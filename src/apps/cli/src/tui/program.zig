//! Program: the Bubble-Tea-style event loop driver.
//!
//! Owns:
//!   - raw-mode + alt-screen enter/exit (always restored, even on error)
//!   - stdin key decoding
//!   - the tick timer (spinner + polling cadence)
//!   - frame double-buffering + diff-based rendering
//!
//! The user's Model must expose:
//!   - `update(msg: Msg) !Cmd`
//!   - `view(allocator, width, height) !Frame`

const std = @import("std");
const terminal = @import("terminal.zig");
const key_mod = @import("key.zig");
const msg_mod = @import("msg.zig");
const frame_mod = @import("frame.zig");

pub const Msg = msg_mod.Msg;
pub const Cmd = msg_mod.Cmd;

/// Poll cadence for the internal tick that drives the spinner (ms).
const TICK_MS: u64 = 100;

/// Milliseconds to hand to the model for a tick that was last serviced at
/// `last_tick_ms` (wall clock, ms). Saturating so a clock that appears to
/// go backwards can't underflow, and clamped to 1 s so a suspend/resume
/// can't fire a burst of catch-up polls.
fn tickElapsedMs(now: u64, last: u64) u64 {
    return @max(1, @min(now -| last, 1000));
}

pub fn Program(comptime Model: type) type {
    return struct {
        const Self = @This();

        model: *Model,
        allocator: std.mem.Allocator,
        io: std.Io,
        /// Set by the model returning `Cmd.send_msg` etc.; executed by
        /// the app-specific executor callback.
        exec_cmd: ?*const fn (self: *Model, cmd: Cmd) void = null,

        prev_frame: ?frame_mod.Frame = null,
        raw_mode: ?terminal.RawMode = null,
        quit_requested: bool = false,
        /// Persistent input byte buffer. Bytes are read into
        /// `input_buf[input_len..]`; after draining, leftover
        /// (incomplete-sequence) bytes are shifted to the start so
        /// the next read appends. 256 bytes is plenty for typical
        /// sequences (SGR mouse is ~12 bytes). Sized to avoid
        /// overflow with reasonable mouse-event bursts.
        input_buf: [256]u8 = undefined,
        input_len: usize = 0,

        pub fn init(model: *Model, allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .model = model, .allocator = allocator, .io = io };
        }

        pub fn deinit(self: *Self) void {
            if (self.prev_frame) |*f| f.deinit(self.allocator);
        }

        /// Run the event loop until a `Msg.quit` is processed or stdin
        /// yields Ctrl-C. Always restores the terminal.
        pub fn run(self: *Self) !void {
            if (!terminal.isTty()) {
                std.log.err("pabrik-tui requires a TTY (stdin is not a terminal)", .{});
                return error.NotATerminal;
            }

            self.raw_mode = terminal.enterRawMode() catch |e| {
                std.log.err("failed to enter raw mode: {s}", .{@errorName(e)});
                return e;
            };
            defer {
                if (self.raw_mode) |rm| terminal.leaveRawMode(rm);
                self.writeOut("\x1b[?25h\x1b[?1049l"); // show cursor, leave alt-screen
                // Disable mouse tracking (paired with the enable in
                // run()). MUST be in the same defer block as the
                // enable so a mid-run crash doesn't leave the user's
                // terminal in mouse-tracking mode (which would make
                // text selection paste escape sequences).
                self.writeOut("\x1b[?1006l\x1b[?1000l");
            }

            self.writeOut("\x1b[?1049h\x1b[?25l"); // enter alt-screen, hide cursor
            // Round-2 (Task 5): enable SGR mouse tracking so the
            // terminal sends `\x1b[<button;col;rowM` sequences when
            // the user scrolls the wheel. 1000 = basic mouse tracking
            // (press/release), 1006 = SGR-encoded coordinates. We
            // only handle wheel events in v1 (button 64/65); clicks
            // are dropped at the key parser. Disable on cleanup so
            // the terminal is left in a normal state — otherwise text
            // selection (drag-to-highlight) would paste garbage.
            self.writeOut("\x1b[?1000h\x1b[?1006h");

            // Round-3 fix (mouse-wheel leak): keep a persistent input
            // buffer that accumulates bytes across reads. Without this,
            // an SGR mouse event split across two reads (e.g. `\x1b[<`
            // in read 1, `64;14;14M` in read 2) would: read 1 → parse
            // returns "incomplete", dispatcher DROPS the 3 bytes; read
            // 2 → parse sees `64;14;14M` starting with a digit, returns
            // a rune for each — the user's input widget ends up with
            // `64;14;14M...` typed text. The buffer carries the
            // partial bytes into the next read so the parse eventually
            // succeeds on the full sequence.
            self.input_len = 0;

            var size = terminal.size();
            try self.draw(size.width, size.height);

            var stdin_buf: [64]u8 = undefined;
            var stdin_reader = std.Io.File.stdin().reader(self.io, &stdin_buf);

            var next_tick_ms = nowMs(self.io) + TICK_MS;
            var last_tick_ms = nowMs(self.io);

            while (!self.quit_requested) {
                // Wait for the next stdin byte OR the next tick, whichever
                // comes first. Polling (rather than read-then-sleep) is what
                // holds keystroke latency at "as soon as the byte lands" —
                // measured ~1 ms, versus ~104 ms before. The old loop had two
                // stacked 100 ms penalties: it blocked in read() and then,
                // when the read reported nothing, slept another 100 ms
                // unconditionally.
                const now = nowMs(self.io);
                const wait_ms: i32 = if (now >= next_tick_ms)
                    0
                else
                    @intCast(@min(next_tick_ms - now, TICK_MS));
                var poll_fds = [_]std.posix.pollfd{.{
                    .fd = std.posix.STDIN_FILENO,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ready = std.posix.poll(&poll_fds, wait_ms) catch 0;
                if (ready > 0) {
                    if ((poll_fds[0].revents & std.posix.POLL.IN) != 0) {
                        // 1. Drain pending input.
                        //
                        // Round-3 fix: bytes go into `self.input_buf` AFTER
                        // any leftover from the previous iteration
                        // (incomplete sequence trailing bytes). Drain events
                        // from the head of the buffer; leftover (incomplete)
                        // bytes stay for the next read.
                        // ONE read syscall — `readVec`, not `readSliceShort`.
                        // Despite its name, `Reader.readSliceShort` loops until
                        // the destination is completely full (or EOF), so
                        // asking it for the whole 256-byte input buffer means
                        // it keeps reading after the first byte and only gives
                        // up when the tty's VTIME expires: measured 108 ms per
                        // keystroke. A short read is exactly what we want here.
                        var read_dest = [1][]u8{self.input_buf[self.input_len..]};
                        const n = stdin_reader.interface.readVec(&read_dest) catch 0;
                        if (n > 0) {
                            self.input_len += n;
                            var consumed: usize = 0;
                            while (consumed < self.input_len) {
                                const rest = self.input_buf[consumed..self.input_len];
                                const p = key_mod.parse(rest);
                                if (p.len == 0) break; // incomplete — keep bytes for next read
                                consumed += p.len;
                                if (p.key) |key| {
                                    switch (key) {
                                        .ctrl_c, .ctrl_d => self.quit_requested = true,
                                        else => {
                                            const cmd = self.model.update(.{ .key = key }) catch |e| {
                                                std.log.err("model.update failed: {s}", .{@errorName(e)});
                                                continue;
                                            };
                                            self.execCmd(cmd);
                                        },
                                    }
                                }
                                // key=null + len>0 → unhandled but consumed
                                // (e.g. button-27 movement event). We just
                                // advanced past it — no dispatch.
                            }
                            // Shift any leftover (incomplete) bytes to the
                            // start of the buffer for the next iteration.
                            if (consumed > 0) {
                                const leftover = self.input_len - consumed;
                                if (leftover > 0) std.mem.copyForwards(u8, self.input_buf[0..leftover], self.input_buf[consumed..self.input_len]);
                                self.input_len = leftover;
                            }
                            if (self.quit_requested) break;
                            try self.draw(size.width, size.height);
                        }
                    }
                    // stdin hung up / errored (e.g. the pty closed) — exit
                    // rather than spinning on a permanently-ready fd.
                    if ((poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) break;
                    // A redraw (or a still-buffered partial key sequence)
                    // already happened; a due tick is picked up on the next
                    // iteration (wait_ms goes to 0), so the tick cadence
                    // can't drift behind input traffic.
                    continue;
                }

                // 2. No input within the wait window — emit TickMsg with the
                //    REAL elapsed time (was a hardcoded TICK_MS, which let
                //    the 500 ms poll cadence drift).
                const tick_now = nowMs(self.io);
                const elapsed = tickElapsedMs(tick_now, last_tick_ms);
                last_tick_ms = tick_now;
                next_tick_ms = tick_now + TICK_MS;
                const cmd = self.model.update(.{ .tick = elapsed }) catch {
                    next_tick_ms = nowMs(self.io) + TICK_MS;
                    continue;
                };
                self.execCmd(cmd);

                // 3. Pick up resizes.
                const new_size = terminal.size();
                if (new_size.width != size.width or new_size.height != size.height) {
                    size = new_size;
                    self.prev_frame.?.deinit(self.allocator);
                    self.prev_frame = null; // force full repaint
                }
                try self.draw(size.width, size.height);
            }
        }

        fn execCmd(self: *Self, cmd: Cmd) void {
            switch (cmd) {
                .none => {},
                .tick_after => {}, // v1 uses a fixed-rate loop tick
                else => {
                    if (self.exec_cmd) |f| f(self.model, cmd);
                },
            }
        }

        fn draw(self: *Self, width: u16, height: u16) !void {
            const bytes = try self.renderDiff(width, height);
            defer self.allocator.free(bytes);
            self.writeOut(bytes);
        }

        /// Renders the model, diffs it against the previous frame and
        /// returns the bytes that bring the terminal up to date. Split out
        /// of `draw` so tests can exercise the allocation/ownership
        /// behaviour without spraying escape codes at stdout.
        fn renderDiff(self: *Self, width: u16, height: u16) ![]u8 {
            var next = self.model.view(self.allocator, width, height) catch |e| {
                std.log.err("model.view failed: {s}", .{@errorName(e)});
                return e;
            };
            errdefer next.deinit(self.allocator);

            const bytes = try frame_mod.diff(
                self.allocator,
                if (self.prev_frame) |*p| p else null,
                &next,
            );
            // Swap: the frame we just rendered becomes the reference for the
            // next diff. Move ownership instead of allocating a fresh frame
            // and memcpy-ing into it — that was one extra `width*height`
            // allocation plus a full copy, on every single draw.
            if (self.prev_frame) |*p| p.deinit(self.allocator);
            self.prev_frame = next;
            return bytes;
        }

        fn writeOut(self: *Self, bytes: []const u8) void {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(self.io, &buf);
            w.interface.writeAll(bytes) catch {};
            w.interface.flush() catch {};
        }

        fn nowMs(io: std.Io) u64 {
            const ms = std.Io.Clock.now(.real, io).toMilliseconds();
            return if (ms < 0) 0 else @intCast(ms);
        }
    };
}

// ----------------------------------------------------------------------------
// Tests — the loop itself needs a tty, so we test the pure parts.
// ----------------------------------------------------------------------------

const testing = std.testing;

const TestModel = struct {
    ticks: usize = 0,
    last_key: ?key_mod.Key = null,

    pub fn update(self: *TestModel, m: Msg) !Cmd {
        switch (m) {
            .tick => self.ticks += 1,
            .key => |k| self.last_key = k,
            .quit => {},
            else => {},
        }
        return .none;
    }

    pub fn view(self: *TestModel, allocator: std.mem.Allocator, width: u16, height: u16) !frame_mod.Frame {
        _ = self;
        return frame_mod.Frame.init(allocator, width, height);
    }
};

test "Program: init/deinit without run is clean" {
    var model = TestModel{};
    var p = Program(TestModel).init(&model, testing.allocator, undefined);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), model.ticks);
}

// The 2026-09-13 audit finding #2: draw() allocated a second frame buffer per
// draw (`Frame.init` + `@memcpy`) and freed neither the previous reference
// frame nor the just-rendered one in a way any arena could reclaim. That is
// what leaked ~0.3 MB per keystroke. With a real allocator the frame swap must
// release every byte it takes — `testing.allocator` fails the test otherwise.
test "Program: repeated draws release every frame buffer (no leak)" {
    var model = TestModel{};
    var p = Program(TestModel).init(&model, testing.allocator, undefined);
    defer p.deinit();

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        const bytes = try p.renderDiff(20, 6);
        testing.allocator.free(bytes);
    }
    // Exactly one frame is retained (the diff reference), not 20 + 1.
    try testing.expect(p.prev_frame != null);
    try testing.expectEqual(@as(usize, 20 * 6), p.prev_frame.?.cells.len);
}

test "Program: frame swap means a second draw of an unchanged model is empty" {
    var model = TestModel{};
    var p = Program(TestModel).init(&model, testing.allocator, undefined);
    defer p.deinit();

    // First draw: full repaint (clear-screen + content + cursor park).
    const first = try p.renderDiff(10, 3);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "\x1b[2J") != null);
    try testing.expect(first.len > "\x1b[3;1H".len);

    // Second draw of an identical model: nothing changed, so only the cursor
    // park is emitted. This only holds because the swap keeps the *rendered*
    // frame (not a blank one) as the diff reference.
    const second = try p.renderDiff(10, 3);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("\x1b[3;1H", second);
}

test "Program: tickElapsedMs saturates and clamps" {
    try testing.expectEqual(@as(u64, 1), tickElapsedMs(100, 100)); // never 0
    try testing.expectEqual(@as(u64, 100), tickElapsedMs(1_100, 1_000));
    try testing.expectEqual(@as(u64, 1), tickElapsedMs(999, 1_000)); // clock went backwards
    try testing.expectEqual(@as(u64, 1000), tickElapsedMs(60_000, 1_000)); // resume after suspend
}

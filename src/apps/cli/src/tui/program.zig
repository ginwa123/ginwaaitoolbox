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

/// Interval for the internal tick that drives the spinner (ms).
const TICK_MS: u64 = 100;

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
                std.log.err("nalar-tui requires a TTY (stdin is not a terminal)", .{});
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

            while (!self.quit_requested) {
                // 1. Drain pending input (non-blocking-ish: raw mode with
                //    VMIN=0/VTIME=1 makes reads return quickly).
                //
                // Round-3 fix: bytes go into `self.input_buf` AFTER any
                // leftover from the previous iteration (incomplete
                // sequence trailing bytes). Drain events from the head
                // of the buffer; leftover (incomplete) bytes stay for
                // the next read.
                const n = stdin_reader.interface.readSliceShort(self.input_buf[self.input_len..]) catch 0;
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
                    continue;
                }

                // 2. No input — sleep one tick and emit TickMsg.
                self.io.sleep(std.Io.Duration.fromMilliseconds(@intCast(TICK_MS)), .awake) catch {};
                const cmd = self.model.update(.{ .tick = TICK_MS }) catch continue;
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
            var next = self.model.view(self.allocator, width, height) catch |e| {
                std.log.err("model.view failed: {s}", .{@errorName(e)});
                return e;
            };
            defer next.deinit(self.allocator);

            const bytes = frame_mod.diff(
                self.allocator,
                if (self.prev_frame) |*p| p else null,
                &next,
            ) catch |e| return e;
            defer self.allocator.free(bytes);
            self.writeOut(bytes);

            // Swap: keep the rendered frame as the new "prev".
            if (self.prev_frame) |*p| p.deinit(self.allocator);
            self.prev_frame = try frame_mod.Frame.init(self.allocator, width, height);
            @memcpy(self.prev_frame.?.cells, next.cells);
        }

        fn writeOut(self: *Self, bytes: []const u8) void {
            var buf: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(self.io, &buf);
            w.interface.writeAll(bytes) catch {};
            w.interface.flush() catch {};
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

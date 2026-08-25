//! App: the chat Model that plugs into `tui.Program`.
//!
//! State machine:
//!   - idle → (Enter pressed) → sending → streaming → idle
//!   - Ctrl-C at any point → quit
//!
//! Streaming is driven by TickMsg polls of GET /api/llm/session/:id/messages
//! every 500 ms while a send is in flight. (The SSE channel exists but
//! v1 keeps the loop single-threaded and poll-based; SSE is wired in
//! transport.openEvents for a follow-up.)

const std = @import("std");
const tui = @import("root.zig");
const custom_http_client = @import("custom_http_client");
const transport = @import("transport.zig");

/// Case-insensitive ASCII equality. Avoids a std lib function that may
/// or may not be available depending on Zig patch version.
fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Poll cadence while waiting for the assistant reply (ms).
const POLL_MS: u64 = 500;

pub const Config = struct {
    server: []const u8 = "http://localhost:8081",
    session_id: ?[]const u8 = null,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,

    viewport: tui.Viewport,
    input: tui.Input,
    spinner: tui.Spinner,
    status: tui.StatusBar,

    http_client: custom_http_client.Client,

    session_id: ?[]u8 = null,
    is_streaming: bool = false,
    /// Number of messages already rendered from the last poll.
    seen_count: usize = 0,
    /// Milliseconds accumulated since the last poll.
    since_poll_ms: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !App {
        var app = App{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .viewport = tui.Viewport.init(allocator),
            .input = tui.Input.init(allocator),
            .spinner = .{ .label = "thinking" },
            .status = .{},
            .http_client = custom_http_client.Client.init(allocator),
        };
        if (cfg.session_id) |sid| {
            app.session_id = try allocator.dupe(u8, sid);
        }
        app.status.setLeft("nalar-tui");
        app.status.setRight(if (cfg.session_id) |sid| sid else "new session");
        try app.viewport.appendLine("nalar-tui — type a message, Enter to send, Ctrl-C to quit", .{ .fg = .brightBlack });
        return app;
    }

    pub fn deinit(self: *App) void {
        self.viewport.deinit();
        self.input.deinit();
        if (self.session_id) |sid| self.allocator.free(sid);
        self.http_client.deinit();
    }

    /// Free a Cmd payload previously returned by `update`. The
    /// executor must call this after consuming the command (mirrors
    /// Bubble Tea's ownership: the model allocates, the runtime
    /// frees).
    pub fn freeCmd(self: *App, cmd: tui.Cmd) void {
        switch (cmd) {
            .send_msg => |payload| self.allocator.free(payload),
            else => {},
        }
    }

    pub fn update(self: *App, m: tui.Msg) !tui.Cmd {
        switch (m) {
            .key => |k| return self.handleKey(k),
            .tick => |ms| return self.handleTick(ms),
            .resize => return .none,
            .stream_chunk => return .none, // reserved for SSE follow-up
            .stream_done => {
                self.is_streaming = false;
                return .poll_messages;
            },
            .quit => return .none,
        }
    }

    fn handleKey(self: *App, k: tui.Key) !tui.Cmd {
        switch (k) {
            .ctrl_c, .ctrl_d => return .none, // Program handles quit itself
            else => {},
        }
        const submitted = try self.input.handleKey(k);
        if (submitted) {
            const hist = self.input.history.items;
            const msg_text = hist[hist.len - 1];
            const prompt = try std.fmt.allocPrint(self.allocator, "> {s}", .{msg_text});
            defer self.allocator.free(prompt);
            try self.viewport.appendLine(prompt, .{ .bold = true });
            self.is_streaming = true;
            self.spinner.label = "thinking";
            // The executor (tui_main.execCmd) frees the duped payload.
            return .{ .send_msg = try self.allocator.dupe(u8, msg_text) };
        }
        return .none;
    }

    fn handleTick(self: *App, ms: u64) !tui.Cmd {
        if (self.is_streaming) {
            self.spinner.tick();
            self.since_poll_ms += ms;
            if (self.since_poll_ms >= POLL_MS) {
                self.since_poll_ms = 0;
                return .poll_messages;
            }
        }
        return .none;
    }

    /// Called by the command executor after POST /api/llm/session
    /// succeeds; records/creates the session id.
    pub fn onSendOk(self: *App, session_id: []const u8) !void {
        if (self.session_id == null) {
            self.session_id = try self.allocator.dupe(u8, session_id);
            const left = try std.fmt.allocPrint(self.allocator, "session {s}", .{session_id});
            defer self.allocator.free(left);
            self.status.setLeft(left);
        }
    }

    /// Called by the command executor after GET .../messages succeeds.
    /// `body` is the raw JSON response; we extract message contents for
    /// rows beyond `seen_count`.
    pub fn onMessages(self: *App, body: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            // Malformed body — keep streaming and let the next poll try
            // again. Never let a bad JSON snapshot wedge the spinner.
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object.get("messages") orelse return;
        if (root != .array) return;
        const arr = root.array;

        // The endpoint returns the LAST `limit` messages in asc order;
        // if more arrived than we've seen, skip ahead.
        if (arr.items.len <= self.seen_count) {
            self.seen_count = arr.items.len;
            if (!self.is_streaming) return;
        }
        var i = self.seen_count;
        while (i < arr.items.len) : (i += 1) {
            const item = arr.items[i];
            if (item != .object) continue; // skip strings/numbers/null etc.
            const obj = item.object;
            const content = if (obj.get("content")) |c| (if (c == .string) c.string else "") else "";
            if (content.len == 0) continue;
            try self.viewport.appendLine(content, .{});
        }
        self.seen_count = arr.items.len;

        // Heuristic: once an assistant message lands after our send,
        // the turn is over. Case-insensitive to match server variants
        // like "Assistant".
        if (self.is_streaming and arr.items.len > 0) {
            const last = arr.items[arr.items.len - 1];
            if (last == .object) {
                const role = last.object.get("role") orelse return;
                if (role == .string and asciiEqIgnoreCase(role.string, "assistant")) {
                    self.is_streaming = false;
                }
            }
        }
    }

    pub fn view(self: *App, allocator: std.mem.Allocator, width: u16, height: u16) !tui.Frame {
        // Layout: viewport (h-2), spinner-or-blank (1), status (1).
        const vp_h = height -| 3;
        var out = try tui.Frame.init(allocator, width, height);
        errdefer out.deinit(allocator);

        var vp_frame = try self.viewport.render(allocator, width, vp_h);
        defer vp_frame.deinit(allocator);
        @memcpy(out.cells[0..vp_frame.cells.len], vp_frame.cells);

        const mid_y = vp_h;
        if (self.is_streaming) {
            var sp_frame = try self.spinner.render(allocator, width);
            defer sp_frame.deinit(allocator);
            @memcpy(out.cells[@as(usize, mid_y) * width ..][0..sp_frame.cells.len], sp_frame.cells);
        } else {
            var in_frame = try self.input.render(allocator, width);
            defer in_frame.deinit(allocator);
            @memcpy(out.cells[@as(usize, mid_y) * width ..][0..in_frame.cells.len], in_frame.cells);
            out.cursor = .{ .x = in_frame.cursor.?.x, .y = mid_y };
        }

        var st_frame = try self.status.render(allocator, width);
        defer st_frame.deinit(allocator);
        const st_off = @as(usize, height - 1) * width;
        @memcpy(out.cells[st_off..][0..st_frame.cells.len], st_frame.cells);

        return out;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

fn testApp() !App {
    return App.init(testing.allocator, undefined, .{ .server = "http://test" });
}

test "App: init renders welcome line" {
    var app = try testApp();
    defer app.deinit();
    try testing.expectEqual(@as(usize, 1), app.viewport.lines.items.len);
}

test "App: enter submits send_msg cmd and shows prompt" {
    var app = try testApp();
    defer app.deinit();
    _ = try app.update(.{ .key = .{ .rune = 'h' } });
    _ = try app.update(.{ .key = .{ .rune = 'i' } });
    const cmd = try app.update(.{ .key = .enter });
    try testing.expect(cmd == .send_msg);
    try testing.expectEqualStrings("hi", cmd.send_msg);
    try testing.expect(app.is_streaming);
    app.freeCmd(cmd);
}

test "App: tick accumulates to poll_messages" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    // Below POLL_MS → no poll yet.
    var cmd = try app.update(.{ .tick = 100 });
    try testing.expect(cmd == .none);
    // Cross POLL_MS → poll.
    cmd = try app.update(.{ .tick = 450 });
    try testing.expect(cmd == .poll_messages);
}

test "App: spinner ticks while streaming" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const before = app.spinner.frame_idx;
    _ = try app.update(.{ .tick = 100 });
    try testing.expectEqual(before + 1, app.spinner.frame_idx);
}

test "App: onMessages appends new assistant content and stops streaming" {
    var app = try testApp();
    defer app.deinit();
    app.is_streaming = true;
    const body =
        \\{"messages":[
        \\ {"role":"user","content":"hi"},
        \\ {"role":"assistant","content":"hello!"}
        \\]}
    ;
    try app.onMessages(body);
    try testing.expect(!app.is_streaming); // assistant replied → done
    // welcome + user + assistant = 3 lines
    try testing.expectEqual(@as(usize, 3), app.viewport.lines.items.len);
}

test "App: onMessages ignores already-seen messages" {
    var app = try testApp();
    defer app.deinit();
    const body =
        \\{"messages":[{"role":"assistant","content":"a"}]}
    ;
    try app.onMessages(body);
    try app.onMessages(body); // same count → no new lines
    try testing.expectEqual(@as(usize, 2), app.viewport.lines.items.len);
}

test "App: view produces full-height frame with status bar" {
    var app = try testApp();
    defer app.deinit();
    var f = try app.view(testing.allocator, 40, 10);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 40), f.width);
    try testing.expectEqual(@as(u16, 10), f.height);
    // Status bar row has the brightBlack background bar.
    try testing.expect(f.get(0, 9).bg != null);
}

const std = @import("std");
const builtin = @import("builtin");

const SOCKET_PATH = "/tmp/agent.sock";

const reset = "\x1b[0m";
const bold = "\x1b[1m";
const dim = "\x1b[2m";
const cyan = "\x1b[36m";
const yellow = "\x1b[33m";
const green = "\x1b[32m";

const sockaddr_un = if (builtin.os.tag != .windows)
    extern struct { sun_family: c_ushort, sun_path: [108]u8 }
else
    void;

// ─── App struct ──────────────────────────────────────────────────────────────

const App = struct {
    // connection
    socket_fd: std.posix.fd_t,

    // terminal
    original_termios: std.posix.termios,

    // session
    session_id: []u8,
    allocator: std.mem.Allocator,

    // input
    input: std.ArrayList(u8),
    pasting: bool,

    // agent name buffer (fixed size to avoid memory issues)
    agent_name_buf: [64]u8 = [_]u8{0} ** 64,

    pub fn init(allocator: std.mem.Allocator) !App {
        try spawnBackend();
        try waitForSocket(10000);

        const socket_fd = try connectToSocket();
        const original_termios = try enableRawMode();
        const session_id = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});

        return App{
            .socket_fd = socket_fd,
            .original_termios = original_termios,
            .session_id = session_id,
            .allocator = allocator,
            .input = std.ArrayList(u8).empty,
            .pasting = false,
        };
    }

    pub fn deinit(app: *App) void {
        disableRawMode(app.original_termios);
        std.posix.close(app.socket_fd);
        app.allocator.free(app.session_id);
        app.input.deinit(app.allocator);
    }
};

// ─── Terminal ────────────────────────────────────────────────────────────────

fn enableRawMode() !std.posix.termios {
    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

fn disableRawMode(original: std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch {};
}

// ─── Backend / Socket ────────────────────────────────────────────────────────

fn spawnBackend() !void {
    if (std.fs.accessAbsolute(SOCKET_PATH, .{})) |_| {
        return;
    } else |_| {}

    const cwd = std.fs.cwd();
    const backend_path = try cwd.realpathAlloc(std.heap.page_allocator, "zig-out/bin/tree1");
    defer std.heap.page_allocator.free(backend_path);

    var child = std.process.Child.init(&.{backend_path}, std.heap.page_allocator);
    child.spawn() catch |err| {
        std.debug.print("{s}Warning: failed to spawn backend: {s}{s}\n", .{ yellow, @errorName(err), reset });
        return;
    };

    std.debug.print("{s}Backend started in background{s}\n", .{ green, reset });
}

fn waitForSocket(timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (true) {
        const socket_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
            std.Thread.sleep(50000000);
            continue;
        };
        defer std.posix.close(socket_fd);

        var addr = std.mem.zeroInit(sockaddr_un, .{});
        addr.sun_family = std.posix.AF.UNIX;
        @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);

        if (std.posix.connect(socket_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un))) {
            return;
        } else |_| {
            std.Thread.sleep(50000000);
        }

        if (std.time.milliTimestamp() - start > timeout_ms) {
            return error.Timeout;
        }
    }
}

fn connectToSocket() !std.posix.fd_t {
    const socket_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(socket_fd);
    var addr = std.mem.zeroInit(sockaddr_un, .{});
    addr.sun_family = std.posix.AF.UNIX;
    @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
    try std.posix.connect(socket_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un));
    return socket_fd;
}

// ─── XML helpers ─────────────────────────────────────────────────────────────

fn escapeXmlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '&' => try result.appendSlice(allocator, "&amp;"),
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

// ─── Messaging ───────────────────────────────────────────────────────────────

fn sendMessage(app: *App, message: []const u8) !void {
    var xml_buf = std.ArrayList(u8).empty;
    defer xml_buf.deinit(app.allocator);

    const cwd = std.process.getCwdAlloc(app.allocator) catch "";
    defer app.allocator.free(cwd);

    const escaped_message = try escapeXmlString(app.allocator, message);
    defer app.allocator.free(escaped_message);
    const escaped_session_id = try escapeXmlString(app.allocator, app.session_id);
    defer app.allocator.free(escaped_session_id);
    const escaped_cwd = try escapeXmlString(app.allocator, cwd);
    defer app.allocator.free(escaped_cwd);

    try xml_buf.writer(app.allocator).print(
        "<message><command_type>tui</command_type><session_id>{s}</session_id><content>{s}</content><cwd_session>{s}</cwd_session></message>",
        .{ escaped_session_id, escaped_message, escaped_cwd },
    );
    _ = try std.posix.write(app.socket_fd, xml_buf.items);
}

// ─── Response formatting ─────────────────────────────────────────────────────

fn printFormattedResponse(content: []const u8) void {
    const agent_name = extractTag(content, "agent") orelse "unknown";
    std.debug.print("{s}━━ {s} ━━{s}\n", .{ cyan, agent_name, reset });

    if (extractTag(content, "markdown")) |md| {
        const trimmed = trim(md);
        if (trimmed.len > 0) {
            std.debug.print("\n{s}{s}{s}\n", .{ bold, trimmed, reset });
        }
    }

    printAllTags(content, &.{ "agent", "markdown" }, 0);
}

fn isNestedElsewhere(xml: []const u8, tag: []const u8, tag_content: []const u8) bool {
    const tag_content_ptr = @intFromPtr(tag_content.ptr);
    var pos: usize = 0;
    while (pos < xml.len) {
        const open_start = std.mem.indexOfPos(u8, xml, pos, "<") orelse break;
        const open_end = std.mem.indexOfPos(u8, xml, open_start + 1, ">") orelse break;
        const other_tag = xml[open_start + 1 .. open_end];
        pos = open_end + 1;

        if (other_tag.len == 0 or other_tag[0] == '/' or std.mem.indexOfScalar(u8, other_tag, ' ') != null) continue;
        if (std.mem.eql(u8, other_tag, tag)) continue;

        const other_content = extractTag(xml, other_tag) orelse continue;
        const other_ptr = @intFromPtr(other_content.ptr);
        const other_end = other_ptr + other_content.len;

        if (tag_content_ptr >= other_ptr and tag_content_ptr + tag_content.len <= other_end) {
            return true;
        }
    }
    return false;
}

fn printAllTags(content: []const u8, skip: []const []const u8, depth: usize) void {
    var pos: usize = 0;
    var printed_buf: [64][]const u8 = undefined;
    var printed_len: usize = 0;

    while (pos < content.len) {
        const open_start = std.mem.indexOfPos(u8, content, pos, "<") orelse break;
        const open_end = std.mem.indexOfPos(u8, content, open_start + 1, ">") orelse break;
        const tag = content[open_start + 1 .. open_end];
        pos = open_end + 1;

        if (tag.len == 0 or tag[0] == '/' or std.mem.indexOfScalar(u8, tag, ' ') != null) continue;

        const should_skip = for (skip) |s| {
            if (std.mem.eql(u8, s, tag)) break true;
        } else false;
        if (should_skip) continue;

        const already_printed = for (printed_buf[0..printed_len]) |p| {
            if (std.mem.eql(u8, p, tag)) break true;
        } else false;
        if (already_printed) continue;

        const tag_content = extractTag(content, tag) orelse continue;

        if (isNestedElsewhere(content, tag, tag_content)) continue;

        if (printed_len < printed_buf.len) {
            printed_buf[printed_len] = tag;
            printed_len += 1;
        }

        printTagBox(tag, tag_content, depth);
    }
}

fn printTagBox(tag: []const u8, content: []const u8, depth: usize) void {
    const colors = [_][]const u8{ cyan, green, yellow, dim };
    var hash: usize = 0;
    for (tag) |c| hash = hash *% 31 +% c;
    const color = colors[hash % colors.len];

    const indent_base = "                "; // 16 spaces
    const indent_str = indent_base[0..@min(depth * 2, indent_base.len)];

    var label_buf: [64]u8 = undefined;
    const label = blk: {
        const n = @min(tag.len, label_buf.len);
        @memcpy(label_buf[0..n], tag[0..n]);
        if (label_buf[0] >= 'a' and label_buf[0] <= 'z') label_buf[0] -= 32;
        for (label_buf[0..n]) |*c| if (c.* == '_') {
            c.* = ' ';
        };
        break :blk label_buf[0..n];
    };

    var border_buf: [256]u8 = undefined;
    var border_len: usize = 0;
    const dash = "─";
    const dash_count = label.len + 4;
    for (0..dash_count) |_| {
        if (border_len + dash.len <= border_buf.len) {
            @memcpy(border_buf[border_len..][0..dash.len], dash);
            border_len += dash.len;
        }
    }
    const border = border_buf[0..border_len];

    const trimmed = trim(content);
    const has_children = std.mem.indexOf(u8, trimmed, "<") != null;

    std.debug.print("{s}{s}┌─ {s} ─{s}\n", .{ indent_str, color, label, reset });

    if (has_children) {
        printAllTags(content, &.{}, depth + 1);
    } else if (trimmed.len > 0) {
        std.debug.print("{s}{s}│{s} {s}\n", .{ indent_str, color, reset, trimmed });
    }

    std.debug.print("{s}{s}└{s}{s}\n", .{ indent_str, color, border, reset });
}

pub fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    const close_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(close_tag);
    const open_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(open_tag);
    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;
    const open_pos = std.mem.lastIndexOf(u8, xml[0..close_pos], open_tag) orelse return null;
    return xml[open_pos + open_tag.len .. close_pos];
}

// ─── Response streaming ──────────────────────────────────────────────────────

fn readResponseAndStream(app: *App) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(app.allocator);
    var buf: [4096]u8 = undefined;
    var spinner_timer: usize = 0;
    const spinners = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var last_tick = std.time.milliTimestamp();
    var last_displayed_len: usize = 0; // track what we've already printed

    while (true) {
        const n = std.posix.read(app.socket_fd, &buf) catch break;
        if (n == 0) break;
        try buffer.appendSlice(app.allocator, buf[0..n]);

        const now = std.time.milliTimestamp();
        if (now - last_tick >= 100) {
            last_tick = now;
            const spin = spinners[spinner_timer % spinners.len];
            spinner_timer += 1;

            const chunk = if (extractTag(buffer.items, "content")) |c| c else "";
            const new_text = if (chunk.len > last_displayed_len) chunk[last_displayed_len..] else "";
            last_displayed_len = chunk.len;

            // Replace newlines with spaces for single-line display
            var clean_buf: [200]u8 = undefined;
            var clean_len: usize = 0;
            for (new_text) |c| {
                if (clean_len >= clean_buf.len - 1) break;
                clean_buf[clean_len] = if (c == '\n' or c == '\r') ' ' else c;
                clean_len += 1;
            }
            std.debug.print("\r\x1b[2K {s}{s}{s} Loading... ({d} bytes)", .{ yellow, spin, reset, buffer.items.len });
        }

        if (std.mem.indexOf(u8, buffer.items, "</finish_reason>") == null) continue;

        if (extractTag(buffer.items, "finish_reason")) |fr| {
            if (std.mem.eql(u8, fr, "user_choice")) {
                std.debug.print("Your input \n", .{});
                break;
            }
        }
    }

    // Clear spinner and print clean response
    std.debug.print("\r\x1b[2K", .{});
    std.debug.print("\n", .{});

    // Extract and display the valuable content
    if (extractTag(buffer.items, "content")) |content| {
        printFormattedResponse(content);
    } else {
        // Fallback: just print the raw buffer
        std.debug.print("{s}", .{buffer.items});
    }

    std.debug.print("\r\n", .{});
    return try buffer.toOwnedSlice(app.allocator);
}

// ─── Input handling ──────────────────────────────────────────────────────────

pub const KEYBINDING = enum(u8) {
    CTRL_C = 3,
    ENTER = 13,
};

fn readEscapeSequence(buf: *[16]u8) !usize {
    buf[0] = 0x1b;
    var i: usize = 1;
    while (i < buf.len) {
        var b: [1]u8 = undefined;
        var bytes_available: c_int = 0;
        _ = std.os.linux.ioctl(std.posix.STDIN_FILENO, std.os.linux.T.FIONREAD, @intFromPtr(&bytes_available));
        if (bytes_available == 0) break;
        const n = std.posix.read(std.posix.STDIN_FILENO, &b) catch break;
        if (n == 0) break;
        buf[i] = b[0];
        i += 1;
        if (b[0] == '~') break;
    }
    return i;
}

fn handleInput(app: *App) !bool {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
    if (n == 0) {
        std.Thread.sleep(10000000);
        return false;
    }
    const c = buf[0];

    if (c == @intFromEnum(KEYBINDING.CTRL_C)) return true; // signal exit

    if (c == 0x1b) {
        var esc: [16]u8 = undefined;
        const len = try readEscapeSequence(&esc);
        const seq = esc[0..len];
        if (std.mem.eql(u8, seq, "\x1b[200~")) app.pasting = true else if (std.mem.eql(u8, seq, "\x1b[201~")) app.pasting = false;
        return false;
    }

    if (c == 127 or c == 8) {
        if (!app.pasting and app.input.items.len > 0) {
            _ = app.input.pop();
            std.debug.print("\x08 \x08", .{});
        }
    } else if (c == @intFromEnum(KEYBINDING.ENTER) or c == 10) {
        // const arena_allocator = std.heap.ArenaAllocator.init(app.allocator);
        // defer arena_allocator.deinit();
        if (app.pasting) {
            try app.input.append(app.allocator, '\n');
            std.debug.print("\r\n", .{});
        } else {
            if (app.input.items.len > 0) {
                std.debug.print("\r\n\r\n", .{});
                try sendMessage(app, app.input.items);
                const response = readResponseAndStream(app) catch "";
                if (response.len == 0) std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
                app.input.clearRetainingCapacity();
            }
            std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
        }
    } else if (c >= 32) {
        try app.input.append(app.allocator, c);
        std.debug.print("{c}", .{c});
    }

    return false;
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_allocator = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_allocator.deinit();

    const allocator = arena_allocator.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    std.debug.print("{s}Connected!{s}\r\n", .{ green, reset });
    std.debug.print("Type message and press Enter. Ctrl+C to exit.\r\n\r\n", .{});

    std.debug.print("\x1b[?2004h", .{}); // enable bracketed paste
    defer std.debug.print("\x1b[?2004l", .{});

    std.debug.print("{s}>{s} ", .{ bold, reset });

    while (true) {
        const should_exit = try handleInput(&app);
        if (should_exit) break;
    }

    std.debug.print("\r\n{s}Bye!{s}\r\n", .{ dim, reset });
}

const std = @import("std");
const builtin = @import("builtin");
const keybindings = @import("keybindings.zig");

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

    // runtime-configurable keybindings
    keybindings: keybindings.Keybindings,

    pub fn init(allocator: std.mem.Allocator) !App {
        try spawnBackend();
        try waitForSocket(10000);

        const socket_fd = try connectToSocket();
        const original_termios = try enableRawMode();
        const session_id = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});
        const kb = try keybindings.loadKeybindings(allocator);

        return App{
            .socket_fd = socket_fd,
            .original_termios = original_termios,
            .session_id = session_id,
            .allocator = allocator,
            .input = std.ArrayList(u8).empty,
            .pasting = false,
            .keybindings = kb,
        };
    }

    pub fn deinit(app: *App) void {
        app.keybindings.deinit();
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
    // Remove stale socket file if it exists but nothing is listening
    if (std.fs.accessAbsolute(SOCKET_PATH, .{})) |_| {
        // Try connecting — if it works, backend is alive, skip spawn
        const test_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch null;
        if (test_fd) |fd| {
            defer std.posix.close(fd);
            var addr = std.mem.zeroInit(sockaddr_un, .{});
            addr.sun_family = std.posix.AF.UNIX;
            @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
            if (std.posix.connect(fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un))) {
                return; // already running
            } else |_| {}
        }
        // Stale socket — remove it
        std.fs.deleteFileAbsolute(SOCKET_PATH) catch {};
    } else |_| {}

    const backend_path = try std.fs.realpathAlloc(std.heap.page_allocator, "/usr/local/bin/zigginagentic");
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
        if (std.time.milliTimestamp() - start > timeout_ms) {
            return error.Timeout;
        }
        const socket_fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch {
            std.Thread.sleep(50_000_000);
            continue;
        };
        defer std.posix.close(socket_fd);
        var addr = std.mem.zeroInit(sockaddr_un, .{});
        addr.sun_family = std.posix.AF.UNIX;
        @memcpy(addr.sun_path[0..SOCKET_PATH.len], SOCKET_PATH);
        if (std.posix.connect(socket_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), @sizeOf(sockaddr_un))) {
            return; // connected!
        } else |_| {
            std.Thread.sleep(50_000_000); // 50ms
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

// ─── Message Protocol ────────────────────────────────────────────────────────

fn escapeXmlString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (input) |c| {
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

fn sendMessage(app: *App, message: []const u8) !void {
    const cwd = std.process.getCwdAlloc(app.allocator) catch "";
    defer if (cwd.len > 0) app.allocator.free(cwd);

    const escaped_message = try escapeXmlString(app.allocator, message);
    defer app.allocator.free(escaped_message);

    const escaped_session_id = try escapeXmlString(app.allocator, app.session_id);
    defer app.allocator.free(escaped_session_id);

    const escaped_cwd = try escapeXmlString(app.allocator, cwd);
    defer if (escaped_cwd.len > 0) app.allocator.free(escaped_cwd);

    const xml = try std.fmt.allocPrint(
        app.allocator,
        \\<message session_id="{s}"><content>{s}</content><cwd>{s}</cwd></message>
    ,
        .{ escaped_session_id, escaped_message, escaped_cwd },
    );
    defer app.allocator.free(xml);

    _ = std.posix.write(app.socket_fd, xml) catch 0;
}

fn readResponseAndStream(app: *App) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var response = std.ArrayList(u8).empty;
    errdefer response.deinit(app.allocator);

    var in_thinking = false;
    var in_content = false;
    var content_buf = std.ArrayList(u8).empty;
    defer content_buf.deinit(app.allocator);

    while (true) {
        const n = std.posix.read(app.socket_fd, &buf) catch 0;
        if (n == 0) break;

        try response.appendSlice(app.allocator, buf[0..n]);

        // Stream content as it arrives
        for (buf[0..n]) |c| {
            if (in_content) {
                if (c == '<') {
                    // End of content tag
                    in_content = false;
                    if (content_buf.items.len > 0) {
                        std.debug.print("{s}", .{content_buf.items});
                        content_buf.clearRetainingCapacity();
                    }
                } else {
                    try content_buf.append(app.allocator, c);
                }
            } else if (in_thinking) {
                if (c == '>') {
                    in_thinking = false;
                }
            } else {
                // Check for content start
                if (std.mem.endsWith(u8, content_buf.items, "<content")) {
                    content_buf.clearRetainingCapacity();
                    in_content = true;
                } else if (std.mem.endsWith(u8, content_buf.items, "<thinking")) {
                    content_buf.clearRetainingCapacity();
                    in_thinking = true;
                } else {
                    try content_buf.append(app.allocator, c);
                    if (content_buf.items.len > 20) {
                        // Keep only last 20 chars for tag detection
                        _ = content_buf.orderedRemove(0);
                    }
                }
            }
        }
    }

    if (content_buf.items.len > 0) {
        std.debug.print("{s}", .{content_buf.items});
    }

    return response.toOwnedSlice(app.allocator);
}

// ─── Input handling ──────────────────────────────────────────────────────────

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

    if (c == app.keybindings.exit) return true; // signal exit

    if (c == 0x1b) {
        var esc: [16]u8 = undefined;
        const len = try readEscapeSequence(&esc);
        const seq = esc[0..len];
        if (std.mem.eql(u8, seq, app.keybindings.paste_start)) app.pasting = true else if (std.mem.eql(u8, seq, app.keybindings.paste_end)) app.pasting = false;
        return false;
    }

    if (c == app.keybindings.backspace_alt or c == app.keybindings.backspace) {
        if (!app.pasting and app.input.items.len > 0) {
            _ = app.input.pop();
            std.debug.print("\x08 \x08", .{});
        }
    } else if (c == app.keybindings.submit or c == app.keybindings.submit_alt) {
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

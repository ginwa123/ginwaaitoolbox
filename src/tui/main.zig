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

fn enableRawMode() !std.posix.termios {
    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = original;
    raw.lflag.ECHO = false; // no echo
    raw.lflag.ICANON = false; // no line buffering
    raw.lflag.ISIG = false; // no signals
    raw.lflag.IEXTEN = false;
    // DO NOT touch ICRNL - keep \r -> \n conversion
    // DO NOT touch OPOST - keep output processing
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
    return original;
}

fn disableRawMode(original: std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch {};
}

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

/// Escape special characters for XML content
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

/// Send message in XML format
fn sendMessage(socket_fd: std.posix.fd_t, session_id: []const u8, message: []const u8) !void {
    var xml_buf = std.ArrayList(u8).empty;
    defer xml_buf.deinit(std.heap.page_allocator);

    const cwd = std.process.getCwdAlloc(std.heap.page_allocator) catch "";
    defer std.heap.page_allocator.free(cwd);

    const escaped_message = try escapeXmlString(std.heap.page_allocator, message);
    defer std.heap.page_allocator.free(escaped_message);

    const escaped_session_id = try escapeXmlString(std.heap.page_allocator, session_id);
    defer std.heap.page_allocator.free(escaped_session_id);

    const escaped_cwd = try escapeXmlString(std.heap.page_allocator, cwd);
    defer std.heap.page_allocator.free(escaped_cwd);

    try xml_buf.writer(std.heap.page_allocator).print(
        "<message><command_type>agent_ask</command_type><session_id>{s}</session_id><content>{s}</content><cwd_session>{s}</cwd_session></message>",
        .{ escaped_session_id, escaped_message, escaped_cwd },
    );
    _ = try std.posix.write(socket_fd, xml_buf.items);
}

fn readResponseAndStream(socket_fd: std.posix.fd_t, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var buf: [4096]u8 = undefined;

    std.debug.print("{s}▸{s} ", .{ yellow, reset });

    while (true) {
        const n = std.posix.read(socket_fd, &buf) catch break;
        if (n == 0) break;

        try buffer.appendSlice(allocator, buf[0..n]);

        for (buf[0..n]) |byte| {
            std.debug.print("{c}", .{byte});
        }

        if (extractTag(buffer.items, "finish_reason")) |fr| {
            if (std.mem.eql(u8, fr, "stop")) {
                break;
            }
        }
    }
    std.debug.print("\n", .{});
    return try buffer.toOwnedSlice(allocator);
}

pub fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(start_tag);
    const end_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(end_tag);

    var result: ?[]const u8 = null;
    var search_start: usize = 0;

    while (true) {
        const start = std.mem.indexOf(u8, xml[search_start..], start_tag) orelse break;
        const content_start = search_start + start + start_tag.len;
        const end = std.mem.indexOf(u8, xml[content_start..], end_tag) orelse break;
        result = xml[content_start .. content_start + end];
        search_start = content_start + end;
    }

    return result;
}

pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

pub const KEBINDING = enum(u8) {
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

pub fn main() !void {
    try spawnBackend();
    try waitForSocket(10000);
    const socket_fd = try connectToSocket();
    defer std.posix.close(socket_fd);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // enable raw mode BEFORE printing anything interactive
    const original_termios = try enableRawMode();
    defer disableRawMode(original_termios);

    std.debug.print("{s}Connected!{s}\r\n", .{ green, reset });
    std.debug.print("Type message and press Enter. Ctrl+C to exit.\r\n\r\n", .{});

    const session_id: []u8 = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});
    defer allocator.free(session_id);
    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    // enable bracketed paste mode
    std.debug.print("\x1b[?2004h", .{});
    defer std.debug.print("\x1b[?2004l", .{});

    std.debug.print("{s}>{s} ", .{ bold, reset });

    var pasting: bool = false;

    while (true) {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
        if (n == 0) {
            std.Thread.sleep(10000000);
            continue;
        }
        const c = buf[0];

        if (c == @intFromEnum(KEBINDING.CTRL_C)) break;

        if (c == 0x1b) {
            var esc: [16]u8 = undefined;
            const len = try readEscapeSequence(&esc);
            const seq = esc[0..len];

            if (std.mem.eql(u8, seq, "\x1b[200~")) {
                pasting = true;
            } else if (std.mem.eql(u8, seq, "\x1b[201~")) {
                pasting = false;
            }
            continue;
        }

        if (c == 127 or c == 8) {
            if (!pasting and input.items.len > 0) {
                _ = input.pop();
                std.debug.print("\x08 \x08", .{});
            }
        } else if (c == @intFromEnum(KEBINDING.ENTER) or c == 10) {
            if (pasting) {
                try input.append(allocator, '\n');
                std.debug.print("\r\n", .{});
            } else {
                if (input.items.len > 0) {
                    std.debug.print("\r\n\r\n", .{});
                    std.debug.print("\r\nDEBUG sending: '{s}'\r\n", .{input.items});
                    try sendMessage(socket_fd, session_id, input.items);
                    const response = readResponseAndStream(socket_fd, allocator) catch "";
                    if (response.len == 0) {
                        std.debug.print("{s}No response{s}\r\n", .{ dim, reset });
                    }
                    input.clearRetainingCapacity();
                    std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
                } else {
                    std.debug.print("\r\n{s}>{s} ", .{ bold, reset });
                }
            }
        } else if (c >= 32) {
            try input.append(allocator, c);
            std.debug.print("{c}", .{c});
        }
    }
    std.debug.print("\r\n{s}Bye!{s}\r\n", .{ dim, reset });
}

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

fn sendMessage(socket_fd: std.posix.fd_t, session_id: []const u8, message: []const u8) !void {
    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(std.heap.page_allocator);
    try json_buf.writer(std.heap.page_allocator).print(
        "{{\"command_type\":\"agent_ask\",\"session_id\":\"{s}\",\"message\":\"{s}\"}}",
        .{ session_id, message },
    );
    _ = try std.posix.write(socket_fd, json_buf.items);
}

fn readResponseAndStream(socket_fd: std.posix.fd_t, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    var buf: [4096]u8 = undefined;
    // var in_content = false;

    std.debug.print("{s}▸{s} ", .{ yellow, reset });

    while (true) {
        const n = std.posix.read(socket_fd, &buf) catch break;
        if (n == 0) break;

        try buffer.appendSlice(allocator, buf[0..n]);

        // Check for content tag in full buffer
        for (buf[0..n]) |byte| {
            std.debug.print("{c}", .{byte});
        }

        if (extractTag(buffer.items, "finish_reason")) |fr| {
            if (std.mem.eql(u8, fr, "stop")) {
                break;
            }
        }

        // if (buffer.items.len >= 11 and std.mem.endsWith(u8, buffer.items, "</response>")) {
        //     break;
        // }
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

fn showResponse(response: []const u8) void {
    var xml = response;

    if (std.mem.startsWith(u8, response, "<response>")) {
        xml = response[9..];
        if (std.mem.endsWith(u8, xml, "</response>")) {
            xml = xml[0 .. xml.len - 11];
        }
    }

    const content = extractTag(xml, "content") orelse {
        std.debug.print("{s}{s}{s}\n", .{ dim, xml, reset });
        return;
    };

    std.debug.print("\n{s}┌{s}┐{s}\n", .{ cyan, "─" ** 56, reset });

    if (extractTag(content, "agent")) |n| {
        const t = trim(n);
        if (t.len > 0) std.debug.print("{s}│{s} 🤖 {s}Agent:{s} {s}{s}{s}\n", .{ cyan, reset, yellow, reset, bold, t, reset });
    }
    if (extractTag(content, "thought")) |t| {
        const x = trim(t);
        if (x.len > 0) std.debug.print("{s}│{s} 💭 {s}{s}{s}\n", .{ cyan, reset, dim, x, reset });
    }
    if (extractTag(content, "markdown")) |m| {
        const x = trim(m);
        if (x.len > 0) std.debug.print("{s}├{s}┤{s}\n{s}│{s}\n{s}\n", .{ cyan, "─" ** 56, reset, cyan, reset, x });
    }

    if (extractTag(content, "finish_reason")) |fr| {
        const fr_trimmed = trim(fr);
        if (fr_trimmed.len > 0) {
            const fr_display = if (std.mem.eql(u8, fr_trimmed, "stop"))
                "stop"
            else if (std.mem.eql(u8, fr_trimmed, "tool_calls"))
                "tool_calls"
            else if (std.mem.eql(u8, fr_trimmed, "length"))
                "length"
            else if (std.mem.eql(u8, fr_trimmed, "content_filter"))
                "content_filter"
            else
                fr_trimmed;
            std.debug.print("{s}│{s} ✓ {s}Finish: {s}{s}\n", .{ cyan, reset, green, fr_display, reset });
        }
    }

    std.debug.print("{s}└{s}┘{s}\n\n", .{ cyan, "─" ** 56, reset });
}

pub const KEBINDING = enum(u8) {
    CTRL_C = 3,
    ENTER = 13,
};

pub fn main() !void {
    try spawnBackend();
    try waitForSocket(10000);

    const socket_fd = try connectToSocket();
    defer std.posix.close(socket_fd);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("{s}Connected!{s}\n", .{ green, reset });
    std.debug.print("Type message and press Enter. Ctrl+C to exit.\n\n", .{});

    const session_id: []u8 = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});
    defer allocator.free(session_id);

    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);

    std.debug.print("{s}>{s} ", .{ bold, reset });

    while (true) {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;

        if (n == 0) {
            std.Thread.sleep(10000000);
            continue;
        }

        const c = buf[0];

        if (c == @intFromEnum(KEBINDING.CTRL_C)) break;

        if (c == 127 or c == 8) {
            if (input.items.len > 0) {
                _ = input.pop();
                std.debug.print("\x08 \x08", .{});
            }
        } else if (c == 13 or c == 10 or c == @intFromEnum(KEBINDING.ENTER)) {
            if (input.items.len > 0) {
                std.debug.print("\n\n", .{});
                try sendMessage(socket_fd, session_id, input.items);

                const response = readResponseAndStream(socket_fd, allocator) catch "";
                if (response.len > 0) {
                    // Content already shown via streaming
                } else {
                    std.debug.print("{s}No response{s}\n", .{ dim, reset });
                }

                input.clearRetainingCapacity();
                std.debug.print("\n{s}>{s} ", .{ bold, reset });
            } else {
                std.debug.print("\n{s}>{s} ", .{ bold, reset });
            }
        } else if (c >= 32) {
            try input.append(allocator, c);
            std.debug.print("{c}", .{c});
        }
    }
    std.debug.print("\n{s}Bye!{s}\n", .{ dim, reset });
}

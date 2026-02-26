const std = @import("std");
const builtin = @import("builtin");

const SOCKET_PATH = "/tmp/agent.sock";

const Color = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const cyan = "\x1b[36m";
    const yellow = "\x1b[33m";
    const green = "\x1b[32m";
    const magenta = "\x1b[35m";
    const blue = "\x1b[34m";
};

const sockaddr_un = if (builtin.os.tag != .windows)
    extern struct {
        sun_family: c_ushort,
        sun_path: [108]u8,
    }
else
    void;

fn connectToSocket() !std.posix.fd_t {
    const socket_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    errdefer std.posix.close(socket_fd);

    const path_len = SOCKET_PATH.len;
    const addr_len = @sizeOf(sockaddr_un);
    var addr = std.mem.zeroInit(sockaddr_un, .{});
    addr.sun_family = std.posix.AF.UNIX;
    @memcpy(addr.sun_path[0..path_len], SOCKET_PATH);
    addr.sun_path[path_len] = 0;

    try std.posix.connect(socket_fd, @as(*std.posix.sockaddr, @ptrCast(&addr)), addr_len);
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

fn readResponse(socket_fd: std.posix.fd_t, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var buf: [1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(socket_fd, &buf) catch break;
        if (n == 0) break;
        try buffer.appendSlice(allocator, buf[0..n]);
        if (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '\n') break;
    }

    return try buffer.toOwnedSlice(allocator);
}

fn resetTerminal() void {
    std.debug.print("\x1b[0m\x1b[?1000l\x1b[?1006l\x1b[?1015l", .{});
}

fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    const start_tag = std.fmt.allocPrint(std.heap.page_allocator, "<{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(start_tag);
    const end_tag = std.fmt.allocPrint(std.heap.page_allocator, "</{s}>", .{tag}) catch return null;
    defer std.heap.page_allocator.free(end_tag);

    const start = std.mem.indexOf(u8, xml, start_tag) orelse return null;
    const content_start = start + start_tag.len;
    const end = std.mem.indexOf(u8, xml[content_start..], end_tag) orelse return null;

    return xml[content_start .. content_start + end];
}

fn trimSpaces(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n' or s[start] == '\r' or s[start] == '\t')) : (start += 1) {}
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n' or s[end - 1] == '\r' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

fn printPrettyResponse(response: []const u8) void {
    std.debug.print("\n{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n", .{ Color.cyan, Color.reset });

    if (extractTag(response, "agent")) |agent_name| {
        const trimmed = trimSpaces(agent_name);
        std.debug.print("{s}🤖 Agent:{s} {s}{s}{s}\n", .{ Color.yellow, Color.reset, Color.bold, trimmed, Color.reset });
    }

    if (extractTag(response, "thought")) |thought| {
        const trimmed = trimSpaces(thought);
        if (trimmed.len > 0) {
            std.debug.print("{s}💭 Thought:{s}\n{s}\n", .{ Color.dim, Color.reset, trimmed });
        }
    }

    if (extractTag(response, "markdown")) |markdown| {
        const trimmed = trimSpaces(markdown);
        if (trimmed.len > 0) {
            std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n", .{ Color.cyan, Color.reset });
            std.debug.print("{s}\n", .{trimmed});
        }
    }

    std.debug.print("{s}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{s}\n\n", .{ Color.cyan, Color.reset });
}

pub fn main() !void {
    resetTerminal();
    defer resetTerminal();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("{s}Connecting to agent...{s}\n", .{ Color.dim, Color.reset });

    const socket_fd = connectToSocket() catch {
        std.debug.print("{s}Failed to connect to agent. Is it running? (zig build run){s}\n", .{ Color.dim, Color.reset });
        return error.ConnectionFailed;
    };
    defer std.posix.close(socket_fd);

    std.debug.print("{s}Connected!{s} Type your message and press Enter.\n\n", .{ Color.green, Color.reset });

    var input_buf = std.ArrayList(u8).empty;
    defer input_buf.deinit(allocator);

    const session_id: []u8 = try std.fmt.allocPrint(allocator, "session_{}", .{std.time.timestamp()});
    defer allocator.free(session_id);

    std.debug.print("{s}>{s} ", .{ Color.bold, Color.reset });

    while (true) {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
        if (n > 0) {
            const c = buf[0];
            if (c == 3) {
                break;
            } else if (c == 127 or c == 8) {
                if (input_buf.items.len > 0) {
                    _ = input_buf.pop();
                    std.debug.print("\x08 \x08", .{});
                }
            } else if (c == 13 or c == 10) {
                if (input_buf.items.len > 0) {
                    std.debug.print("\n\n", .{});
                    try sendMessage(socket_fd, session_id, input_buf.items);

                    const response = readResponse(socket_fd, allocator) catch "";
                    defer allocator.free(response);

                    if (response.len > 0) {
                        printPrettyResponse(response);
                    } else {
                        std.debug.print("{s}No response{s}\n", .{ Color.dim, Color.reset });
                    }

                    input_buf.clearRetainingCapacity();
                    std.debug.print("{s}>{s} ", .{ Color.bold, Color.reset });
                } else {
                    std.debug.print("\n{s}>{s} ", .{ Color.bold, Color.reset });
                }
            } else if (c >= 32) {
                try input_buf.append(allocator, c);
                std.debug.print("{c}", .{c});
            }
        }
        std.Thread.sleep(10000000);
    }

    std.debug.print("\n{s}Goodbye!{s}\n", .{ Color.dim, Color.reset });
}

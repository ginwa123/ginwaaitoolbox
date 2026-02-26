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

fn streamResponse(socket_fd: std.posix.fd_t, timeout_ms: u32) !void {
    var buffer: [4096]u8 = undefined;
    var buf_pos: usize = 0;
    const deadline = std.time.milliTimestamp() + timeout_ms;
    var in_content = false;
    var content_started = false;

    std.debug.print("{s}▸{s} ", .{ yellow, reset });

    while (std.time.milliTimestamp() < deadline) {
        var fds = [_]std.posix.pollfd{.{ .fd = socket_fd, .events = std.posix.POLL.IN, .revents = undefined }};
        const time_left = @as(u32, @intCast(deadline - std.time.milliTimestamp()));
        const ready = std.posix.poll(&fds, @min(100, @as(i32, @intCast(time_left)))) catch break;
        if (ready == 0) continue;
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;

        const n = std.posix.read(socket_fd, buffer[buf_pos..]) catch break;
        if (n == 0) break;
        buf_pos += n;

        // Process buffer and extract content
        var i: usize = 0;
        while (i < buf_pos) {
            if (buffer[i] == '<') {
                // Check for <content> tag
                if (i + 8 < buf_pos and std.mem.eql(u8, buffer[i .. i + 8], "<content>")) {
                    in_content = true;
                    i += 8;
                    continue;
                }
                // Check for </content> tag
                if (i + 9 < buf_pos and std.mem.eql(u8, buffer[i .. i + 9], "</content>")) {
                    in_content = false;
                    i += 9;
                    continue;
                }
                // Check for </response> - end of stream
                if (i + 11 < buf_pos and std.mem.eql(u8, buffer[i .. i + 11], "</response>")) {
                    std.debug.print("\n", .{});
                    return;
                }
            }
            if (in_content) {
                std.debug.print("{c}", .{buffer[i]});
                content_started = true;
            }
            i += 1;
        }

        // Shift remaining to beginning
        if (i < buf_pos) {
            @memcpy(buffer[0 .. buf_pos - i], buffer[i..buf_pos]);
            buf_pos = buf_pos - i;
        } else {
            buf_pos = 0;
        }
    }
    std.debug.print("\n", .{});
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

    std.debug.print("{s}└{s}┘{s}\n\n", .{ cyan, "─" ** 56, reset });
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

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\n')) start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\n')) end -= 1;
    return s[start..end];
}

pub fn main() !void {
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

        if (c == 3) break;

        if (c == 127 or c == 8) {
            if (input.items.len > 0) {
                _ = input.pop();
                std.debug.print("\x08 \x08", .{});
            }
        } else if (c == 13 or c == 10) {
            if (input.items.len > 0) {
                std.debug.print("\n\n", .{});
                try sendMessage(socket_fd, session_id, input.items);

                // Stream the response
                streamResponse(socket_fd, 60000) catch {
                    std.debug.print("{s}Stream error{s}\n", .{ dim, reset });
                };

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

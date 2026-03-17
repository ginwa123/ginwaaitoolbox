const std = @import("std");
const globals = @import("../globals.zig");

/// Escape a string for JSON output
fn escapeJsonString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return "",
            '\\' => result.appendSlice(allocator, "\\\\") catch return "",
            '\n' => result.appendSlice(allocator, "\\n") catch return "",
            '\r' => result.appendSlice(allocator, "\\r") catch return "",
            '\t' => result.appendSlice(allocator, "\\t") catch return "",
            else => result.append(allocator, c) catch return "",
        }
    }

    return allocator.dupe(u8, result.items) catch "";
}

/// Send a message to the server via HTTP POST
pub fn sendMessage(app: anytype, message: []const u8) !void {
    const cwd = std.process.getCwdAlloc(app.arena.allocator()) catch "";
    const escaped_msg = escapeJsonString(app.arena.allocator(), message);
    const escaped_cwd = escapeJsonString(app.arena.allocator(), cwd);
    const json_payload = try std.fmt.allocPrint(app.arena.allocator(),
        \\{{"app_type":"tui","command_type":"run_llm","session_id":"{s}","content":"{s}","cwd_session":"{s}"}}
    , .{ app.session_id, escaped_msg, escaped_cwd });
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(app.arena.allocator(), "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

/// Send a double_escape command to unregister session from cancellation registry
pub fn sendDoubleEscapeCommand(app: anytype) !void {
    const json_payload = try std.fmt.allocPrint(app.arena.allocator(),
        \\{{"app_type":"tui","command_type":"double_escape","session_id":"{s}"}}
    , .{app.session_id});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(app.arena.allocator(), "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

/// Send a get_sessions command to list active sessions
pub fn sendSessionsCommand(app: anytype) !void {
    const json_payload = try std.fmt.allocPrint(app.arena.allocator(),
        \\{{"app_type":"tui","command_type":"get_sessions"}}
    , .{});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(app.arena.allocator(), "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

/// Send a ping request to the server to check if the session is still connected
/// This prevents "session not found" errors when the server's SSE stream handler
/// thread exits while the TUI is still running a long operation
/// Returns true if reconnect is needed, false otherwise
pub fn sendPingCommand(app: anytype) !bool {
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));

    // Use the new synchronous ping endpoint
    const request = try std.fmt.allocPrint(app.arena.allocator(), "GET /api/ping/{s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(sock, request);

    // Read response to check if reconnect is needed
    var buf: [1024]u8 = undefined;
    const n = std.posix.read(sock, &buf) catch return false;
    if (n > 0) {
        const response = buf[0..n];
        if (std.mem.indexOf(u8, response, "\"reconnect\":true") != null) {
            return true; // Need to reconnect
        }
    }
    return false;
}

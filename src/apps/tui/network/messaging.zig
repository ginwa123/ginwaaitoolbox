const std = @import("std");
const globals = @import("../globals.zig");
const App = @import("../main.zig").App;

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
pub fn sendMessage(app: *App, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd = std.process.getCwdAlloc(allocator) catch "";
    const escaped_msg = escapeJsonString(allocator, message);
    const escaped_cwd = escapeJsonString(allocator, cwd);
    const json_payload = try std.fmt.allocPrint(allocator,
        \\{{"app_type":"tui","command_type":"run_llm","session_id":"{s}","content":"{s}","cwd_session":"{s}"}}
    , .{ app.session_id, escaped_msg, escaped_cwd });
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(allocator, "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

/// Send a double_escape command to unregister session from cancellation registry
pub fn sendDoubleEscapeCommand(app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_payload = try std.fmt.allocPrint(allocator,
        \\{{"app_type":"tui","command_type":"double_escape","session_id":"{s}"}}
    , .{app.session_id});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(allocator, "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

/// Send a get_sessions command to list active sessions
pub fn sendSessionsCommand(app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_payload = try std.fmt.allocPrint(allocator,
        \\{{"app_type":"tui","command_type":"get_sessions"}}
    , .{});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(allocator, "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

/// Send a ping request to the server to check if the session is still connected
/// This prevents "session not found" errors when the server's SSE stream handler
/// thread exits while the TUI is still running a long operation
/// Returns true if reconnect is needed, false otherwise
pub fn sendPingCommand(app: *App) !bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();


    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));

    // Use the new synchronous ping endpoint
    const request = try std.fmt.allocPrint(allocator, "GET /api/ping/{s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
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

/// Check if a session exists in the database
/// Returns true if session exists, false otherwise
pub fn check_session_exists(app: *App) !bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));

    const request = try std.fmt.allocPrint(allocator, "GET /api/session/exists/{s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(sock, request);

    // Read response to check if session exists
    var buf: [1024]u8 = undefined;
    const n = std.posix.read(sock, &buf) catch return false;
    if (n > 0) {
        const response = buf[0..n];
        // Parse JSON response: {"session_id":"...","exists":true/false}
        if (std.mem.indexOf(u8, response, "\"exists\":true") != null) {
            return true;
        }
    }
    return false;
}

/// Get the latest session for a given working directory
/// Returns the session_id if found, null otherwise
pub fn get_latest_session_by_dir(allocator: std.mem.Allocator, http_port: u16, cwd: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));

    // URL encode the cwd for the query parameter
    // For simplicity, we'll assume the cwd doesn't contain special URL chars that need encoding
    const request = try std.fmt.allocPrint(alloc, "GET /api/session/latest?cwd={s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ cwd, globals.HTTP_HOST, http_port });
    _ = try std.posix.write(sock, request);

    // Read response
    var buf: [2048]u8 = undefined;
    const n = std.posix.read(sock, &buf) catch return error.ConnectionFailed;
    if (n > 0) {
        const response = buf[0..n];
        // Parse JSON response: {"session_id":"...","found":true} or {"found":false}
        if (std.mem.indexOf(u8, response, "\"found\":true") != null) {
            // Extract session_id from the response
            // Format: {"session_id":"abc123","session_dir":"/path","created_at":"...","found":true}
            if (std.mem.indexOf(u8, response, "\"session_id\":\"")) |idx| {
                const start = idx + 14; // length of "\"session_id\":\""
                var end = start;
                while (end < response.len and response[end] != '"') : (end += 1) {}
                return try allocator.dupe(u8, response[start..end]);
            }
        }
    }
    return null;
}

/// Send a get_history command to retrieve session conversation history
pub fn sendHistoryCommand(app: App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_payload = try std.fmt.allocPrint(allocator,
        \\{{"app_type":"tui","command_type":"get_history","session_id":"{s}"}}
    , .{app.session_id});
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));
    const request = try std.fmt.allocPrint(allocator, "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });
    _ = try std.posix.write(sock, request);
}

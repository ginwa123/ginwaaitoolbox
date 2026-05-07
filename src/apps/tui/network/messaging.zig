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

    const cwd = std.process.currentPathAlloc(app.io, allocator) catch "";
    const escaped_msg = escapeJsonString(allocator, message);
    const escaped_cwd = escapeJsonString(allocator, cwd);
    allocator.free(cwd);

    const json_payload = try std.fmt.allocPrint(allocator,
        \\{{"session_id":"{s}","queue_message":"{s}","cwd_session":"{s}","allowed_tools":"all"}}
    , .{ app.session_id, escaped_msg, escaped_cwd });

    // Use high-level std.Io.net API to connect
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", app.http_port);
    const stream = try std.Io.net.IpAddress.connect(&address, app.io, .{ .mode = .stream });
    defer stream.close(app.io);

    const request = try std.fmt.allocPrint(allocator, "POST /api/session HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ globals.HTTP_HOST, app.http_port, json_payload.len, json_payload });

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(app.io, &write_buf);
    try std.Io.Writer.writeAll(&writer.interface, request);
    try writer.interface.flush();
}

/// Send a double_escape command to cancel the session
pub fn sendDoubleEscapeCommand(app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketCreationFailed;
    defer _ = std.c.close(sock);
    var addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = @intCast(app.http_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.ConnectionFailed;
    const request = try std.fmt.allocPrint(allocator, "POST /api/session/{s}/cancel HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = std.c.write(sock, request.ptr, request.len);
}

/// Send a get_sessions command to list active sessions
pub fn sendSessionsCommand(app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketCreationFailed;
    defer _ = std.c.close(sock);
    var addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = @intCast(app.http_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.ConnectionFailed;
    const request = try std.fmt.allocPrint(allocator, "GET /api/session HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ globals.HTTP_HOST, app.http_port });
    _ = std.c.write(sock, request.ptr, request.len);
}

/// Send a ping request to the server to check if the session is still connected
/// This prevents "session not found" errors when the server's SSE stream handler
/// thread exits while the TUI is still running a long operation
/// Returns true if reconnect is needed, false otherwise
pub fn send_ping_command(app: *App) !bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketCreationFailed;
    defer _ = std.c.close(sock);
    var addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = @intCast(app.http_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.ConnectionFailed;

    const request = try std.fmt.allocPrint(allocator, "GET /api/ping/{s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = std.c.write(sock, request.ptr, request.len);

    var buf: [1024]u8 = undefined;
    const n = std.c.read(sock, &buf, buf.len);
    if (n <= 0) return false;
    const response = buf[0..@intCast(n)];
    if (std.mem.indexOf(u8, response, "\"reconnect\":true") != null) {
        return true;
    }
    return false;
}

/// Check if a session exists in the database
/// Returns true if session exists, false otherwise
pub fn check_session_exists(app: *App) !bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", app.http_port);
    const stream = try std.Io.net.IpAddress.connect(&address, app.io, .{ .mode = .stream });
    defer stream.socket.close(app.io);

    const request = try std.fmt.allocPrint(allocator, "GET /api/session/exists/{s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    defer allocator.free(request);

    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(app.io, &write_buffer);
    try std.Io.Writer.writeAll(&writer.interface, request);

    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(app.io, &read_buffer);
    const n = std.Io.Reader.readSliceShort(&reader.interface, &read_buffer) catch return false;
    if (n > 0) {
        const response = read_buffer[0..n];
        if (std.mem.indexOf(u8, response, "\"exists\":true") != null) {
            return true;
        }
    }
    return false;
}

/// Get the latest session for a given working directory
/// Returns the session_id if found, null otherwise
pub fn get_latest_session_by_dir(allocator: std.mem.Allocator, io: std.Io, http_port: u16, cwd: []const u8) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const addr: std.Io.net.IpAddress = .{ .ip4 = std.Io.net.Ip4Address.loopback(http_port) };
    var stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    const request = try std.fmt.allocPrint(alloc, "GET /api/session/latest?cwd={s} HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ cwd, globals.HTTP_HOST, http_port });
    var write_buf: [1024]u8 = undefined;
    var stream_writer = std.Io.net.Stream.Writer.init(stream, io, &write_buf);
    try stream_writer.interface.writeAll(request);

    var read_buf: [2048]u8 = undefined;
    var stream_reader = std.Io.net.Stream.Reader.init(stream, io, &read_buf);
    var slices: [1][]u8 = .{read_buf[0..]};
    const n = try stream_reader.interface.readVec(&slices);
    if (n > 0) {
        const response = read_buf[0..n];
        if (std.mem.indexOf(u8, response, "\"found\":true") != null) {
            if (std.mem.indexOf(u8, response, "\"session_id\":\"")) |idx| {
                const start = idx + 14;
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

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketCreationFailed;
    defer _ = std.c.close(sock);
    var addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = @intCast(app.http_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.ConnectionFailed;
    const request = try std.fmt.allocPrint(allocator, "GET /api/session/{s}/messages HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = std.c.write(sock, request.ptr, request.len);
}

/// Send a compact command to manually trigger conversation history compaction
pub fn sendCompactCommand(app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketCreationFailed;
    defer _ = std.c.close(sock);
    var addr = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = @intCast(app.http_port),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.ConnectionFailed;
    const request = try std.fmt.allocPrint(allocator, "POST /api/session/{s}/compact HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = std.c.write(sock, request.ptr, request.len);
}

/// Get the latest message with finish_reason="stop" for a session
/// Returns true if the latest message has finish_reason="stop"
/// This is used during streaming to detect when the LLM has finished
pub fn get_latest_message_by_created_at(app: *App) !bool {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Use high-level std.Io.net API
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", app.http_port);
    const stream = try std.Io.net.IpAddress.connect(&address, app.io, .{ .mode = .stream });
    defer stream.close(app.io);

    const request = try std.fmt.allocPrint(allocator, "GET /api/session/{s}/messages?sort_by=created_at&direction=desc&limit=1 HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(app.io, &write_buf);
    try std.Io.Writer.writeAll(&writer.interface, request);
    try writer.interface.flush();

    var response_buf = std.ArrayList(u8).empty;
    defer response_buf.deinit(allocator);
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(app.io, &read_buf);

    while (true) {
        const n = std.Io.Reader.readSliceShort(&reader.interface, &read_buf) catch break;
        if (n == 0) break;
        try response_buf.appendSlice(allocator, read_buf[0..n]);
    }

    const full_response = response_buf.items;
    if (full_response.len == 0) return false;

    const header_sep = "\r\n\r\n";
    const body_offset = std.mem.indexOf(u8, full_response, header_sep) orelse return false;
    const body = full_response[body_offset + header_sep.len ..];

    if (std.mem.indexOf(u8, body, "\"finish_reason\":\"stop\"")) |_| {
        return true;
    }

    if (std.mem.indexOf(u8, body, "\"finish_reason\":\"user_choice\"")) |_| {
        return true;
    }

    return false;
}

/// Fetch the raw HTTP response body of the latest message for a session.
/// Returns the JSON body as a caller-owned slice, or null if not found.
/// The body format is: {"messages":[{"id":"...","role":"assistant","content":"...", ...}]}
pub fn fetch_latest_message_body(app: *App) !?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Use high-level std.Io.net API
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", app.http_port);
    const stream = try std.Io.net.IpAddress.connect(&address, app.io, .{ .mode = .stream });
    defer stream.close(app.io);

    const request = try std.fmt.allocPrint(alloc, "GET /api/session/{s}/messages?sort_by=created_at&direction=desc&limit=1 HTTP/1.0\r\nHost: {s}:{d}\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });

    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(app.io, &write_buf);
    try std.Io.Writer.writeAll(&writer.interface, request);
    try writer.interface.flush();

    var response_buf = std.ArrayList(u8).empty;
    defer response_buf.deinit(alloc);
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(app.io, &read_buf);

    while (true) {
        const n = std.Io.Reader.readSliceShort(&reader.interface, &read_buf) catch break;
        if (n == 0) break;
        try response_buf.appendSlice(alloc, read_buf[0..n]);
    }

    const full_response = response_buf.items;
    if (full_response.len == 0) return null;

    const header_sep = "\r\n\r\n";
    const body_offset = std.mem.indexOf(u8, full_response, header_sep) orelse return null;
    const body = full_response[body_offset + header_sep.len ..];
    if (body.len == 0) return null;

    return try app.allocator.dupe(u8, body);
}

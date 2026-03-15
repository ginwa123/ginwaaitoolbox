const std = @import("std");

/// Default HTTP server port
const DEFAULT_PORT: u16 = 8080;
const HTTP_HOST = "127.0.0.1";

/// Version info
const VERSION = "0.1.0";

/// Escape a string for JSON
fn escapeJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);
    const writer = escaped.writer(allocator);

    for (input) |c| {
        switch (c) {
            '"' => { try writer.writeByte('\\'); try writer.writeByte('"'); },
            '\\' => { try writer.writeByte('\\'); try writer.writeByte('\\'); },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }

    return escaped.toOwnedSlice(allocator);
}

// ─── SSE Parsing ─────────────────────────────────────────────────────────────

/// Strips HTTP headers and chunk size lines, returns raw SSE text.
fn decodeChunked(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // Skip HTTP response headers if present
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n");
    var pos: usize = if (header_end) |end| end + 4 else 0;

    // Check if this looks like chunked encoding (starts with hex number)
    const maybe_chunked = pos < raw.len and
        (std.ascii.isHex(raw[pos]) or raw[pos] == '\r' or raw[pos] == '\n');

    if (maybe_chunked and header_end != null) {
        // Parse chunked encoding
        while (pos < raw.len) {
            // Find end of chunk size line
            const size_end = std.mem.indexOfPos(u8, raw, pos, "\r\n") orelse break;
            const size_str = std.mem.trim(u8, raw[pos..size_end], " \t");
            if (size_str.len == 0) {
                pos = size_end + 2;
                continue;
            }

            // Parse hex chunk size
            const chunk_size = std.fmt.parseInt(usize, size_str, 16) catch {
                pos = size_end + 2;
                continue;
            };

            if (chunk_size == 0) break; // end of chunked stream

            pos = size_end + 2;
            if (pos + chunk_size > raw.len) break; // incomplete, wait for more data

            try out.appendSlice(allocator, raw[pos .. pos + chunk_size]);
            pos += chunk_size;

            // Skip trailing \r\n after chunk data
            if (pos + 2 <= raw.len and raw[pos] == '\r' and raw[pos + 1] == '\n') {
                pos += 2;
            }
        }
    } else {
        // No chunked encoding - just return body (or entire input if no headers)
        try out.appendSlice(allocator, raw[pos..]);
    }

    return out.toOwnedSlice(allocator);
}

/// After chunked decode, SSE lines look like:
///   data: {"event":"chunk","data":"<xml escaped>"}
///   : keepalive
///
/// This extracts and unescapes the "data" JSON field value from each data: line.
fn extractSseData(allocator: std.mem.Allocator, sse_text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, sse_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");

        // Skip empty lines (SSE event boundaries)
        if (trimmed.len == 0) continue;

        // Skip comment lines (keepalive, etc.)
        if (std.mem.startsWith(u8, trimmed, ":")) continue;

        // Skip event type lines - we just want the data
        if (std.mem.startsWith(u8, trimmed, "event:")) continue;

        // Extract data lines
        if (std.mem.startsWith(u8, trimmed, "data:")) {
            const payload = trimmed["data:".len..];
            // Add newline separator between data lines (SSE spec)
            if (out.items.len > 0) {
                try out.append(allocator, '\n');
            }
            try out.appendSlice(allocator, payload);
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Extract content from XML tag
fn extractTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    var close_tag_buf: [128]u8 = undefined;
    var open_tag_buf: [128]u8 = undefined;

    const close_tag = std.fmt.bufPrint(&close_tag_buf, "</{s}>", .{tag}) catch return null;
    const open_tag = std.fmt.bufPrint(&open_tag_buf, "<{s}>", .{tag}) catch return null;

    const close_pos = std.mem.lastIndexOf(u8, xml, close_tag) orelse return null;
    const open_pos = std.mem.lastIndexOf(u8, xml[0..close_pos], open_tag) orelse return null;
    return xml[open_pos + open_tag.len .. close_pos];
}

/// Wait for SSE "connected" event from server
fn waitForSseConnected(socket: std.posix.fd_t, timeout_ms: u64) bool {
    var buf: [4096]u8 = undefined;
    const start = std.time.milliTimestamp();

    while (true) {
        if (std.time.milliTimestamp() - start > timeout_ms) return false;

        var poll_fd = [1]std.posix.pollfd{
            .{ .fd = socket, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const ready = std.posix.poll(&poll_fd, 100) catch 0;
        if (ready > 0 and (poll_fd[0].revents & std.posix.POLL.IN != 0)) {
            const n = std.posix.read(socket, &buf) catch return false;
            if (n == 0) return false;
            if (std.mem.indexOf(u8, buf[0..n], "event: connected") != null) {
                return true;
            }
        }
    }
}

/// Reconnect to SSE stream
fn reconnectSseStream(allocator: std.mem.Allocator, session_id: []const u8, current_socket: std.posix.fd_t) std.posix.fd_t {
    // Close old socket
    std.posix.close(current_socket);

    // Create new socket
    const new_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return -1;

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, DEFAULT_PORT);
    std.posix.connect(new_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        std.posix.close(new_socket);
        return -1;
    };

    // Send stream request
    const stream_request = std.fmt.allocPrint(allocator,
        "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n",
        .{ session_id, HTTP_HOST, DEFAULT_PORT }
    ) catch {
        std.posix.close(new_socket);
        return -1;
    };

    _ = std.posix.write(new_socket, stream_request) catch {
        std.posix.close(new_socket);
        return -1;
    };

    // Wait for connected event
    if (!waitForSseConnected(new_socket, 5000)) {
        std.posix.close(new_socket);
        return -1;
    }

    return new_socket;
}

/// Send a message to the server
fn sendMessage(allocator: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd_session: []const u8) !void {
    // Escape the message for JSON - handle special characters
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);
    var writer = escaped.writer(allocator);

    for (message) |c| {
        switch (c) {
            '"' => { try writer.writeByte('\\'); try writer.writeByte('"'); },
            '\\' => { try writer.writeByte('\\'); try writer.writeByte('\\'); },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }

    // Build JSON payload - simple approach without complex string manipulation
    // Calculate total size needed
    const session_id_len = session_id.len;
    const content_len = escaped.items.len;

    // Escape cwd_session for JSON
    var escaped_cwd = std.ArrayList(u8).empty;
    errdefer escaped_cwd.deinit(allocator);
    var cwd_writer = escaped_cwd.writer(allocator);
    for (cwd_session) |c| {
        switch (c) {
            '"' => { try cwd_writer.writeByte('\\'); try cwd_writer.writeByte('"'); },
            '\\' => { try cwd_writer.writeByte('\\'); try cwd_writer.writeByte('\\'); },
            '\n' => try cwd_writer.writeAll("\\n"),
            '\r' => try cwd_writer.writeAll("\\r"),
            '\t' => try cwd_writer.writeAll("\\t"),
            else => try cwd_writer.writeByte(c),
        }
    }
    const escaped_cwd_len = escaped_cwd.items.len;

    // Calculate total size needed:
    // {"app_type":"cli","command_type":"run_llm","session_id":" = 57 chars
    // ","content":" = 13 chars
    // ","cwd_session":" = 15 chars
    // "} = 2 chars
    // Total fixed: 57 + 13 + 17 + 2 = 89 characters + session_id_len + content_len + escaped_cwd_len
    const total_size = 89 + session_id_len + content_len + escaped_cwd_len;

    var json_payload = try allocator.alloc(u8, total_size);
    errdefer allocator.free(json_payload);

    // Build the JSON manually
    var pos: usize = 0;

    // {"app_type":"cli","command_type":"run_llm","session_id":"
    @memcpy(json_payload[pos..][0..57], "{\"app_type\":\"cli\",\"command_type\":\"run_llm\",\"session_id\":\"");
    pos += 57;

    // session_id value
    std.debug.print("DEBUG sendMessage: session_id = '{s}', len={d}, payload pos={d}, copy_len={d}\n", .{ session_id, session_id.len, pos, session_id_len });
    std.debug.print("DEBUG sendMessage: json_payload ptr={*}, capacity={d}\n", .{ json_payload.ptr, json_payload.len });
    @memcpy(json_payload[pos..][0..session_id_len], session_id);
    pos += session_id_len;

    // ","content":"
    @memcpy(json_payload[pos..][0..13], "\",\"content\":\"");
    pos += 13;

    // escaped content
    @memcpy(json_payload[pos..][0..content_len], escaped.items);
    pos += content_len;

    // ","cwd_session":"<escaped_cwd>"}
    @memcpy(json_payload[pos..][0..17], "\",\"cwd_session\":\"");
    pos += 17;

    @memcpy(json_payload[pos..][0..escaped_cwd_len], escaped_cwd.items);
    pos += escaped_cwd_len;

    // "}
    @memcpy(json_payload[pos..][0..2], "\"}");
    pos += 2;

    std.debug.assert(pos == total_size);

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, DEFAULT_PORT);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));

    std.debug.print("DEBUG: creating HTTP request\n", .{});

    const request = try std.fmt.allocPrint(allocator,
        "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ HTTP_HOST, DEFAULT_PORT, json_payload.len, json_payload }
    );

    _ = try std.posix.write(sock, request);
    allocator.free(request);
}

/// Send message through an already-connected socket (TUI pattern)
fn sendMessageViaSocket(allocator: std.mem.Allocator, sock: std.posix.fd_t, session_id: []const u8, message: []const u8, cwd_session: []const u8) !void {
    // Escape the message for JSON - handle special characters
    var escaped = std.ArrayList(u8).empty;
    errdefer escaped.deinit(allocator);
    var writer = escaped.writer(allocator);

    for (message) |c| {
        switch (c) {
            '"' => { try writer.writeByte('\\'); try writer.writeByte('"'); },
            '\\' => { try writer.writeByte('\\'); try writer.writeByte('\\'); },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }

    // Escape cwd_session for JSON
    var escaped_cwd = std.ArrayList(u8).empty;
    errdefer escaped_cwd.deinit(allocator);
    var cwd_writer = escaped_cwd.writer(allocator);
    for (cwd_session) |c| {
        switch (c) {
            '"' => { try cwd_writer.writeByte('\\'); try cwd_writer.writeByte('"'); },
            '\\' => { try cwd_writer.writeByte('\\'); try cwd_writer.writeByte('\\'); },
            '\n' => try cwd_writer.writeAll("\\n"),
            '\r' => try cwd_writer.writeAll("\\r"),
            '\t' => try cwd_writer.writeAll("\\t"),
            else => try cwd_writer.writeByte(c),
        }
    }

    const json_payload = try std.fmt.allocPrint(allocator,
        \\{{"app_type":"cli","command_type":"run_llm","session_id":"{s}","content":"{s}","cwd_session":"{s}"}}
    , .{ session_id, escaped.items, escaped_cwd.items });

    const request = try std.fmt.allocPrint(allocator,
        "POST /api/command HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ HTTP_HOST, DEFAULT_PORT, json_payload.len, json_payload }
    );

    _ = try std.posix.write(sock, request);
    allocator.free(request);
}

/// Send a ping request to check if session is still connected
fn sendPingCommand(allocator: std.mem.Allocator, session_id: []const u8) !bool {
    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, DEFAULT_PORT);
    try std.posix.connect(sock, &addr.any, @sizeOf(std.net.Address));

    // Use the new synchronous ping endpoint
    const request = try std.fmt.allocPrint(allocator,
        "GET /api/ping/{s} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n",
        .{ session_id, HTTP_HOST, DEFAULT_PORT }
    );
    _ = try std.posix.write(sock, request);

    // Read response
    var buf: [1024]u8 = undefined;
    const n = std.posix.read(sock, &buf) catch return false;
    if (n > 0) {
        const response = buf[0..n];
        if (std.mem.indexOf(u8, response, "\"reconnect\":true") != null) {
            return true;
        }
    }
    return false;
}

/// Tool result structure
const ToolResult = struct {
    id: []u8,
    name: []u8,
    result: []u8,
};

/// Extract tool results from XML
fn extractToolResults(allocator: std.mem.Allocator, xml: []const u8) !std.ArrayList(ToolResult) {
    var results = std.ArrayList(ToolResult).empty;
    errdefer results.deinit(allocator);

    var pos: usize = 0;
    while (pos < xml.len) {
        const tool_result_start = std.mem.indexOfPos(u8, xml, pos, "<tool_result>") orelse break;
        const tool_result_end = std.mem.indexOfPos(u8, xml, tool_result_start, "</tool_result>") orelse break;
        const tool_result_block = xml[tool_result_start..tool_result_end];
        pos = tool_result_end + "</tool_result>".len;

        const id = extractTag(tool_result_block, "tool_call_id") orelse "";
        const name = extractTag(tool_result_block, "tool_name") orelse "";
        const result = extractTag(tool_result_block, "result") orelse "";

        if (id.len > 0) {
            try results.append(allocator, .{
                .id = try allocator.dupe(u8, id),
                .name = try allocator.dupe(u8, name),
                .result = try allocator.dupe(u8, result),
            });
        }
    }
    return results;
}

/// Display bash tool result
fn displayBashResult(result_xml: []const u8) void {
    const stdout = std.mem.trim(u8, extractTag(result_xml, "stdout") orelse "", &std.ascii.whitespace);
    const stderr = extractTag(result_xml, "stderr");

    if (stdout.len > 0) {
        std.debug.print("\n[bash stdout]\n{s}\n", .{stdout});
    }
    if (stderr != null and stderr.?.len > 0) {
        std.debug.print("\n[bash stderr]\n{s}\n", .{stderr.?});
    }
}

/// Stream response using raw sockets (TUI pattern)
/// Now follows TUI pattern: create stream socket first, then send message
fn streamResponse(allocator: std.mem.Allocator, session_id: []const u8, message: []const u8, cwd_session: []const u8) !void {
    const SSE_TIMEOUT_MS: i64 = 30000;
    const PING_INTERVAL_MS: i64 = 5000;

    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var last_ping_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;
    const MAX_RECONNECTION_ATTEMPTS: u32 = 100;

    var raw_buffer = std.ArrayList(u8).empty;
    defer raw_buffer.deinit(allocator);

    var buf: [4096]u8 = undefined;

    // Create socket for SSE streaming (TUI pattern)
    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch {
        std.debug.print("Error: Could not create socket\n", .{});
        return;
    };
    defer std.posix.close(stream_socket);

    // Enable TCP keepalive
    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    // Connect
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, DEFAULT_PORT);
    std.debug.print("DEBUG: Connecting to {s}:{d}...\n", .{ HTTP_HOST, DEFAULT_PORT });
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch {
        std.debug.print("Error: Could not connect to server\n", .{});
        return;
    };
    std.debug.print("DEBUG: Connected, sending SSE request...\n", .{});

    // Send SSE request FIRST (TUI pattern)
    const stream_request = try std.fmt.allocPrint(allocator,
        "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n",
        .{ session_id, HTTP_HOST, DEFAULT_PORT }
    );
    _ = try std.posix.write(stream_socket, stream_request);
    std.debug.print("DEBUG: SSE request sent, waiting for connected event...\n", .{});

    // Wait for SSE connected
    const connected = waitForSseConnected(stream_socket, 5000);
    std.debug.print("DEBUG: waitForSseConnected returned: {}\n", .{connected});
    if (!connected) {
        std.debug.print("Warning: SSE connection timeout\n", .{});
    }

    // Send the message via a SEPARATE socket (TUI pattern)
    // The SSE socket is for reading responses, not for sending commands
    std.debug.print("DEBUG: Sending message via separate command socket...\n", .{});
    try sendMessage(allocator, session_id, message, cwd_session);
    std.debug.print("DEBUG: Message sent, entering poll loop...\n", .{});

    // Poll for stdin (for potential interruption) and socket
    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var raw_buffer_processed_len: usize = 0;
    var last_printed_chunk_index: usize = 0;
    var displayed_tool_ids = std.ArrayList([]const u8).empty;
    defer {
        for (displayed_tool_ids.items) |id| allocator.free(id);
        displayed_tool_ids.deinit(allocator);
    }

    while (true) {
        const now = std.time.milliTimestamp();

        const ready = std.posix.poll(&poll_fds, 100) catch 0;
        std.debug.print("DEBUG poll: ready={d}, revents[0]={x}, revents[1]={x}\n", .{ ready, poll_fds[0].revents, poll_fds[1].revents });
        var new_data = false;

        if (ready > 0) {
            // Check for stdin input (could be Ctrl+C)
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                // Read and discard stdin (user typed something)
                var stdin_buf: [64]u8 = undefined;
                _ = std.posix.read(std.posix.STDIN_FILENO, &stdin_buf) catch {};
                poll_fds[1].revents = 0;
                // For now, we don't support interrupting - just continue
            }

            // Socket has data
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stream_socket, &buf) catch break;
                if (n == 0) break;
                try raw_buffer.appendSlice(allocator, buf[0..n]);
                poll_fds[0].revents = 0;
                new_data = true;
                last_data_received_ms = now;
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        } else {
            // Poll timeout - check for ping/timeout

            // Send periodic ping
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const needs_reconnect = sendPingCommand(allocator, session_id) catch false;
                if (needs_reconnect) {
                    std.debug.print("SSE session expired, reconnecting...\n", .{});
                    reconnection_attempts += 1;
                }
                last_ping_ms = now;
            }

            // Check for connection timeout
            if (now - last_data_received_ms > SSE_TIMEOUT_MS) {
                if (reconnection_attempts >= MAX_RECONNECTION_ATTEMPTS) {
                    std.debug.print("\nConnection lost. Max reconnection attempts reached.\n", .{});
                    break;
                }

                reconnection_attempts += 1;
                std.debug.print("Connection lost, reconnecting... (attempt {}/{})\n", .{ reconnection_attempts, MAX_RECONNECTION_ATTEMPTS });

                const new_socket = reconnectSseStream(allocator, session_id, stream_socket);
                if (new_socket < 0) {
                    std.debug.print("Reconnection failed.\n", .{});
                    last_data_received_ms = now;
                    continue;
                }

                stream_socket = new_socket;
                poll_fds[0].fd = stream_socket;
                last_data_received_ms = std.time.milliTimestamp();
                std.debug.print("Reconnected successfully.\n", .{});
                continue;
            }
        }

        // Process new data
        if (new_data) {
            const new_raw = raw_buffer.items[raw_buffer_processed_len..];
            if (new_raw.len == 0) continue;

            const decoded = try decodeChunked(allocator, new_raw);
            defer allocator.free(decoded);
            raw_buffer_processed_len = raw_buffer.items.len;

            const xml = try extractSseData(allocator, decoded);
            defer allocator.free(xml);

            var chunk_pos: usize = 0;
            while (std.mem.indexOfPos(u8, xml, chunk_pos, "<chunk")) |chunk_start| {
                const chunk_end = std.mem.indexOfPos(u8, xml, chunk_start, "</chunk>") orelse break;
                const chunk_block = xml[chunk_start .. chunk_end + "</chunk>".len];
                chunk_pos = chunk_end + "</chunk>".len;

                var chunk_index: usize = 0;
                if (std.mem.indexOfPos(u8, chunk_block, 0, "index=\"")) |idx_start| {
                    const idx_end = std.mem.indexOfPos(u8, chunk_block, idx_start + 7, "\"") orelse continue;
                    const idx_str = chunk_block[idx_start + 7 .. idx_end];
                    chunk_index = std.fmt.parseInt(usize, idx_str, 10) catch continue;
                }

                if (chunk_index >= last_printed_chunk_index) {
                    last_printed_chunk_index = chunk_index + 1;
                    if (extractTag(chunk_block, "content")) |content| {
                        if (content.len > 0) {
                            std.debug.print("{s}", .{content});
                        }
                    }
                }
            }

            // Handle tool results
            const tool_results = extractToolResults(allocator, xml) catch continue;
            var tool_results_val = tool_results;
            defer {
                for (tool_results_val.items) |result| {
                    allocator.free(result.id);
                    allocator.free(result.name);
                    allocator.free(result.result);
                }
                tool_results_val.deinit(allocator);
            }

            for (tool_results_val.items) |result| {
                var already_displayed = false;
                for (displayed_tool_ids.items) |id| {
                    if (std.mem.eql(u8, id, result.id)) {
                        already_displayed = true;
                        break;
                    }
                }
                if (!already_displayed) {
                    try displayed_tool_ids.append(allocator, try allocator.dupe(u8, result.id));

                    if (std.mem.eql(u8, result.name, "bash")) {
                        displayBashResult(result.result);
                    } else {
                        // Show generic tool result
                        const tool_output = std.mem.trim(u8, result.result, &std.ascii.whitespace);
                        if (tool_output.len > 0) {
                            std.debug.print("\n[tool: {s}]\n{s}\n", .{ result.name, tool_output });
                        }
                    }
                }
            }
        }
    }
}

/// Send a command to the server and stream the response
fn sendCommand(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    message: []const u8,
    cwd_session: []const u8,
    host: []const u8,
    port: u16,
) !void {
    _ = host;
    _ = port;

    std.debug.print("DEBUG sendCommand: session_id_ptr = {*}, len={d}\n", .{ &session_id, session_id.len });
    std.debug.print("DEBUG sendCommand: message_ptr = {*}, len={d}\n", .{ &message, message.len });

    std.debug.print("Sending command to {s}:{d}...\n", .{ HTTP_HOST, DEFAULT_PORT });
    std.debug.print("Streaming response...\n", .{});

    // Stream the response (this now handles the message sending - TUI pattern)
    try streamResponse(allocator, session_id, message, cwd_session);
}

/// Show help information
fn showHelp() void {
    std.debug.print(
        \\nalarcore-cli - AI assistant CLI
        \\
        \\Usage:
        \\  nalarcore [options]
        \\  nalarcore -q <prompt>
        \\  nalarcore -c <session_id> -q <prompt>
        \\
        \\Options:
        \\  -q, --query <prompt>    Send a query prompt
        \\  -c, --continue <id>    Resume an existing session
        \\  -h, --help             Show this help
        \\  -v, --version          Print version
        \\  --host <address>       Server host (default: localhost)
        \\  --port <port>          Server port (default: 8080)
        \\
        \\Examples:
        \\  nalarcore -q "What is the capital of France?"
        \\  nalarcore -c abc123 -q "Summarize that"
        \\  nalarcore --help
        \\
    , .{});
}

/// Show version information
fn showVersion() void {
    std.debug.print("nalarcore-cli version {s}\n", .{VERSION});
}

/// Interactive mode - read from stdin
fn interactiveMode(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    _ = host;
    _ = port;

    std.debug.print("nalarcore interactive mode\n", .{});
    std.debug.print("Type your query and press Enter. Press Ctrl+C to exit.\n", .{});
    std.debug.print("\n> ", .{});

    const stdin = std.fs.File.stdin();
    var line_buf: [4096]u8 = undefined;
    const n = try stdin.read(&line_buf);
    if (n > 0) {
        const line = line_buf[0..n];
        const trimmed = std.mem.trim(u8, line, " \t\n");
        if (trimmed.len > 0) {
            // Generate a simple session ID
            const session_id = try std.fmt.allocPrint(allocator, "cli_{d}", .{std.time.timestamp()});
            defer allocator.free(session_id);

            // Get current working directory
            const cwd_buf = try allocator.alloc(u8, 4096);
            defer allocator.free(cwd_buf);
            const cwd_session = try std.posix.getcwd(cwd_buf);

            try sendCommand(allocator, session_id, trimmed, cwd_session, HTTP_HOST, DEFAULT_PORT);
        }
    }
}

/// Generate a simple session ID
fn generateSessionId(allocator: std.mem.Allocator) ![]const u8 {
    // Use a fixed buffer to avoid any potential allocator issues
    var buf: [32]u8 = undefined;
    const timestamp = std.time.timestamp();
    const result = try std.fmt.bufPrint(&buf, "cli_{d}", .{timestamp});
    std.debug.print("DEBUG generateSessionId: result = '{s}'\n", .{result});
    const duped = try allocator.dupe(u8, result);
    std.debug.print("DEBUG generateSessionId: duped = '{s}', ptr = {*}\n", .{duped, duped.ptr});
    return duped;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default values
    var query: ?[]const u8 = null;
    var session_id: ?[]const u8 = null;
    var host: []const u8 = HTTP_HOST;
    var port: u16 = DEFAULT_PORT;
    var show_help = false;
    var show_version = false;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            show_version = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--query")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -q/--query requires a value\n", .{});
                return error.InvalidArgs;
            }
            query = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: -c/--continue requires a value\n", .{});
                return error.InvalidArgs;
            }
            session_id = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --host requires a value\n", .{});
                return error.InvalidArgs;
            }
            host = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --port requires a value\n", .{});
                return error.InvalidArgs;
            }
            port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 2;
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{arg});
            std.debug.print("Run 'nalarcore-cli --help' for usage.\n", .{});
            return error.InvalidArgs;
        }
    }

    // Handle help/version
    if (show_help) {
        showHelp();
        return;
    }

    if (show_version) {
        showVersion();
        return;
    }

    // If no query provided, start interactive mode
    if (query == null) {
        try interactiveMode(allocator, host, port);
        return;
    }

    // Determine session ID
    const final_session_id = session_id orelse try generateSessionId(allocator);
    if (session_id == null) {
        // defer allocator.free(final_session_id);
    }

    // Debug: print what's being passed
    std.debug.print("DEBUG: about to print session_id\n", .{});
    std.debug.print("DEBUG: query_ptr = {*}\n", .{&query});
    if (query) |q| {
        std.debug.print("DEBUG: query has value, len={d}\n", .{q.len});
    } else {
        std.debug.print("DEBUG: query is null\n", .{});
    }
    std.debug.print("DEBUG: session_id_ptr = {*}\n", .{&session_id});
    if (session_id) |s| {
        std.debug.print("DEBUG: session_id has value, len={d}\n", .{s.len});
    } else {
        std.debug.print("DEBUG: session_id is null\n", .{});
    }

    // Get current working directory to pass to server
    const cwd_buf = try allocator.alloc(u8, 4096);
    defer allocator.free(cwd_buf);
    const cwd_session = try std.posix.getcwd(cwd_buf);

    // Send the command
    try sendCommand(allocator, final_session_id, query.?, cwd_session, host, port);
}

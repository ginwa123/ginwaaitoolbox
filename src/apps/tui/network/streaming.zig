const std = @import("std");
const debug = @import("debug.zig");
const globals = @import("../globals.zig");
const sse = @import("sse.zig");
const messaging = @import("messaging.zig");
const connection = @import("connection.zig");
const utils = @import("../helpers/utils.zig");
const tool_results = @import("../display/tool_results.zig");
const response = @import("../display/response.zig");
const App = @import("../main.zig").App;

// Re-export ToolResult from tool_results for convenience
pub const ToolResult = tool_results.ToolResult;

/// Read response and stream LLM output
/// This is the main streaming function for chatting with the AI
pub fn readResponseAndStreamRunLLM(app: *App, message: []const u8) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: [4096]u8 = undefined;
    var retry_count: usize = 0;
    var streaming_started = false;

    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;

    const PING_INTERVAL_MS: i64 = 1000;
    var last_ping_ms: i64 = std.time.milliTimestamp();

    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return try raw_buffer.toOwnedSlice(app.allocator);
    defer std.posix.close(stream_socket);

    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch return try raw_buffer.toOwnedSlice(app.allocator);

    const stream_request = try std.fmt.allocPrint(alloc, "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(stream_socket, stream_request);

    if (!connection.waitForSseConnected(stream_socket, 5000)) {
        std.debug.print("{s}Warning: SSE connection timeout{s}\n", .{ globals.yellow, globals.reset });
    }
    try messaging.sendMessage(app, message);

    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    var stream_interrupted = false;
    var displayed_tool_ids = std.ArrayList([]const u8).empty;
    defer {
        for (displayed_tool_ids.items) |id| app.allocator.free(id);
        displayed_tool_ids.deinit(app.allocator);
    }
    var raw_buffer_processed_len: usize = 0;

    while (true) {
        const now = std.time.milliTimestamp();
        const ready = std.posix.poll(&poll_fds, 100) catch 0;

        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    messaging.sendDoubleEscapeCommand(app) catch {};
                    stream_interrupted = true;
                    break;
                }
                poll_fds[1].revents = 0;
            }

            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stream_socket, &buf) catch break;
                if (n == 0) break;
                try raw_buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
                last_data_received_ms = now;
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        } else {
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const needs_reconnect = messaging.sendPingCommand(app) catch false;
                if (needs_reconnect) {
                    reconnection_attempts += 1;
                    const new_socket = connection.reconnectSseStream(app, alloc, stream_socket);
                    if (new_socket < 0) {
                        std.debug.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ globals.yellow, globals.reset });
                        last_data_received_ms = now;
                        continue;
                    }

                    stream_socket = new_socket;
                    poll_fds[0].fd = stream_socket;
                    last_data_received_ms = std.time.milliTimestamp();
                    continue;
                }
                last_ping_ms = now;
            }
        }

        const new_raw = raw_buffer.items[raw_buffer_processed_len..];
        if (new_raw.len == 0) continue;

        const decoded = sse.decode_chuncked(app.allocator, new_raw) catch {
            debug.logError("streaming: decode_chuncked failed", .{});
            raw_buffer_processed_len = raw_buffer.items.len;
            continue;
        };
        defer app.allocator.free(decoded);
        raw_buffer_processed_len = raw_buffer.items.len;

        debug.logVerbose("streaming: decoded {d} bytes", .{decoded.len});

        const xml = sse.extract_sse_data(app.allocator, decoded) catch {
            debug.logError("streaming: extract_sse_data failed", .{});
            continue;
        };
        defer app.allocator.free(xml);

        debug.logVerbose("streaming: extracted {d} bytes of XML", .{xml.len});

        // Tool results are displayed per-chunk (they are discrete events)
        const tr_val = try tool_results.extractToolResults(app.allocator, xml);
        var tool_results_list = tr_val;
        defer tool_results_list.deinit(app.allocator);

        for (tool_results_list.items) |result| {
            var already_displayed = false;
            for (displayed_tool_ids.items) |id| {
                if (std.mem.eql(u8, id, result.id)) {
                    already_displayed = true;
                    break;
                }
            }
            if (!already_displayed) {
                std.debug.print("\r\x1b[2K", .{});
                const max_result_len: usize = 500;
                tool_results.displayToolResultByName(result.result, result.name, max_result_len);
                if (utils.extractTag(result.result, "set_agent_properties")) |_| {
                    std.debug.print("\n{s}[agent properties]{s} → updated\n", .{ globals.cyan, globals.reset });
                }
                const id_copy = app.allocator.dupe(u8, result.id) catch continue;
                displayed_tool_ids.append(app.allocator, id_copy) catch {
                    app.allocator.free(id_copy);
                    continue;
                };
            }
        }

        // Check finish_reason to decide whether to break the loop
        if (utils.extractTag(raw_buffer.items, "finish_reason")) |fr| {
            debug.logVerbose("streaming: detected finish_reason", .{});

            if (std.mem.eql(u8, fr, "notification_error")) {
                debug.logInfo("streaming: notification_error, retrying", .{});
                retry_count += 1;
                continue;
            }
            if (std.mem.eql(u8, fr, "cancelled")) {
                std.debug.print("\r\x1b[2K\n{s}Task cancelled{s}\n", .{ globals.yellow, globals.reset });
                break;
            }
            if (std.mem.eql(u8, fr, "user_choice")) {
                debug.logInfo("streaming: user_choice detected", .{});
                break;
            }
            if (std.mem.eql(u8, fr, "stop")) {
                debug.logInfo("streaming: stop detected, ending stream", .{});
                break;
            }
        }
    }

    std.debug.print("\r\x1b[2K", .{});
    if (stream_interrupted) {
        std.debug.print("\n{s}Interrupted (double ESC){s}\n", .{ globals.yellow, globals.reset });
    }

    // Decode and extract the full accumulated response once, then print
    const final_decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);

    const final_xml = sse.extract_sse_data(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);

    const final_extract = try response.extract_content_result(app.allocator, final_xml);
    if (final_extract) |extract_result| {
        const should_display = if (extract_result.finish_reason) |fr|
            !std.mem.eql(u8, fr, "tool_calls")
        else
            true;

        if (should_display) {
            var content_list = extract_result.content_results;
            defer content_list.deinit(app.allocator);
            for (content_list.items) |result| {
                streaming_started = true;
                std.debug.print("{s}", .{result.content});
            }
        }
    }

    std.debug.print("\n", .{});
    return try raw_buffer.toOwnedSlice(app.allocator);
}

/// Read and stream the list of active sessions
pub fn readResponseAndStreamGetSessions(app: *App) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [4096]u8 = undefined;

    const SSE_TIMEOUT_MS: i64 = 90000;
    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;
    const MAX_RECONNECTION_ATTEMPTS: u32 = 3;

    const PING_INTERVAL_MS: i64 = 5000;
    var last_ping_ms: i64 = std.time.milliTimestamp();

    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return try raw_buffer.toOwnedSlice(app.allocator);
    defer std.posix.close(stream_socket);

    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch return try raw_buffer.toOwnedSlice(app.allocator);

    const stream_request = try std.fmt.allocPrint(alloc, "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(stream_socket, stream_request);

    if (!connection.waitForSseConnected(stream_socket, 5000)) {
        std.debug.print("{s}Warning: SSE connection timeout{s}\n", .{ globals.yellow, globals.reset });
    }
    try messaging.sendSessionsCommand(app);

    var poll_fds = [2]std.posix.pollfd{
        .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        const now = std.time.milliTimestamp();
        const ready = std.posix.poll(&poll_fds, 50) catch 0;
        var new_data = false;
        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                poll_fds[1].revents = 0;
            }
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stream_socket, &buf) catch break;
                if (n == 0) break;
                try raw_buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
                new_data = true;
                last_data_received_ms = now;
            }
            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        }

        if (!new_data) {
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const needs_reconnect = messaging.sendPingCommand(app) catch false;
                if (needs_reconnect) {
                    std.debug.print("SSE session expired, reconnecting...\n", .{});
                    reconnection_attempts += 1;
                    break;
                }
                last_ping_ms = now;
            }

            if (now - last_data_received_ms > SSE_TIMEOUT_MS) {
                if (reconnection_attempts >= MAX_RECONNECTION_ATTEMPTS) {
                    std.debug.print("\r\x1b[2K\n{s}Connection lost. Max reconnection attempts reached.{s}\n", .{ globals.yellow, globals.reset });
                    break;
                }

                reconnection_attempts += 1;
                std.debug.print("\r\x1b[2K\n{s}Connection lost, reconnecting... (attempt {}/{})\n{s}", .{ globals.yellow, reconnection_attempts, MAX_RECONNECTION_ATTEMPTS, globals.reset });

                const new_socket = connection.reconnectSseStream(app, alloc, stream_socket);
                if (new_socket < 0) {
                    std.debug.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ globals.yellow, globals.reset });
                    last_data_received_ms = now;
                    std.Thread.sleep(1_000_000_000);
                    continue;
                }

                stream_socket = new_socket;
                poll_fds[0].fd = stream_socket;
                last_data_received_ms = now;
                std.debug.print("\r\x1b[2K\n{s}Reconnected successfully.{s}\n", .{ globals.green, globals.reset });
                continue;
            }

            std.Thread.sleep(10_000_000);
            continue;
        }

        const decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch continue;
        defer app.allocator.free(decoded);
        const xml = sse.extract_sse_data(app.allocator, decoded) catch continue;
        defer app.allocator.free(xml);
        if (std.mem.indexOf(u8, xml, "</finish_reason>") != null) break;
    }

    std.debug.print("\r\x1b[2K\n", .{});

    const final_decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    const final_xml = sse.extract_sse_data(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);

    if (utils.extractTag(final_xml, "sessions")) |md| {
        const trimmed = utils.trim(md);
        std.debug.print("{s}Session ID           Directory                        Created{s}\n", .{ globals.bold, globals.reset });
        std.debug.print("─────────────────────────────────────────────────────────────────────\n", .{});
        var rest = trimmed;
        while (utils.extractTag(rest, "session")) |session| {
            const id = utils.extractTag(session, "id") orelse "";
            const dir = utils.extractTag(session, "dir") orelse "";
            const ts = utils.extractTag(session, "created") orelse "";
            std.debug.print("{s:<20} {s:<32} {s}\n", .{ id, dir, ts });
            const end = std.mem.indexOf(u8, rest, "</session>") orelse break;
            rest = rest[end + "</session>".len ..];
        }
    }

    return try raw_buffer.toOwnedSlice(app.allocator);
}

/// Check stdin for double escape sequence (to interrupt streaming)
fn checkStdinForDoubleEscape(app: *App) bool {
    const raw_mode = @import("../terminal/raw_mode.zig");
    const bytes_available = raw_mode.stdinBytesAvailable();
    if (bytes_available == 0) return false;
    var buf: [16]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return false;
    if (n == 0) return false;
    const first_byte = buf[0];
    if (first_byte == 0x1b) {
        if (n >= 6 and std.mem.eql(u8, buf[0..6], "\x1b[200~")) {
            app.last_esc_time = null;
            return false;
        }
        if (n >= 6 and std.mem.eql(u8, buf[0..6], "\x1b[201~")) {
            app.last_esc_time = null;
            return false;
        }
        const now = std.time.milliTimestamp();
        if (app.last_esc_time) |last| {
            if (now - last < globals.DOUBLE_ESC_WINDOW_MS) {
                app.last_esc_time = null;
                return true;
            }
        }
        app.last_esc_time = now;
        return false;
    }
    return false;
}

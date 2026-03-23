const std = @import("std");
const globals = @import("../globals.zig");
const tuiText = @import("tui-text");
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
    // var spinner_timer: usize = 0;
    // const spinners = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    // var last_tick: i64 = 0;
    var retry_count: usize = 0;
    var streaming_started = false;

    // Timeout detection for SSE reconnection
    // Keepalive is sent every 30s, server removes session after ~60s
    // Use 90s timeout (3x server lifecycle) to avoid false timeouts
    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;

    // Ping interval - send ping every 5 seconds to keep session alive on server
    const PING_INTERVAL_MS: i64 = 1000;
    var last_ping_ms: i64 = std.time.milliTimestamp();

    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return try raw_buffer.toOwnedSlice(app.allocator);
    defer std.posix.close(stream_socket);

    // Enable TCP keepalive to detect connection drops
    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch return try raw_buffer.toOwnedSlice(app.allocator);

    const stream_request = try std.fmt.allocPrint(alloc, "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(stream_socket, stream_request);

    if (!connection.waitForSseConnected(stream_socket, 5000)) {
        tuiText.print("{s}Warning: SSE connection timeout{s}\n", .{ globals.yellow, globals.reset });
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
    // var last_printed_chunk_index: usize = 0;
    var last_finish_search_pos: usize = 0;
    var raw_buffer_processed_len: usize = 0;

    while (true) {
        const now = std.time.milliTimestamp();
        const ready = std.posix.poll(&poll_fds, 100) catch 0;
        var new_data = false;

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
                new_data = true;
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
                        tuiText.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ globals.yellow, globals.reset });
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

            // Spinner — only updated when idle and before streaming starts
            // if (!streaming_started and now - last_tick >= 100) {
            //     last_tick = now;
            //     const spin = spinners[spinner_timer % spinners.len];
            //     spinner_timer += 1;
            //     tuiText.print("\r\x1b[2K {s}{s}{s} Loading... ({d} bytes)", .{
            //         globals.yellow, spin, globals.reset, raw_buffer.items.len,
            //     });
            // }
            // if (!streaming_started and now - last_tick >= 100) {
            //     last_tick = now;
            //     const spin = spinners[spinner_timer % spinners.len];
            //     spinner_timer += 1;
            //     tuiText.print("\r\x1b[2K {s}{s}{s} Loading... ({d} bytes)", .{
            //         globals.yellow, spin, globals.reset, raw_buffer.items.len,
            //     });
            // }
        }

        const new_raw = raw_buffer.items[raw_buffer_processed_len..];
        if (new_raw.len == 0) continue;

        if (sse.decode_chuncked(app.allocator, new_raw)) |decoded| {
            defer app.allocator.free(decoded);
            raw_buffer_processed_len = raw_buffer.items.len;

            // Debug: print decoded size
            // tuiText.print("{s}[DEBUG] Decoded: {d} bytes{s}\n", .{ globals.dim, decoded.len, globals.reset });

            if (sse.extract_sse_data(app.allocator, decoded)) |xml| {
                defer app.allocator.free(xml);

                // Debug: print XML preview
                // const xml_preview = xml[0..@min(xml.len, 500)];
                // tuiText.print("{s}[DEBUG] XML ({d} bytes): {s}{s}\n", .{ globals.dim, xml.len, xml_preview, globals.reset });

                if (try response.extract_content_result(app.allocator, xml)) |extract_result| {
                    var content_list = extract_result.content_results;
                    defer content_list.deinit(app.allocator);

                    // Debug: print extraction results
                    // tuiText.print("{s}[DEBUG] Found {d} content results{s}\n", .{ globals.dim, content_list.items.len, globals.reset });

                    for (content_list.items) |result| {
                        // const xml_type_str: []const u8 = switch (result.xml_type) {
                        //     .response => "response",
                        //     .tool_result => "tool_result",
                        //     .content => "content",
                        // };
                        // tuiText.print("{s}[DEBUG] Content ({s}): {s}{s}\n", .{ globals.cyan, xml_type_str, result.content[0..@min(result.content.len, 200)], globals.reset });
                        if (result.content.len > 0) {
                            streaming_started = true;
                            tuiText.print("{s}", .{result.content});
                        }
                    }
                } else {
                    // tuiText.print("{s}[DEBUG] extractContentResult returned null (no <response>/<tool_result> tags found){s}\n", .{ globals.red, globals.reset });
                }

                if (tool_results.extractToolResults(app.allocator, xml)) |tr_val| {
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
                            tuiText.print("\r\x1b[2K", .{});
                            const max_result_len: usize = 500;
                            tool_results.displayToolResultByName(result.result, result.name, max_result_len);
                            if (utils.extractTag(result.result, "set_agent_properties")) |_| {
                                tuiText.print("\n{s}[agent properties]{s} → updated\n", .{ globals.cyan, globals.reset });
                            }
                            const id_copy = app.allocator.dupe(u8, result.id) catch continue;
                            displayed_tool_ids.append(app.allocator, id_copy) catch {
                                app.allocator.free(id_copy);
                                continue;
                            };
                        }
                    }
                } else |_| {}
            } else |_| {}
        } else |_| {}

        var finish_reason_stop = false;
        // finish_reason
        const search_start = @min(last_finish_search_pos, raw_buffer.items.len);
        if (std.mem.indexOfPos(u8, raw_buffer.items, search_start, "</finish_reason>")) |pos| {
            last_finish_search_pos = raw_buffer.items.len;
            // Find the corresponding opening tag to extract content
            if (utils.extractTag(raw_buffer.items, "finish_reason")) |fr| {
                if (std.mem.eql(u8, fr, "notification_error")) {
                    retry_count += 1;
                    continue;
                }
                if (std.mem.eql(u8, fr, "cancelled")) {
                    tuiText.print("\r\x1b[2K\n{s}Task cancelled{s}\n", .{ globals.yellow, globals.reset });
                    finish_reason_stop = true;
                }
                if (std.mem.eql(u8, fr, "user_choice")) {
                    finish_reason_stop = true;
                }
                if (std.mem.eql(u8, fr, "stop")) {
                    finish_reason_stop = true;
                }
                if (finish_reason_stop) {
                    // Verify this is the LAST finish_reason in buffer before breaking
                    // Count total finish_reason tags - if this is the only one, it's the latest
                    const total_tags = std.mem.count(u8, raw_buffer.items, "</finish_reason>");
                    if (total_tags == 1) {
                        // Only one finish_reason - this is definitely the latest
                        break;
                    }
                    // Multiple tags - check if there's another one after this position
                    const after_this_end = pos + "</finish_reason>".len;
                    if (after_this_end >= raw_buffer.items.len or
                        std.mem.indexOf(u8, raw_buffer.items[after_this_end..], "</finish_reason>") == null)
                    {
                        // check get session to make sure we loop
                        // call api get session
                        break;
                    }
                }
            }
        }
    }

    tuiText.print("\r\x1b[2K", .{});
    if (stream_interrupted) {
        tuiText.print("\n{s}Interrupted (double ESC){s}\n", .{ globals.yellow, globals.reset });
    }

    // tuiText.print("\n{s}[DEBUG] Raw buffer size: {d}{s}\n", .{ globals.dim, raw_buffer.items.len, globals.reset });

    const final_decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    // tuiText.print("{s}[DEBUG] Decoded size: {d}{s}\n", .{ globals.dim, final_decoded.len, globals.reset });

    const final_xml = sse.extract_sse_data(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);
    // tuiText.print("{s}[DEBUG] XML size: {d}{s}\n", .{ globals.dim, final_xml.len, globals.reset });
    // tuiText.print("{s}[DEBUG] XML preview: {s}{s}\n", .{ globals.dim, final_xml[0..@min(final_xml.len, 500)], globals.reset });

    // Content was already printed during streaming, no need to reprint here

    tuiText.print("\n", .{});
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

    // Timeout detection for SSE reconnection
    const SSE_TIMEOUT_MS: i64 = 90000; // 90 seconds
    var last_data_received_ms: i64 = std.time.milliTimestamp();
    var reconnection_attempts: u32 = 0;
    const MAX_RECONNECTION_ATTEMPTS: u32 = 3;

    // Ping interval
    const PING_INTERVAL_MS: i64 = 5000;
    var last_ping_ms: i64 = std.time.milliTimestamp();

    var stream_socket = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0) catch return try raw_buffer.toOwnedSlice(app.allocator);
    defer std.posix.close(stream_socket);

    // Enable TCP keepalive
    var enable: u32 = 1;
    std.posix.setsockopt(stream_socket, std.posix.SOL.SOCKET, std.posix.SO.KEEPALIVE, std.mem.asBytes(&enable)) catch {};

    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, app.http_port);
    std.posix.connect(stream_socket, &addr.any, @sizeOf(std.net.Address)) catch return try raw_buffer.toOwnedSlice(app.allocator);

    const stream_request = try std.fmt.allocPrint(alloc, "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(stream_socket, stream_request);

    // Wait for "connected" event BEFORE sending command
    if (!connection.waitForSseConnected(stream_socket, 5000)) {
        tuiText.print("{s}Warning: SSE connection timeout{s}\n", .{ globals.yellow, globals.reset });
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
            // No data available - check for timeout
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const needs_reconnect = messaging.sendPingCommand(app) catch false;
                if (needs_reconnect) {
                    tuiText.print("SSE session expired, reconnecting...\n", .{});
                    reconnection_attempts += 1;
                    break;
                }
                last_ping_ms = now;
            }

            if (now - last_data_received_ms > SSE_TIMEOUT_MS) {
                if (reconnection_attempts >= MAX_RECONNECTION_ATTEMPTS) {
                    tuiText.print("\r\x1b[2K\n{s}Connection lost. Max reconnection attempts reached.{s}\n", .{ globals.yellow, globals.reset });
                    break;
                }

                reconnection_attempts += 1;
                tuiText.print("\r\x1b[2K\n{s}Connection lost, reconnecting... (attempt {}/{})\n{s}", .{ globals.yellow, reconnection_attempts, MAX_RECONNECTION_ATTEMPTS, globals.reset });

                const new_socket = connection.reconnectSseStream(app, alloc, stream_socket);
                if (new_socket < 0) {
                    tuiText.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ globals.yellow, globals.reset });
                    last_data_received_ms = now;
                    std.Thread.sleep(1_000_000_000);
                    continue;
                }

                stream_socket = new_socket;
                poll_fds[0].fd = stream_socket;
                last_data_received_ms = now;
                tuiText.print("\r\x1b[2K\n{s}Reconnected successfully.{s}\n", .{ globals.green, globals.reset });
                continue;
            }

            std.Thread.sleep(10_000_000); // 10ms
            continue;
        }

        const decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch continue;
        defer app.allocator.free(decoded);
        const xml = sse.extract_sse_data(app.allocator, decoded) catch continue;

        defer app.allocator.free(xml);
        if (std.mem.indexOf(u8, xml, "</finish_reason>") != null) break;
    }

    tuiText.print("\r\x1b[2K\n", .{});

    const final_decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    const final_xml = sse.extract_sse_data(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);

    if (utils.extractTag(final_xml, "sessions")) |md| {
        const trimmed = utils.trim(md);
        tuiText.print("{s}Session ID           Directory                        Created{s}\n", .{ globals.bold, globals.reset });
        tuiText.print("─────────────────────────────────────────────────────────────────────\n", .{});
        var rest = trimmed;
        while (utils.extractTag(rest, "session")) |session| {
            const id = utils.extractTag(session, "id") orelse "";
            const dir = utils.extractTag(session, "dir") orelse "";
            const ts = utils.extractTag(session, "created") orelse "";
            tuiText.print("{s:<20} {s:<32} {s}\n", .{ id, dir, ts });
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

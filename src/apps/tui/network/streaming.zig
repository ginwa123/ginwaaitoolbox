const std = @import("std");
const globals = @import("../globals.zig");
const tui_text = @import("tui-text");
const sse = @import("sse.zig");
const messaging = @import("messaging.zig");
const connection = @import("connection.zig");
const utils = @import("../helpers/utils.zig");
const tool_results = @import("../display/tool_results.zig");

// Re-export ToolResult from tool_results for convenience
pub const ToolResult = tool_results.ToolResult;

/// Read response and stream LLM output
/// This is the main streaming function for chatting with the AI
pub fn readResponseAndStreamRunLLM(app: anytype, message: []const u8) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);

    var buf: [4096]u8 = undefined;
    var spinner_timer: usize = 0;
    const spinners = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var last_tick: i64 = 0;
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

    const stream_request = try std.fmt.allocPrint(app.arena.allocator(), "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(stream_socket, stream_request);

    if (!connection.waitForSseConnected(stream_socket, 5000)) {
        tui_text.print("{s}Warning: SSE connection timeout{s}\n", .{ globals.yellow, globals.reset });
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
    var last_printed_chunk_index: usize = 0;
    var last_finish_search_pos: usize = 0;
    var raw_buffer_processed_len: usize = 0;

    while (true) {
        // Cache timestamp once per loop — avoids redundant syscalls
        const now = std.time.milliTimestamp();

        // poll() blocks up to 100ms waiting for data
        const ready = std.posix.poll(&poll_fds, 100) catch 0;
        var new_data = false;

        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    messaging.sendCancelCommand(app) catch {};
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
            // poll() timed out — no data arrived in the last 100ms.

            // Send periodic ping to keep session alive on server
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const needs_reconnect = messaging.sendPingCommand(app) catch false;
                if (needs_reconnect) {
                    tui_text.print("SSE session expired, reconnecting...\n", .{});
                    reconnection_attempts += 1;
                    const new_socket = connection.reconnectSseStream(app, stream_socket);
                    if (new_socket < 0) {
                        tui_text.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ globals.yellow, globals.reset });
                        last_data_received_ms = now;
                        continue;
                    }

                    stream_socket = new_socket;
                    poll_fds[0].fd = stream_socket;
                    last_data_received_ms = std.time.milliTimestamp();
                    tui_text.print("\r\x1b[2K\n{s}Reconnected successfully.{s}\n", .{ globals.green, globals.reset });
                    continue;
                }
                last_ping_ms = now;
            }

            // Spinner — only updated when idle
            if (!streaming_started and now - last_tick >= 100) {
                last_tick = now;
                const spin = spinners[spinner_timer % spinners.len];
                spinner_timer += 1;
                tui_text.print("\r\x1b[2K {s}{s}{s} Loading... ({d} bytes)", .{
                    globals.yellow, spin, globals.reset, raw_buffer.items.len,
                });
            }
        }

        const new_raw = raw_buffer.items[raw_buffer_processed_len..];
        if (new_raw.len == 0) continue;

        if (sse.decodeChunked(app.allocator, new_raw)) |decoded| {
            defer app.allocator.free(decoded);
            raw_buffer_processed_len = raw_buffer.items.len;

            if (sse.extractSseData(app.allocator, decoded)) |xml| {
                defer app.allocator.free(xml);

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
                        if (utils.extractTag(chunk_block, "content")) |content| {
                            if (content.len > 0) {
                                if (!streaming_started) {
                                    tui_text.print("\r\x1b[2K", .{});
                                    streaming_started = true;
                                }
                                tui_text.print("{s}", .{content});
                            }
                        }
                    }
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
                            tui_text.print("\r\x1b[2K", .{});
                            const max_result_len: usize = 500;
                            tool_results.displayToolResultByName(result.result, result.name, max_result_len);
                            if (utils.extractTag(result.result, "set_agent_properties")) |_| {
                                tui_text.print("\n{s}[agent properties]{s} → updated\n", .{ globals.cyan, globals.reset });
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

        // finish_reason
        const search_start = @min(last_finish_search_pos, raw_buffer.items.len);
        if (std.mem.indexOfPos(u8, raw_buffer.items, search_start, "</finish_reason>")) |_| {
            last_finish_search_pos = raw_buffer.items.len;
            if (utils.extractTag(raw_buffer.items, "finish_reason")) |fr| {
                if (std.mem.eql(u8, fr, "notification_error")) {
                    retry_count += 1;
                    continue;
                }
                if (std.mem.eql(u8, fr, "cancelled")) {
                    tui_text.print("\r\x1b[2K\n{s}Task cancelled{s}\n", .{ globals.yellow, globals.reset });
                    break;
                }
                if (std.mem.eql(u8, fr, "user_choice")) break;
                if (std.mem.eql(u8, fr, "stop")) break;
            }
        }
    }

    tui_text.print("\r\x1b[2K", .{});
    if (stream_interrupted) {
        tui_text.print("\n{s}Interrupted (double ESC){s}\n", .{ globals.yellow, globals.reset });
    }

    tui_text.print("\n{s}[DEBUG] Raw buffer size: {d}{s}\n", .{ globals.dim, raw_buffer.items.len, globals.reset });

    const final_decoded = sse.decodeChunked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    tui_text.print("{s}[DEBUG] Decoded size: {d}{s}\n", .{ globals.dim, final_decoded.len, globals.reset });

    const final_xml = sse.extractSseData(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);
    tui_text.print("{s}[DEBUG] XML size: {d}{s}\n", .{ globals.dim, final_xml.len, globals.reset });
    if (final_xml.len > 0) {
        tui_text.print("{s}[DEBUG] XML preview: {s}{s}\n", .{ globals.dim, final_xml[0..@min(final_xml.len, 200)], globals.reset });
    }

    if (utils.extractTag(final_xml, "content")) |content| {
        printFormattedResponse(content);
    } else if (final_xml.len > 0) {
        if (utils.extractTag(final_xml, "message")) |msg| {
            printFormattedResponse(msg);
        } else {
            tui_text.print("{s}\n", .{final_xml});
        }
    } else {
        tui_text.print("{s}(no response){s}\n", .{ globals.dim, globals.reset });
    }

    tui_text.print("\n", .{});
    _ = app.arena.reset(.retain_capacity);
    return try raw_buffer.toOwnedSlice(app.allocator);
}

/// Read and stream the list of active sessions
pub fn readResponseAndStreamGetSessions(app: anytype) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);
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

    const stream_request = try std.fmt.allocPrint(app.arena.allocator(), "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    _ = try std.posix.write(stream_socket, stream_request);

    // Wait for "connected" event BEFORE sending command
    if (!connection.waitForSseConnected(stream_socket, 5000)) {
        tui_text.print("{s}Warning: SSE connection timeout{s}\n", .{ globals.yellow, globals.reset });
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
                    tui_text.print("SSE session expired, reconnecting...\n", .{});
                    reconnection_attempts += 1;
                    break;
                }
                last_ping_ms = now;
            }

            if (now - last_data_received_ms > SSE_TIMEOUT_MS) {
                if (reconnection_attempts >= MAX_RECONNECTION_ATTEMPTS) {
                    tui_text.print("\r\x1b[2K\n{s}Connection lost. Max reconnection attempts reached.{s}\n", .{ globals.yellow, globals.reset });
                    break;
                }

                reconnection_attempts += 1;
                tui_text.print("\r\x1b[2K\n{s}Connection lost, reconnecting... (attempt {}/{})\n{s}", .{ globals.yellow, reconnection_attempts, MAX_RECONNECTION_ATTEMPTS, globals.reset });

                const new_socket = connection.reconnectSseStream(app, stream_socket);
                if (new_socket < 0) {
                    tui_text.print("\r\x1b[2K\n{s}Reconnection failed.{s}\n", .{ globals.yellow, globals.reset });
                    last_data_received_ms = now;
                    std.Thread.sleep(1_000_000_000);
                    continue;
                }

                stream_socket = new_socket;
                poll_fds[0].fd = stream_socket;
                last_data_received_ms = now;
                tui_text.print("\r\x1b[2K\n{s}Reconnected successfully.{s}\n", .{ globals.green, globals.reset });
                continue;
            }

            std.Thread.sleep(10_000_000); // 10ms
            continue;
        }

        const decoded = sse.decodeChunked(app.allocator, raw_buffer.items) catch continue;
        defer app.allocator.free(decoded);
        const xml = sse.extractSseData(app.allocator, decoded) catch continue;

        tui_text.print("\r\nXML len={d}: {s}\r\nEND_XML\r\n", .{ xml.len, xml[0..@min(xml.len, 200)] });
        defer app.allocator.free(xml);
        if (std.mem.indexOf(u8, xml, "</finish_reason>") != null) break;
    }

    tui_text.print("\r\x1b[2K\n", .{});

    const final_decoded = sse.decodeChunked(app.allocator, raw_buffer.items) catch "";
    defer app.allocator.free(final_decoded);
    const final_xml = sse.extractSseData(app.allocator, final_decoded) catch "";
    defer app.allocator.free(final_xml);

    if (utils.extractTag(final_xml, "sessions")) |md| {
        const trimmed = utils.trim(md);
        tui_text.print("{s}Session ID           Directory                        Created{s}\n", .{ globals.bold, globals.reset });
        tui_text.print("─────────────────────────────────────────────────────────────────────\n", .{});
        var rest = trimmed;
        while (utils.extractTag(rest, "session")) |session| {
            const id = utils.extractTag(session, "id") orelse "";
            const dir = utils.extractTag(session, "dir") orelse "";
            const ts = utils.extractTag(session, "created") orelse "";
            tui_text.print("{s:<20} {s:<32} {s}\n", .{ id, dir, ts });
            const end = std.mem.indexOf(u8, rest, "</session>") orelse break;
            rest = rest[end + "</session>".len ..];
        }
    }

    _ = app.arena.reset(.retain_capacity);
    return try raw_buffer.toOwnedSlice(app.allocator);
}

/// Print formatted response from the AI
fn printFormattedResponse(content: []const u8) void {
    const agent_name = utils.extractTag(content, "agent") orelse "assistant";
    tui_text.print("{s}━━ {s} ━━{s}\n", .{ globals.cyan, agent_name, globals.reset });
    if (utils.extractTag(content, "markdown")) |md| {
        const trimmed = utils.trim(md);
        if (trimmed.len > 0) {
            tui_text.print("\n{s}{s}{s}\n", .{ globals.bold, trimmed, globals.reset });
        } else {
            tui_text.print("\n{s}{s}{s}\n", .{ globals.bold, content, globals.reset });
        }
    } else {
        tui_text.print("\n{s}{s}{s}\n", .{ globals.bold, content, globals.reset });
    }
}

/// Check stdin for double escape sequence (to interrupt streaming)
fn checkStdinForDoubleEscape(app: anytype) bool {
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

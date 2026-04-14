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
/// Simplified: collects raw buffer, displays content at the end
pub fn read_response_and_stream_run_LLM(app: *App, message: []const u8) ![]u8 {
    var raw_buffer = std.ArrayList(u8).empty;
    errdefer raw_buffer.deinit(app.allocator);
    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: [4096]u8 = undefined;

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

    while (true) {
        defer {
            raw_buffer.clearAndFree(app.allocator);
        }
        const now = std.time.milliTimestamp();

        if (app.is_noninteractive) {
            var poll_fd = [1]std.posix.pollfd{
                .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&poll_fd, 100) catch 0;

            if (ready > 0) {
                if (poll_fd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                    break;
                }
                if (poll_fd[0].revents & std.posix.POLL.IN != 0) {
                    const n = std.posix.read(stream_socket, &buf) catch break;
                    if (n == 0) {
                        break;
                    }
                    try raw_buffer.appendSlice(app.allocator, buf[0..n]);
                }
            }

            if (std.mem.indexOf(u8, raw_buffer.items, ": keepalive") != null) {
                const is_done = try messaging.get_latest_message_by_created_at(app);
                if (is_done) {
                    break;
                }
            } else if (raw_buffer.items.len > 0) {
                const is_done = try messaging.get_latest_message_by_created_at(app);
                if (is_done) {
                    break;
                }
            }
            continue;
        }

        var poll_fds = [2]std.posix.pollfd{
            .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&poll_fds, 100) catch 0;

        if (ready > 0) {
            if (poll_fds[1].revents & std.posix.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    messaging.sendDoubleEscapeCommand(app) catch {};
                    break;
                }
                poll_fds[1].revents = 0;
            }

            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stream_socket, &buf) catch break;
                if (n == 0) break;
                try raw_buffer.appendSlice(app.allocator, buf[0..n]);
                poll_fds[0].revents = 0;
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        } else {
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const is_need_reconnect = messaging.send_ping_command(app) catch false;
                if (is_need_reconnect) {
                    const new_socket = connection.reconnectSseStream(app, app.allocator, stream_socket);
                    if (new_socket < 0) {
                        break;
                    }
                    stream_socket = new_socket;
                    poll_fds[0].fd = stream_socket;
                }
                last_ping_ms = now;
            }
        }

        if (std.mem.indexOf(u8, raw_buffer.items, ": keepalive") != null) {
            const is_done = try messaging.get_latest_message_by_created_at(app);
            if (is_done) {
                break;
            }
        } else {
            const decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch {
                raw_buffer.clearAndFree(app.allocator);
                continue;
            };
            defer app.allocator.free(decoded);
            const json_str = sse.extract_sse_data(app.allocator, decoded) catch {
                raw_buffer.clearAndFree(app.allocator);
                continue;
            };
            defer app.allocator.free(json_str);
            if (json_str.len > 0) {
                const trimmed = std.mem.trim(u8, json_str, &std.ascii.whitespace);
                if (trimmed.len > 0 and trimmed[0] == '{') {
                    const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, trimmed, .{}) catch continue;
                    defer parsed.deinit();
                    printJsonContent(parsed.value);
                }
            }
        }

        raw_buffer.clearAndFree(app.allocator);
    }

    // In non-interactive mode, fetch the final message and print according to --json flag
    if (app.is_noninteractive) {
        const body = messaging.fetch_latest_message_body(app) catch null;
        if (body) |b| {
            defer app.allocator.free(b);
            if (app.json) {
                // Pretty-print the full JSON response
                printPrettyJson(app.allocator, b);
            } else {
                // Extract and print only the content field value
                printMessageContent(app.allocator, b);
            }
        }
    }

    raw_buffer.clearRetainingCapacity();
    return try raw_buffer.toOwnedSlice(app.allocator);
}

/// Parse the messages JSON body and print user-friendly output for the first message.
/// Body format: {"messages":[{"content":"...","role":"assistant",...}]}
pub fn printMessageContent(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        std.debug.print("{s}\n", .{body});
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        std.debug.print("{s}\n", .{body});
        return;
    }
    const messages_val = root.object.get("messages") orelse {
        std.debug.print("{s}\n", .{body});
        return;
    };
    if (messages_val != .array or messages_val.array.items.len == 0) {
        std.debug.print("{s}\n", .{body});
        return;
    }
    const first_msg = messages_val.array.items[0];
    if (first_msg != .object) {
        std.debug.print("{s}\n", .{body});
        return;
    }
    const content_val = first_msg.object.get("content") orelse {
        std.debug.print("{s}\n", .{body});
        return;
    };
    if (content_val != .string) {
        std.debug.print("{s}\n", .{body});
        return;
    }

    const role_val = first_msg.object.get("role");
    const role_str = if (role_val) |r| if (r == .string) r.string else "" else "";
    const content_str = content_val.string;

    // Print content directly - it's already extracted from JSON, not XML
    std.debug.print("{s}", .{content_str});

    if (role_str.len > 0) {
        std.debug.print("\n\n", .{});
    }
}

/// Parse the JSON body and pretty-print it with indentation.
pub fn printPrettyJson(allocator: std.mem.Allocator, body: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        std.debug.print("{s}\n", .{body});
        return;
    };
    defer parsed.deinit();

    const pretty = std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 }) catch {
        std.debug.print("{s}\n", .{body});
        return;
    };
    defer allocator.free(pretty);
    std.debug.print("{s}\n", .{pretty});
}

/// Parse SSE JSON data and print user-friendly content
/// is_input: true when showing tool call invocation (arguments)
/// is_output: true when showing tool call result (output)
pub fn printJsonContent(root: std.json.Value) void {
        if (root != .object) return;

        const is_input = root.object.get("is_input");
        const is_output = root.object.get("is_output");
        const is_input_bool = is_input != null and is_input.?.bool;
        const is_output_bool = is_output != null and is_output.?.bool;

        const tool_name_str = if (root.object.get("tool_name")) |t| if (t == .string) t.string else "" else "";

        // const role_str = if (root.object.get("role")) |r| if (r == .string) r.string else "" else "";
        // const finish_str = if (root.object.get("finish_reason")) |f| if (f == .string) f.string else "" else "";

        const content_val = root.object.get("content") orelse return;
        if (content_val != .string) return;
        const content_str = content_val.string;
        if (content_str.len == 0) return;

        std.debug.print("\n", .{});
        if (is_input_bool) {
            std.debug.print("Assistant: \nTool Call: {s}\n", .{tool_name_str});
        } else if (is_output_bool) {
            std.debug.print("Tool Result {s}:\n", .{tool_name_str});
        }

        std.debug.print("{s}\n", .{content_str});
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
                const needs_reconnect = messaging.send_ping_command(app) catch false;
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

    if (utils.extract_tag(final_xml, "sessions")) |md| {
        const trimmed = utils.trim(md);
        std.debug.print("{s}Session ID           Directory                        Created{s}\n", .{ globals.bold, globals.reset });
        std.debug.print("─────────────────────────────────────────────────────────────────────\n", .{});
        var rest = trimmed;
        while (utils.extract_tag(rest, "session")) |session| {
            const id = utils.extract_tag(session, "id") orelse "";
            const dir = utils.extract_tag(session, "dir") orelse "";
            const ts = utils.extract_tag(session, "created") orelse "";
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

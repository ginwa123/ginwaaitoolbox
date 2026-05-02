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

/// Check if the SSE stream is done by querying the server.
/// Returns true if the stream has completed.
fn checkStreamDone(app: *App) !bool {
    return try messaging.get_latest_message_by_created_at(app);
}

/// Print the final message body to stdout (used by both modes at end).
fn printFinalMessage(app: *App) void {
    const body = messaging.fetch_latest_message_body(app) catch null;
    if (body) |b| {
        defer app.allocator.free(b);
        if (app.json) {
            print_pretty_json(app.allocator, b);
        } else {
            printMessageContent(app.allocator, b);
        }
    }
}

/// SSE event data parsed from JSON (matches SseEventPayload from on_event_sent.zig)
pub const SSEEventData = struct {
    session_id: []const u8 = "",
    model: []const u8 = "",
    cwd: []const u8 = "",
    content: ?[]const u8 = null,
    reasoning_content: ?[]const u8 = null,
    role: []const u8 = "assistant",
    finish_reason: ?[]const u8 = null,
    tool_calls: ?[]const ToolCallJson = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8 = null,
    session_name: ?[]const u8 = null,
    loop_index: u32 = 0,
    temperature: f32 = 0,
    is_thinking: bool = false,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
};

/// JSON representation of a tool call (matches ToolCallJson from on_event_sent.zig)
pub const ToolCallJson = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

/// Parse SSE event data from JSON string
fn parseSSEEventData(allocator: std.mem.Allocator, json_str: []const u8) !SSEEventData {
    const parsed = try std.json.parseFromSlice(SSEEventData, allocator, json_str, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_first,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return parsed.value;
}

/// Read response and stream LLM output
/// Simplified: collects raw buffer, displays content at the end
pub fn readResponseAndStreamRunLLM(app: *App, message: []const u8) ![]u8 {
    var raw_buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer raw_buffer.deinit(app.allocator);

    var arena = std.heap.ArenaAllocator.init(app.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const PING_INTERVAL_MS: i64 = 1000;
    var last_ping_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(app.io, .real).nanoseconds, 1_000_000));

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

    const READ_SIZE: usize = 1024 * 64;

    while (true) {
        defer {
            raw_buffer.clearAndFree(app.allocator);
        }
        const now = std.time.milliTimestamp();

        if (app.is_noninteractive) {
            // Non-interactive: poll only the socket
            var poll_fd = [1]std.posix.pollfd{
                .{ .fd = stream_socket, .events = std.posix.POLL.IN, .revents = 0 },
            };
            const ready = std.posix.poll(&poll_fd, 100) catch 0;

            if (ready > 0) {
                if (poll_fd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                    break;
                }
                if (poll_fd[0].revents & std.posix.POLL.IN != 0) {
                    try raw_buffer.ensureUnusedCapacity(app.allocator, READ_SIZE);
                    const slice = raw_buffer.unusedCapacitySlice();
                    const n = std.posix.read(stream_socket, slice[0..@min(slice.len, READ_SIZE)]) catch break;
                    if (n == 0) break;
                    raw_buffer.items.len += n;
                }
            }

            // Check if stream is done (keepalive or any data)
            if (std.mem.indexOf(u8, raw_buffer.items, ": keepalive") != null or raw_buffer.items.len > 0) {
                if (try checkStreamDone(app)) break;
            }
            continue;
        }

        // Interactive: poll socket + stdin, parse & print in real-time
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
                try raw_buffer.ensureUnusedCapacity(app.allocator, READ_SIZE);
                const slice = raw_buffer.unusedCapacitySlice();
                const n = std.posix.read(stream_socket, slice[0..@min(slice.len, READ_SIZE)]) catch break;
                if (n == 0) break;
                raw_buffer.items.len += n;
                poll_fds[0].revents = 0;
            }

            if (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
        } else {
            if (now - last_ping_ms > PING_INTERVAL_MS) {
                const is_need_reconnect = messaging.send_ping_command(app) catch false;
                if (is_need_reconnect) {
                    const new_socket = connection.reconnectSseStream(app, app.allocator, stream_socket);
                    if (new_socket < 0) break;
                    stream_socket = new_socket;
                    poll_fds[0].fd = stream_socket;
                }
                last_ping_ms = now;
            }
        }

        // Parse and print SSE events in real-time
        if (std.mem.indexOf(u8, raw_buffer.items, ": keepalive") != null) {
            if (try checkStreamDone(app)) break;
        } else {
            const decoded = sse.decode_chuncked(app.allocator, raw_buffer.items) catch {
                continue;
            };
            defer app.allocator.free(decoded);
            const json_str = sse.extract_sse_data(app.allocator, decoded) catch {
                continue;
            };
            defer app.allocator.free(json_str);
            if (json_str.len > 0) {
                const trimmed = std.mem.trim(u8, json_str, &std.ascii.whitespace);
                if (trimmed.len > 0 and trimmed[0] == '{') {
                    const sse_event = parseSSEEventData(app.allocator, trimmed) catch |err| {
                        debug.logError("Failed to parse SSE event JSON: raw_buffer={s}", .{raw_buffer.items});
                        debug.logError("Failed to parse SSE event JSON: {s}", .{@errorName(err)});
                        continue;
                    };
                    printSSEEventContent(sse_event);

                    if (sse_event.finish_reason) |fr| {
                        if (std.mem.eql(u8, fr, "stop")) break;
                    }
                } else {
                    debug.logError("Failed to parse SSE event JSON: {s}", .{json_str});
                    std.debug.print("Failed to parse SSE event JSON: {s}\n", .{json_str});
                }
            }
        }
    }

    // Print final message body in both modes
    printFinalMessage(app);

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
pub fn print_pretty_json(allocator: std.mem.Allocator, body: []const u8) void {
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

/// Print SSE event content using custom struct data
pub fn printSSEEventContent(event: SSEEventData) void {
    const content_str = event.content orelse "";
    if (content_str.len == 0) return;

    const tool_name_str = event.tool_name orelse "";
    if (event.is_input) {
        std.debug.print("\n Assistant: \n", .{});
        std.debug.print("{s}\n", .{content_str});
        if (tool_name_str.len > 0) {
            std.debug.print("\nPlanning NextMove: {s}\n", .{tool_name_str});
        }
    } else if (event.is_output) {
        if (tool_name_str.len > 0) {
            std.debug.print("Result {s}:\n", .{tool_name_str});
        }
        std.debug.print("{s}\n", .{content_str});
    } else {
        std.debug.print("{s}\n", .{content_str});
    }
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

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

fn getTimeMillis() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Check if the SSE stream is done by querying the server.
/// Returns true if the stream has completed.
fn checkStreamDone(app: *App) !bool {
    return try messaging.get_latest_message_by_created_at(app);
}

/// Print the final message body to stdout (used by both modes at end).
fn printFinalMessage(app: *App) void {
    const body = messaging.fetch_latest_message_body(app) catch |err| {
        std.debug.print("[DEBUG] fetch_latest_message_body error: {s}\n", .{@errorName(err)});
        return;
    };
    if (body) |b| {
        defer app.allocator.free(b);
        // Parse and find the assistant message content
        const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, b, .{}) catch {
            std.debug.print("{s}\n", .{b});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            std.debug.print("{s}\n", .{b});
            return;
        }
        const messages_val = root.object.get("messages") orelse {
            std.debug.print("{s}\n", .{b});
            return;
        };
        if (messages_val != .array or messages_val.array.items.len == 0) {
            std.debug.print("{s}\n", .{b});
            return;
        }
        // Find the first non-tool message (the actual assistant response)
        for (messages_val.array.items) |msg| {
            if (msg != .object) continue;
            const role = msg.object.get("role") orelse continue;
            if (role != .string) continue;
            if (std.mem.eql(u8, role.string, "assistant")) {
                const content = msg.object.get("content") orelse continue;
                if (content == .string) {
                    std.debug.print("{s}\n", .{content.string});
                    return;
                }
            }
        }
        // Fallback: just print first message content
        const first_msg = messages_val.array.items[0];
        if (first_msg == .object) {
            if (first_msg.object.get("content")) |content_val| {
                if (content_val == .string) {
                    std.debug.print("{s}\n", .{content_val.string});
                    return;
                }
            }
        }
        std.debug.print("{s}\n", .{b});
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
    std.debug.print("[DEBUG] START - session_id: {s}, message: {s}\n", .{ app.session_id, message });
    std.debug.print("[DEBUG] About to init raw_buffer\n", .{});
    var raw_buffer: std.ArrayListUnmanaged(u8) = .empty;
    std.debug.print("[DEBUG] raw_buffer init done\n", .{});
    errdefer raw_buffer.deinit(app.allocator);
    std.debug.print("[DEBUG] About to init arena\n", .{});

    var arena = std.heap.ArenaAllocator.init(app.allocator);
    std.debug.print("[DEBUG] arena init done\n", .{});
    defer _ = arena.reset(.free_all);
    std.debug.print("[DEBUG] About to create socket\n", .{});
    const alloc = arena.allocator();

    const PING_INTERVAL_MS: i64 = 1000;
    var last_ping_ms: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(app.io, .real).nanoseconds, 1_000_000));

    std.debug.print("[DEBUG] About to connect using high-level API...\n", .{});

    // Use high-level std.Io.net API - this handles socket creation and connection
    const address = std.Io.net.IpAddress.parse("127.0.0.1", app.http_port) catch {
        std.debug.print("[DEBUG] IpAddress.parse failed\n", .{});
        return try raw_buffer.toOwnedSlice(app.allocator);
    };
    std.debug.print("[DEBUG] Address parsed successfully\n", .{});

    const stream = std.Io.net.IpAddress.connect(&address, app.io, .{ .mode = .stream }) catch |err| {
        std.debug.print("[DEBUG] IpAddress.connect failed: {s}\n", .{@errorName(err)});
        return try raw_buffer.toOwnedSlice(app.allocator);
    };
    std.debug.print("[DEBUG] Connected via high-level API!\n", .{});

    // Get the socket fd for polling
    var stream_socket: i32 = @intCast(stream.socket.handle);
    std.debug.print("[DEBUG] stream_socket fd: {d}\n", .{stream_socket});

    const stream_request = try std.fmt.allocPrint(alloc, "GET /api/stream/{s} HTTP/1.1\r\nHost: {s}:{d}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n", .{ app.session_id, globals.HTTP_HOST, app.http_port });
    std.debug.print("[DEBUG] stream_request created, len={d}\n", .{stream_request.len});

    // Use stream writer instead of raw write
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(app.io, &write_buf);
    try std.Io.Writer.writeAll(&writer.interface, stream_request);
    std.debug.print("[DEBUG] write done via stream writer\n", .{});

    std.debug.print("[DEBUG] SSE connected, sending message: {s}\n", .{message});
    messaging.sendMessage(app, message) catch |err| {
        std.debug.print("[DEBUG] sendMessage error: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("[DEBUG] Message sent, starting poll loop\n", .{});

    const READ_SIZE: usize = 1024 * 64;
    const MAX_POLL_ITERATIONS: usize = 300; // 30 seconds max

    var poll_iterations: usize = 0;

    while (true) {
        const now = getTimeMillis();

        if (app.is_noninteractive) {
            poll_iterations += 1;
            if (poll_iterations > MAX_POLL_ITERATIONS) {
                std.debug.print("[DEBUG] max poll iterations reached, breaking\n", .{});
                break;
            }
            // Non-interactive: poll only the socket
            var poll_fd = [1]std.c.pollfd{
                .{ .fd = stream_socket, .events = std.c.POLL.IN, .revents = 0 },
            };
            const ready = std.c.poll(&poll_fd, poll_fd.len, 100);

            if (ready > 0) {
                if (poll_fd[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR) != 0) {
                    std.debug.print("[DEBUG] poll HUP/ERR\n", .{});
                    break;
                }
                if (poll_fd[0].revents & std.c.POLL.IN != 0) {
                    try raw_buffer.ensureUnusedCapacity(app.allocator, READ_SIZE);
                    const slice = raw_buffer.unusedCapacitySlice();
                    const n = std.c.read(stream_socket, slice[0..@min(slice.len, READ_SIZE)].ptr, @min(slice.len, READ_SIZE));
                    if (n <= 0) break;
                    raw_buffer.items.len += @intCast(n);
                }
            }

            // Check if stream is done (keepalive or any data)
            if (raw_buffer.items.len > 0) {
                if (std.mem.indexOf(u8, raw_buffer.items, ": keepalive") != null) {
                    std.debug.print("[DEBUG] keepalive detected, checking stream done\n", .{});
                    if (try checkStreamDone(app)) {
                        std.debug.print("[DEBUG] stream done, breaking\n", .{});
                        break;
                    }
                }
            }
            continue;
        }

        // Interactive: poll socket + stdin, parse & print in real-time
        raw_buffer.clearAndFree(app.allocator);
        var poll_fds = [2]std.c.pollfd{
            .{ .fd = stream_socket, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = std.c.STDIN_FILENO, .events = std.c.POLL.IN, .revents = 0 },
        };
        const ready = std.c.poll(&poll_fds, poll_fds.len, 100);

        if (ready > 0) {
            if (poll_fds[1].revents & std.c.POLL.IN != 0) {
                if (checkStdinForDoubleEscape(app)) {
                    messaging.sendDoubleEscapeCommand(app) catch {};
                    break;
                }
                poll_fds[1].revents = 0;
            }

            if (poll_fds[0].revents & std.c.POLL.IN != 0) {
                try raw_buffer.ensureUnusedCapacity(app.allocator, READ_SIZE);
                const slice = raw_buffer.unusedCapacitySlice();
                const n = std.c.read(stream_socket, slice[0..@min(slice.len, READ_SIZE)].ptr, @min(slice.len, READ_SIZE));
                if (n <= 0) break;
                raw_buffer.items.len += @intCast(n);
                poll_fds[0].revents = 0;
            }

            if (poll_fds[0].revents & (std.c.POLL.HUP | std.c.POLL.ERR) != 0) break;
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
    std.debug.print("[DEBUG] About to print final message\n", .{});
    printFinalMessage(app);
    std.debug.print("[DEBUG] Finished printing final message\n", .{});

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
    const n = std.c.read(std.posix.STDIN_FILENO, &buf, buf.len);
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
        const now = getTimeMillis();
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

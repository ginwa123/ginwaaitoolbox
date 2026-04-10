const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;
const SseStreamCtx = @import("mod.zig").SseStreamCtx;

/// Format an SSE event from queue item into a buffer
fn formatQueueItemInto(item: *http_server.SseQueueItem, buf: []u8) error{BufferTooSmall}![]u8 {
    var pos: usize = 0;

    // Write event type line if specified
    if (item.event_type) |event_type| {
        // Need: "event: " (7) + event_type.len + 1 (newline)
        if (pos + 7 + event_type.len + 1 > buf.len) return error.BufferTooSmall;
        const event_line = std.fmt.bufPrint(buf[pos..], "event: {s}\n", .{event_type}) catch unreachable;
        pos += event_line.len;
    }

    // Write data line
    if (item.data.len == 0) {
        // Need: "data: \n" (7) + 1 (final newline) = 8
        if (pos + 8 > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..7], "data: \n");
        pos += 7;
    } else {
        // Need: 6 ("data: ") + data.len + 1 (newline) + 1 (final newline)
        if (pos + 6 + item.data.len + 2 > buf.len) return error.BufferTooSmall;
        @memcpy(buf[pos..][0..6], "data: ");
        pos += 6;
        @memcpy(buf[pos..][0..item.data.len], item.data);
        pos += item.data.len;
        buf[pos] = '\n';
        pos += 1;
    }

    // Final newline to end the event
    if (pos + 1 > buf.len) return error.BufferTooSmall;
    buf[pos] = '\n';
    pos += 1;

    return buf[0..pos];
}

/// SSE stream handler - this thread OWNS the stream and reads events from the queue
fn sseStreamHandler(ctx: SseStreamCtx, stream: std.net.Stream) void {
    std.log.info("SSE stream handler started: session_id={s}", .{ctx.session_id});

    // Create a queue for this session - we'll register it with the manager
    const queue = ctx.server.sse_manager.createQueue() catch {
        std.log.err("SSE: Failed to create queue for session: {s}", .{ctx.session_id});
        return;
    };
    defer {
        queue.close();
        ctx.server.allocator.destroy(queue);
    }

    // Register the queue (not the stream) with the manager
    ctx.server.sse_manager.register(ctx.session_id, queue) catch {
        std.log.err("SSE: Failed to register queue for session: {s}", .{ctx.session_id});
        return;
    };
    defer ctx.server.sse_manager.remove(ctx.session_id);

    // Send connected event
    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\n{{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id}) catch {
        std.log.err("SSE: Failed to format connected event", .{});
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    stream.writeAll(connected_data) catch |err| {
        std.log.err("SSE: Failed to write connected event: {s}", .{@errorName(err)});
        return;
    };

    std.log.info("SSE: Connected event sent for session: {s}", .{ctx.session_id});

    // Main loop: process events from queue and keepalive
    while (ctx.server.sse_manager.hasSession(ctx.session_id)) {
        // Wait for an event from the queue with 5 second timeout
        const item = queue.dequeueWithTimeout(5_000_000_000);

        if (item) |queue_item| {
            // Format and send the event
            var stack_buf: [http_server.SseEvent.MAX_SSE_SIZE]u8 = undefined;
            const formatted = formatQueueItemInto(queue_item, &stack_buf) catch {
                std.log.warn("SSE: event too large for buffer", .{});
                // Free queue item memory
                ctx.server.allocator.free(queue_item.data);
                if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                ctx.server.allocator.destroy(queue_item);
                continue;
            };

            stream.writeAll(formatted) catch |err| {
                std.log.warn("SSE write failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) });
                // Free queue item memory before exiting
                ctx.server.allocator.free(queue_item.data);
                if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                ctx.server.allocator.destroy(queue_item);
                break;
            };

            // Free queue item memory after successful send
            ctx.server.allocator.free(queue_item.data);
            if (queue_item.event_type) |et| ctx.server.allocator.free(et);
            ctx.server.allocator.destroy(queue_item);
        } else {
            // Timeout - send keepalive
            stream.writeAll(": keepalive\n\n") catch |err| {
                std.log.warn("SSE keepalive failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) });
                break;
            };
        }
    }

    std.log.info("SSE stream handler ending: session_id={s}", .{ctx.session_id});
    ctx.server.allocator.free(ctx.session_id);
}

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    };

    if (http_server.global_server) |server| {
        std.log.info("SSE STREAM CONNECTED: session_id={s}", .{session_id});

        const session_id_copy = try server.allocator.dupe(u8, session_id);
        errdefer server.allocator.free(session_id_copy);

        const ctx = SseStreamCtx{
            .server = server,
            .session_id = session_id_copy,
        };

        try res.startEventStream(ctx, sseStreamHandler);
    } else {
        res.status = 500;
        res.body = "Server not available";
    }
}

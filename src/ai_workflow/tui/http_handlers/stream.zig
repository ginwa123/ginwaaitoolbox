const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;
const SseStreamCtx = @import("mod.zig").SseStreamCtx;

/// Format an SSE event from queue item using heap allocation
fn formatQueueItem(allocator: std.mem.Allocator, item: *http_server.SseQueueItem) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Write event type line if specified
    if (item.event_type) |event_type| {
        try buf.appendSlice(allocator, "event: ");
        try buf.appendSlice(allocator, event_type);
        try buf.append(allocator, '\n');
    }

    // Write data line
    if (item.data.len == 0) {
        try buf.appendSlice(allocator, "data: \n");
    } else {
        try buf.appendSlice(allocator, "data: ");
        try buf.appendSlice(allocator, item.data);
        try buf.append(allocator, '\n');
    }

    // Final newline to end the event
    try buf.append(allocator, '\n');

    return try buf.toOwnedSlice(allocator);
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
            // Format and send the event using heap allocation
            const formatted = formatQueueItem(ctx.server.allocator, queue_item) catch |err| {
                std.log.warn("SSE: failed to format event: {}", .{err});
                // Free queue item memory
                ctx.server.allocator.free(queue_item.data);
                if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                ctx.server.allocator.destroy(queue_item);
                continue;
            };
            defer ctx.server.allocator.free(formatted);

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

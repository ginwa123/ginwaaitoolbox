const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const logger = root_mod.logger;

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

/// SSE stream handler - this thread OWNS the stream and reads events from its own queue
/// Each client gets its own queue, so multiple clients can connect to the same session
fn sseStreamHandler(ctx: SseStreamCtx, stream: std.net.Stream) void {
    const log = logger.getGlobal();
    log.?.infoFmt("SSE stream handler started: session_id={s}", .{ctx.session_id}) catch {};

    // Create a queue for this specific client
    const queue = ctx.server.sse_manager.createQueue() catch {
        log.?.errFmt("SSE: Failed to create queue for session: {s}", .{ctx.session_id}) catch {};
        return;
    };
    defer {
        queue.close();
        ctx.server.allocator.destroy(queue);
    }

    // Register this client with its own queue (supports multiple clients per session)
    ctx.server.sse_manager.registerClient(ctx.session_id, queue) catch |err| {
        log.?.errFmt("SSE: Failed to register client for session: {s}, error: {s}", .{
            ctx.session_id, @errorName(err),
        }) catch {};
        return;
    };
    defer {
        // Remove only this specific client, not the whole session
        const was_last = ctx.server.sse_manager.removeClient(ctx.session_id, queue);
        if (was_last) {
            log.?.infoFmt("SSE: Last client removed, session cleaned up: {s}", .{ctx.session_id}) catch {};
        }
    }

    // Send connected event
    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\n{{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id}) catch {
        log.?.errFmt("SSE: Failed to format connected event", .{}) catch {};
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    stream.writeAll(connected_data) catch |err| {
        log.?.errFmt("SSE: Failed to write connected event: {s}", .{@errorName(err)}) catch {};
        return;
    };

    // Get client count for logging
    const client_count = ctx.server.sse_manager.getClientCount(ctx.session_id);
    log.?.infoFmt("SSE: Connected event sent for session: {s}, total clients: {d}", .{
        ctx.session_id, client_count,
    }) catch {};

    // Main loop: process events from queue and keepalive
    while (ctx.server.sse_manager.hasSession(ctx.session_id)) {
        // Wait for an event from the queue with 5 second timeout
        const item = queue.dequeueWithTimeout(5_000_000_000);

        if (item) |queue_item| {
            // Log body before sending
            log.?.debugFmt("SSE: sending body: {s}", .{queue_item.data}) catch {};

            // Format and send the event using heap allocation
            const formatted = formatQueueItem(ctx.server.allocator, queue_item) catch |err| {
                log.?.warnFmt("SSE: failed to format event: {}", .{err}) catch {};
                // Free queue item memory
                ctx.server.allocator.free(queue_item.data);
                if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                ctx.server.allocator.destroy(queue_item);
                continue;
            };
            defer ctx.server.allocator.free(formatted);

            // Log formatted SSE data before sending
            log.?.debugFmt("SSE: sending formatted: {s}", .{formatted}) catch {};

            stream.writeAll(formatted) catch |err| {
                log.?.warnFmt("SSE write failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) }) catch {};
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
                log.?.warnFmt("SSE keepalive failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) }) catch {};
                break;
            };
        }
    }

    log.?.infoFmt("SSE stream handler ending: session_id={s}", .{ctx.session_id}) catch {};
    ctx.server.allocator.free(ctx.session_id);
}

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    };

    const log = logger.getGlobal();

    if (http_server.global_server) |server| {
        log.?.infoFmt("SSE STREAM CONNECTED: session_id={s}", .{session_id}) catch {};

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

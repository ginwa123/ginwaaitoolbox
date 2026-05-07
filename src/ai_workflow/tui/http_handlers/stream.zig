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

    // Write data lines - handle multi-line data properly
    if (item.data.len == 0) {
        try buf.appendSlice(allocator, "data: \n");
    } else {
        // Split by newline and prefix each line with "data: "
        var iter = std.mem.splitScalar(u8, item.data, '\n');
        while (iter.next()) |line| {
            try buf.appendSlice(allocator, "data: ");
            try buf.appendSlice(allocator, line);
            try buf.append(allocator, '\n');
        }
    }

    // Final newline to end the event
    try buf.append(allocator, '\n');

    return try buf.toOwnedSlice(allocator);
}

/// SSE stream handler - this thread OWNS the stream and reads events from its own queue
/// Each client gets its own queue, so multiple clients can connect to the same session
fn sseStreamHandler(ctx: SseStreamCtx, stream: std.Io.net.Stream) void {
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
    defer stream.close(ctx.server.io);

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
        std.debug.print("[SSE_ERROR] Failed to format connected event\n", .{});
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    std.debug.print("[SSE_DEBUG] About to write connected event, len={d}\n", .{connected_data.len});

    // Use raw posix.write instead of Stream writer to avoid any buffering issues
    const socket_fd = stream.socket.handle;
    var bytes_written: usize = 0;
    while (bytes_written < connected_data.len) {
        const n = std.c.write(@intCast(socket_fd), connected_data[bytes_written..].ptr, connected_data[bytes_written..].len);
        if (n < 0) {
            std.debug.print("[SSE_ERROR] write failed\n", .{});
            return;
        }
        if (n == 0) {
            std.debug.print("[SSE_ERROR] write returned 0\n", .{});
            return;
        }
        bytes_written += @intCast(n);
    }
    std.debug.print("[SSE_DEBUG] Wrote {d} bytes via raw c.write\n", .{bytes_written});

    // Get client count for logging
    const client_count = ctx.server.sse_manager.getClientCount(ctx.session_id);
    log.?.infoFmt("SSE: Connected event sent for session: {s}, total clients: {d}", .{
        ctx.session_id, client_count,
    }) catch {};

    // Main loop: process events from queue and keepalive
    // Note: We don't check hasSession() here because for new sessions,
    // hasSession returns false until the workflow enqueues its first event.
    // The session is properly cleaned up via removeClient when the client disconnects.
    while (!queue.closed) {
        // Wait for an event from the queue with 5 second timeout
        const item = queue.dequeueWithTimeout(5_000_000_000);

        if (item) |queue_item| {
            std.debug.print("[SSE_DEBUG] dequeueWithTimeout returned item, data_len={d}\n", .{queue_item.data.len});
            std.debug.print("[SSE_DEBUG] queue_item.data contents: {s}\n", .{queue_item.data});
            // Log body before sending
            log.?.debugFmt("SSE: sending body: {s}", .{queue_item.data}) catch {};

            // Format and send the event using heap allocation
            const formatted = formatQueueItem(ctx.server.allocator, queue_item) catch |err| {
                std.debug.print("[SSE_ERROR] formatQueueItem failed: {}\n", .{err});
                // Free queue item memory
                ctx.server.allocator.free(queue_item.data);
                if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                ctx.server.allocator.destroy(queue_item);
                continue;
            };
            defer ctx.server.allocator.free(formatted);

            std.debug.print("[SSE_DEBUG] formatted len={d}, sending...\n", .{formatted.len});
            // Use raw c.write for SSE data as well
            const sfd = stream.socket.handle;
            var bytes_sent: usize = 0;
            while (bytes_sent < formatted.len) {
                const n = std.c.write(@intCast(sfd), formatted[bytes_sent..].ptr, formatted[bytes_sent..].len);
                if (n < 0) {
                    std.debug.print("[SSE_ERROR] SSE write failed\n", .{});
                    ctx.server.allocator.free(queue_item.data);
                    if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                    ctx.server.allocator.destroy(queue_item);
                    break;
                }
                bytes_sent += @intCast(n);
            }
            std.debug.print("[SSE_DEBUG] SSE write completed, {d} bytes\n", .{bytes_sent});

            // Free queue item memory after successful send
            ctx.server.allocator.free(queue_item.data);
            if (queue_item.event_type) |et| ctx.server.allocator.free(et);
            ctx.server.allocator.destroy(queue_item);
        } else {
            // Timeout - send keepalive
            const keepalive_text = ": keepalive\n\n";
            const kfd = stream.socket.handle;
            _ = std.c.write(@intCast(kfd), keepalive_text.ptr, keepalive_text.len);
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

const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const http_response = nalar_core.http_response;
const logger = nalar_core.logger;

const SseStreamCtx = @import("mod.zig").SseStreamCtx;

/// Format an SSE event from queue item using heap allocation
fn formatQueueItem(allocator: std.mem.Allocator, item: *gserverz.SseQueueItem) ![]u8 {
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
    log.?.infoFmt("SSE stream handler started: session_id={s}", .{ctx.session_id});

    // Create a queue for this specific client
    const queue = ctx.server.sse_manager.createQueue() catch {
        log.?.errFmt("SSE: Failed to create queue for session: {s}", .{ctx.session_id});
        return;
    };

    // Register this queue with the session
    ctx.server.sse_manager.registerSession(ctx.session_id, queue) catch {
        log.?.errFmt("SSE: Failed to register queue for session: {s}", .{ctx.session_id});
        return;
    };

    // Register cleanup on return
    defer {
        ctx.server.sse_manager.unregisterSession(ctx.session_id);
    }

    const allocator = ctx.server.allocator;

    // Send initial connection event
    const connectEvent = try std.fmt.allocPrint(allocator, "event: connected\ndata: {{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id});
    defer allocator.free(connectEvent);
    stream.writeAll(connectEvent) catch {
        log.?.errFmt("SSE: Failed to send connect event for session: {s}", .{ctx.session_id});
        return;
    };

    // Main event loop
    var connected = true;
    while (connected) {
        // Wait for event with timeout
        if (queue.waitForEvent(5000)) {
            // Process all available events
            while (queue.dequeue()) |item| {
                const event_data = formatQueueItem(allocator, item) catch {
                    log.?.errFmt("SSE: Failed to format event for session: {s}", .{ctx.session_id});
                    continue;
                };
                defer allocator.free(event_data);

                stream.writeAll(event_data) catch {
                    log.?.errFmt("SSE: Failed to send event for session: {s}", .{ctx.session_id});
                    connected = false;
                    break;
                };
            }
        }

        // Check if session still exists
        if (!ctx.server.sse_manager.hasSession(ctx.session_id)) {
            log.?.infoFmt("SSE: Session removed: {s}", .{ctx.session_id});
            break;
        }

        // Send keepalive
        const keepalive_text = ": keepalive\n\n";
        const kfd = stream.handle;
        _ = std.c.write(@intCast(kfd), keepalive_text.ptr, keepalive_text.len);
    }

    log.?.infoFmt("SSE stream handler ending: session_id={s}", .{ctx.session_id});
    ctx.server.allocator.free(ctx.session_id);
}

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    const log = logger.getGlobal();

    if (gserverz.global_server) |server| {
        log.?.infoFmt("SSE STREAM CONNECTED: session_id={s}", .{session_id});

        // For now, just return a JSON response indicating SSE is not fully implemented
        // The custom HTTP server doesn't support streaming responses like httpz does
        _ = server;
        return res.jsonResponse( .{ .status_code = 501, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "SSE streaming not implemented in custom HTTP server" }) });
    } else {
        return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not available" }) });
    }
}

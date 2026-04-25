const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const ai_workflow = root_mod.ai_workflow;

const httpz = http_server.httpz;
const logger_mod = root_mod.logger;

/// SSE stream context for session events
pub const SessionStreamCtx = struct {
    server: *http_server.HttpServer,
    log: *logger_mod.Logger,
};

/// Format an SSE event from queue item using heap allocation
fn formatSessionEvent(allocator: std.mem.Allocator, data: []const u8, event_type: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    // Write event type line
    try buf.appendSlice(allocator, "event: ");
    try buf.appendSlice(allocator, event_type);
    try buf.append(allocator, '\n');

    // Write data line
    try buf.appendSlice(allocator, "data: ");
    try buf.appendSlice(allocator, data);
    try buf.append(allocator, '\n');

    // Final newline to end the event
    try buf.append(allocator, '\n');

    return try buf.toOwnedSlice(allocator);
}

/// SSE stream handler for session events - broadcasts session_created events
/// Clients connect to receive notifications when sessions are created
fn sessionSseStreamHandler(ctx: SessionStreamCtx, stream: std.net.Stream) void {
    ctx.log.infoFmt("Session SSE stream handler started", .{}) catch {};

    // Create a queue for this specific client
    const queue = ctx.server.sse_manager.createQueue() catch {
        ctx.log.errFmt("Session SSE: Failed to create queue", .{}) catch {};
        return;
    };
    defer {
        queue.close();
        ctx.server.allocator.destroy(queue);
    }

    // Register this client with a special session ID for session events
    const session_key = "_session_events_";
    ctx.server.sse_manager.registerClient(session_key, queue) catch |err| {
        ctx.log.errFmt("Session SSE: Failed to register client, error: {s}", .{@errorName(err)}) catch {};
        return;
    };
    defer {
        _ = ctx.server.sse_manager.removeClient(session_key, queue);
    }

    // Send connected event
    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\n{{\"type\":\"session_stream\"}}\n\n", .{}) catch {
        ctx.log.errFmt("Session SSE: Failed to format connected event", .{}) catch {};
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    stream.writeAll(connected_data) catch |err| {
        ctx.log.errFmt("Session SSE: Failed to write connected event: {s}", .{@errorName(err)}) catch {};
        return;
    };

    // Main loop: process events from queue and keepalive
    while (ctx.server.sse_manager.hasSession(session_key)) {
        // Wait for an event from the queue with 30 second timeout
        const item = queue.dequeueWithTimeout(30_000_000_000);

        if (item) |queue_item| {
            // Format and send the event using heap allocation
            const event_type = queue_item.event_type orelse "message";
            const formatted = formatSessionEvent(ctx.server.allocator, queue_item.data, event_type) catch |err| {
                ctx.log.warnFmt("Session SSE: failed to format event: {}", .{err}) catch {};
                ctx.server.allocator.free(queue_item.data);
                if (queue_item.event_type) |et| ctx.server.allocator.free(et);
                ctx.server.allocator.destroy(queue_item);
                continue;
            };
            defer ctx.server.allocator.free(formatted);

            stream.writeAll(formatted) catch |err| {
                ctx.log.warnFmt("Session SSE write failed: {s}", .{@errorName(err)}) catch {};
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
                ctx.log.warnFmt("Session SSE keepalive failed: {s}", .{@errorName(err)}) catch {};
                break;
            };
        }
    }

    ctx.log.infoFmt("Session SSE stream handler ending", .{}) catch {};
}

/// Broadcast a session_created event to all connected session stream clients
pub fn broadcastSessionCreated(allocator: std.mem.Allocator, session_id: []const u8, session_name: []const u8) void {
    if (http_server.global_server) |server| {
        const event_data = std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"event\":\"session_created\"}}", .{
            session_id, session_name,
        }) catch return;
        defer allocator.free(event_data);

        const event = http_server.SseEvent{
            .data = event_data,
            .event_type = "session_created",
        };

        // Broadcast to all clients listening on the session events stream
        const session_key = "_session_events_";
        server.sse_manager.enqueueEvent(session_key, event) catch {
            // If no clients are listening, that's okay - just log a debug message
            std.log.debug("Session SSE: No clients listening for session events", .{});
        };
    }
}

/// Session events SSE stream endpoint - notifies clients when sessions are created
pub fn sessionStreamHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req;

    if (http_server.global_server) |server| {
        const log = logger_mod.getGlobal();
        log.?.infoFmt("Session SSE STREAM CONNECTED", .{}) catch {};

        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));

            const ctx_stream = SessionStreamCtx{
                .server = server,
                .log = ctxTui.logger,
            };

            try res.startEventStream(ctx_stream, sessionSseStreamHandler);
        } else {
            res.status = 500;
            res.body = "Server not initialized";
        }
    } else {
        res.status = 500;
        res.body = "Server not available";
    }
}

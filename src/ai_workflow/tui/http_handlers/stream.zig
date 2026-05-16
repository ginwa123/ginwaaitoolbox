const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;

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

pub const CallbackAiStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const session_id = data.session_id;
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const server = di.server;

        std.debug.print("SSE_DEBUG: callback for session {s}\n", .{session_id});

        const client_id = ai_mod.getClientIdForSession(session_id) orelse return;
        std.debug.print("GILANG_SERVER 2: client_id={s}\n", .{client_id});

        std.debug.print("SSE_DEBUG: got client_id {s}, sending event\n", .{client_id});
        const event_str = std.fmt.allocPrint(allocator, "data: {s}\n\n", .{data.data}) catch return;
        defer allocator.free(event_str);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        if (data.event_type) |event_type| {
             buf.appendSlice(allocator, "event: ") catch return;
             buf.appendSlice(allocator, event_type) catch return;
             buf.append(allocator, '\n') catch return;
        }

        if (data.data.len == 0) {
             buf.appendSlice(allocator, "data: \n") catch return;
        } else {
            var iter = std.mem.splitScalar(u8, data.data, '\n');
            while (iter.next()) |line| {
                 buf.appendSlice(allocator, "data: ") catch return;
                 buf.appendSlice(allocator, line) catch return;
                 buf.append(allocator, '\n') catch return;
            }
        }
         buf.append(allocator, '\n') catch return;
        const dataaaa = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(dataaaa);


        server.sse_manager.sendToClient(client_id, dataaaa) catch {};
    }
};

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalar_core.getSingleton();
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    std.debug.print("STREAM_HANDLER: session_id={s} client_id present={}\n", .{
        session_id,
        ctx.client_id != null,
    });

    // Register the client_id mapping (set by http_server after registerClient)
    if (ctx.client_id) |client_id| {
        std.debug.print("STREAM_HANDLER: registering client_id for session {s}\n", .{session_id});
        std.debug.print("STREAM_HANDLER: client_id={s}\n", .{client_id});
        std.debug.print("GILANG_SERVER: client_id={s}\n", .{client_id});

        // Check if this session already has a client - clean up old one first
        // if (ai_mod.on_event_sent.getClientIdForSession(session_id)) |_| {
        //     std.debug.print("STREAM_HANDLER: cleaning up old client for session {s}\n", .{session_id});
        //     ai_mod.on_event_sent.unregisterSessionClient(session_id);
        //     di.event_bus.unsubscribe(session_id);
        // }

        ai_mod.registerSessionClient(session_id, client_id) catch {};

        // Set up disconnect callback to clean up event bus subscription
        // ai_mod.on_event_sent.on_disconnect_cb = ai_mod.on_event_sent.handleClientDisconnect;
    }

    const event_bus = di.event_bus;

    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, session_id, CallbackAiStream.callback) catch {};

    return error.WouldBlock; // Handler should not complete - connection stays open
}

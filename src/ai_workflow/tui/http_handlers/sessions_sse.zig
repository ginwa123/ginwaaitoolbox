const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;


/// Callback for session SSE events - broadcasts to client
pub const CallbackSessionsStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const server = di.server;

        // Get ALL client_ids for "sessions" routing, not just the first
        const maybe_clients = ai_mod.getListClientsForSession("sessions", allocator, false) catch return;
        const client_ids = maybe_clients orelse return;

        if (client_ids.len == 0) return;

        // Build SSE message once (reused for all clients)
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Add event type if present
        if (data.event_type) |event_type| {
            buf.appendSlice(allocator, "event: ") catch return;
            buf.appendSlice(allocator, event_type) catch return;
            buf.append(allocator, '\n') catch return;
        }

        // Split data by newlines and prefix with "data: "
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

        const sse_event_data = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(sse_event_data);

        // Send to ALL clients for "sessions"
        for (client_ids) |client_id| {
            server.sse_manager.sendToClient(client_id, sse_event_data) catch {};
        }
    }
};

/// SSE stream endpoint for session events - subscribes to "sessions" routing key
/// Clients connect here to receive session list updates (created, updated, deleted)
pub fn sessionsStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    _ = res;

    const di = try nalar_core.getSingleton();
    const event_bus = di.event_bus;

    // Register client mapping for "sessions" routing key
    if (ctx.client_id) |client_id| {
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient("sessions", client_id_copy, true) catch {};
    }

    // Subscribe to session events with callback
    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, "sessions", CallbackSessionsStream.callback) catch {};

    return error.WouldBlock; // Keep connection open
}

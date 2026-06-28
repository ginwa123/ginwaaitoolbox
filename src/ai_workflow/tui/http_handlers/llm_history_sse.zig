const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;

const SseStreamCtx = @import("mod.zig").SseStreamCtx;

pub const CallbackAiStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const session_id = data.session_id;
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const server = di.server;

        // Get ALL client_ids for this session, not just the first.
        // `getListClientsForSession` returns an owned copy; the slice is
        // detached from the global `session_to_client_ids` map so the
        // SSE event loop can safely `unregisterSessionClient` this
        // session on a POLL.HUP while we are still iterating here.
        const maybe_clients = ai_mod.getListClientsForSession(session_id, allocator, false) catch return;
        defer if (maybe_clients) |c| allocator.free(c);
        const client_ids = maybe_clients orelse return;

        if (client_ids.len == 0) return;

        // Build SSE message once (reused for all clients)
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
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
        const sse_event_data = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(sse_event_data);

        // Send to ALL clients for this session
        for (client_ids) |client_id| {
            server.sse_manager.sendToClient(client_id, sse_event_data) catch {};
        }
    }
};

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn llmHistorySSE(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalar_core.getSingleton();
    const global_allocator = di.allocator;
    const server = di.server;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    // Register the client_id mapping (set by http_server after registerClient)
    if (ctx.client_id) |client_id| {
        const session_id_copy = try global_allocator.dupe(u8, session_id);
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient(session_id_copy, client_id_copy, true) catch {};

        // Deferred to keep the handler task non-blocking — see
        // SseManager.sendDeferred (docs/plans/2026-06-30-fix-sse-blocking-api.md).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendDeferred(client_id_copy, connected_event);
    }

    const event_bus = di.event_bus;

    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, session_id, CallbackAiStream.callback) catch {};

    return error.WouldBlock; // Handler should not complete - connection stays open
}

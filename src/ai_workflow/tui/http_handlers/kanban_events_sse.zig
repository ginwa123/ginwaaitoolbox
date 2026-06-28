//! SSE stream endpoint for kanban events.
//!
//! The frontend opens a single `EventSource('/api/kanban/events')` (see
//! `createKanbanSseConnection` in `src/apps/desktop/...`) and expects
//! BOTH `kanban_column` and `kanban_task` named events on that one
//! stream. The emitters in `on_event_sent_kanban.zig` publish to TWO
//! separate event_bus routing keys (`"kanban_column"` and
//! `"kanban_task"`), so this handler fans out both keys onto one
//! client connection by:
//!
//!   1. Registering the connecting client under BOTH routing keys.
//!   2. Subscribing ONE callback per key. Each callback looks up the
//!      client list for its own key and forwards the SSE bytes to
//!      every registered client.
//!
//! The callback receives an `SseEvent` (the emitted payload) and is
//! bound to a specific routing key by the `event_bus.subscribe` call.
//! Mirrors the worker_sse.zig pattern at line 20.
//!
//! Plan: docs/superpowers/plans/2026-06-25-kanban-list-fix.md (Chunk 5).

const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;

/// Forward an SSE event to every client registered under `routing_key`.
///
/// Mirrors the helper inline in `worker_sse.zig:10-57`. Exposed as a
/// reusable function so we can call it from BOTH the column and task
/// callbacks without duplicating the SSE-framing logic.
fn forwardToClients(routing_key: []const u8, data: ai_mod.on_event_sent.SseEvent) void {
    const di = nalar_core.getSingleton() catch return;
    const allocator = di.allocator;
    const server = di.server;

    // Detach the client list from the global map before iterating, so
    // the SSE event loop can safely `unregisterSessionClient` on a
    // POLL.HUP while we are still iterating here.
    const maybe_clients = ai_mod.getListClientsForSession(routing_key, allocator, false) catch return;
    defer if (maybe_clients) |c| allocator.free(c);
    const client_ids = maybe_clients orelse return;

    if (client_ids.len == 0) return;

    // Build the SSE frame once, send to every subscriber.
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

    for (client_ids) |client_id| {
        server.sse_manager.sendToClient(client_id, sse_event_data) catch {};
    }
}

/// Callback for `kanban_column` routing key — fires on column create/update/delete.
pub const CallbackKanbanColumnStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_column", data);
    }
};

/// Callback for `kanban_task` routing key — fires on task create/move/update/delete.
pub const CallbackKanbanTaskStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_task", data);
    }
};

/// SSE stream endpoint for kanban events - subscribes to BOTH
/// "kanban_column" and "kanban_task" routing keys and forwards every
/// event to the connected client(s).
pub fn kanbanEventsStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    _ = res;

    const di = try nalar_core.getSingleton();
    const event_bus = di.event_bus;
    const server = di.server;

    // Register the connecting client under BOTH routing keys so it
    // receives events published under either key.
    if (ctx.client_id) |client_id| {
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient("kanban_column", client_id_copy, true) catch {};
        ai_mod.registerSessionClient("kanban_task", client_id_copy, true) catch {};

        // Send the "connected" ack so the frontend's `onopen` fires.
        // Deferred via `sendDeferred` so the handler task's
        // `group.concurrent` worker thread is freed immediately —
        // see docs/plans/2026-06-30-fix-sse-blocking-api.md. The
        // connected_event string is a static literal, so it's safe
        // to defer (lifetime contract documented on SseManager.sendDeferred).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendDeferred(client_id_copy, connected_event);
    }

    // Subscribe a callback to BOTH routing keys. Each callback fans
    // out to the clients registered for its own key only.
    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, "kanban_column", CallbackKanbanColumnStream.callback) catch {};
    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, "kanban_task", CallbackKanbanTaskStream.callback) catch {};

    return error.WouldBlock; // Keep connection open
}

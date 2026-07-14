//! Unified SSE stream endpoint for all server-pushed events.
//!
//! Replaces the 5 dedicated SSE routes registered in main.zig:
//!   - GET /api/workers/stream
//!   - GET /api/sessions/stream
//!   - GET /api/llm/stream/:session_id
//!   - GET /api/llm/session/:session_id/queue_messages/stream
//!   - GET /api/kanban/events
//!
//! The client opens ONE EventSource and declares which channel families
//! it cares about via the `?channels=` query parameter:
//!
//!   /api/events?channels=workers,sessions,kanban
//!   /api/events?channels=llm
//!   /api/events?channels=queue
//!   /api/events?channels=workers,sessions,kanban,llm,queue
//!
//! Channel tokens and the event_bus routing keys they fan out to:
//!   workers        → "workers"
//!   sessions       → "sessions"
//!   kanban         → "kanban_column", "kanban_task"
//!   design_element → "design_element" (central key — all workspaces' design
//!                    element create/update/delete events; the frontend
//!                    filters by `data.workspace_id` JS-side)
//!   llm            → "llm"          (central key — all sessions' LLM events)
//!   queue          → "queue"        (central key — all sessions' queue events)
//!
//! Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md

const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const ai_mod = nalar_core.ai_mod;

/// Forward an SSE event to every client registered under `routing_key`.
///
/// Lifted verbatim from kanban_events_sse.zig:34-76. Subscription-lock-safe:
/// `getListClientsForSession` returns an owned copy of the client list, so
/// the SSE event loop can safely `unregisterSessionClient` on POLL.HUP
/// while we are still iterating here.
fn forwardToClients(routing_key: []const u8, data: ai_mod.on_event_sent.SseEvent) void {
    const di = nalar_core.getSingleton() catch return;
    const allocator = di.allocator;
    const server = di.server;

    const maybe_clients = ai_mod.getListClientsForSession(routing_key, allocator, false) catch return;
    defer if (maybe_clients) |c| allocator.free(c);
    const client_ids = maybe_clients orelse return;
    if (client_ids.len == 0) return;

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

/// ChannelList — the parsed result of `?channels=`.
pub const ChannelList = struct {
    /// Each entry is a routing key the handler must subscribe a
    /// callback to. Duplicates are not deduplicated (the SSE
    /// event_bus handles duplicate subscribers without error).
    routing_keys: []const []const u8,

    pub fn deinit(self: ChannelList, allocator: std.mem.Allocator) void {
        for (self.routing_keys) |k| allocator.free(k);
        allocator.free(self.routing_keys);
    }
};

/// Parse `?channels=workers,sessions,kanban,llm,queue`.
/// Returns the list of routing keys to subscribe + register. Returns
/// ChannelParseError on missing/empty/unknown channel tokens.
pub const ChannelParseError = error{
    MissingChannels,
    UnknownChannel,
    OutOfMemory,
};

/// `pub` so `unified_events_sse_test.zig` can import it for behavioral
/// tests (Plan Reviewer finding #3). The `pub` is harmless — the
/// function is only called from `unifiedEventsStreamHandler`.
pub fn parseChannels(allocator: std.mem.Allocator, raw: []const u8) ChannelParseError!ChannelList {
    // Trim whitespace from the raw value (the router does not trim).
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return error.MissingChannels;

    var routing_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (routing_keys.items) |k| allocator.free(k);
        routing_keys.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, " \t");
        if (token.len == 0) continue; // skip empty tokens (e.g. ",,,")

        if (std.mem.eql(u8, token, "workers")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "workers"));
        } else if (std.mem.eql(u8, token, "sessions")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "sessions"));
        } else if (std.mem.eql(u8, token, "kanban")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_column"));
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_task"));
        } else if (std.mem.eql(u8, token, "llm")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "llm"));
        } else if (std.mem.eql(u8, token, "queue")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "queue"));
        } else if (std.mem.eql(u8, token, "design_element")) {
            // Design-mode element mutations. The frontend
            // `createUnifiedSseConnection` sends this token; the
            // backend's `on_event_sent_design.zig` emits
            // `design_element_created/updated/deleted` on the central
            // "design_element" routing key. The single key covers all
            // three granular event types (the action discriminator
            // tells them apart JS-side).
            try routing_keys.append(allocator, try allocator.dupe(u8, "design_element"));
        } else {
            return error.UnknownChannel;
        }
    }

    // If the raw value was non-empty but every comma-delimited token
    // was empty (e.g. ",,,"), we still need to error. The trim+skip
    // path above would leave routing_keys empty without an explicit
    // error here — guard against that.
    if (routing_keys.items.len == 0) return error.MissingChannels;

    return ChannelList{ .routing_keys = try routing_keys.toOwnedSlice(allocator) };
}

// =============================================================================
// Callback structs (top-level, NOT inline).
//
// Each routing key gets its own callback. The routing key itself is
// hard-coded into the callback body — there's no closure capture of a
// loop variable (Pitfall 1: inline-struct capture trap). The handler
// picks the right callback by inspecting the routing-key SHAPE with
// an if/else chain (mirrors kanban_events_sse.zig:79-90).
// =============================================================================

/// Callback for `kanban_column` routing key — fires on column create/update/delete.
pub const CallbackUnifiedColumnStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_column", data);
    }
};

/// Callback for `kanban_task` routing key.
pub const CallbackUnifiedTaskStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("kanban_task", data);
    }
};

/// Callback for `workers` routing key.
pub const CallbackUnifiedWorkersStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("workers", data);
    }
};

/// Callback for `sessions` routing key.
pub const CallbackUnifiedSessionsStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("sessions", data);
    }
};

/// Callback for the central "llm" routing key. Forwards to every
/// client registered under "llm" — the frontend listener then
/// filters by `data.session_id` on the JS side.
pub const CallbackUnifiedLLMBroadcast = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("llm", data);
    }
};

/// Callback for the central "queue" routing key. Forwards to every
/// client registered under "queue" — the frontend listener then
/// filters by `data.session_id` on the JS side.
pub const CallbackUnifiedQueueBroadcast = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("queue", data);
    }
};

/// Callback for the central "design_element" routing key. Forwards
/// to every client registered under "design_element" — the frontend
/// listener (`designSse.ts` Pinia store) then filters by
/// `data.workspace_id` on the JS side and dispatches to the
/// `workspacesStore.fetchDesignElements` action.
pub const CallbackUnifiedDesignElementStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients("design_element", data);
    }
};

/// SSE stream endpoint — single endpoint for all server-pushed events.
///
/// The `?channels=` query parameter is REQUIRED. Returns HTTP 400
/// (via the early `res.jsonResponse`) if missing/empty/unknown.
pub fn unifiedEventsStreamHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Parse ?channels=
    const raw_channels = req.query.get("channels") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                \\{{"error":"missing channels query parameter"}}
            , .{}),
        });
    };
    var channels = parseChannels(allocator, raw_channels) catch |err| switch (err) {
        error.MissingChannels => return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                \\{{"error":"missing or empty channels query parameter"}}
            , .{}),
        }),
        error.UnknownChannel => return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                \\{{"error":"unknown channel in {s}"}}
            , .{raw_channels}),
        }),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer channels.deinit(allocator);

    // 2. Register + subscribe
    const di = try nalar_core.getSingleton();
    const event_bus = di.event_bus;
    const server = di.server;

    if (ctx.client_id) |client_id| {
        const client_id_copy: [16]u8 = client_id;

        // 2a. Register the client_id under EVERY routing key.
        // registerSessionClient dupes the key internally, so we can
        // pass each entry of channels.routing_keys (already-owned
        // slices) directly.
        for (channels.routing_keys) |rk| {
            ai_mod.registerSessionClient(rk, client_id_copy, true) catch {};
        }

        // 2b. Subscribe ONE callback per routing key. The callback
        // looks up the client list for ITS OWN routing key only —
        // see forwardToClients.
        for (channels.routing_keys) |rk| {
            // event_bus.subscribe dupes the key internally, so we can
            // pass each entry directly and it remains valid for the
            // call. See worker_sse.zig:81 and kanban_events_sse.zig:117.
            if (std.mem.eql(u8, rk, "kanban_column")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedColumnStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "kanban_task")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedTaskStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "workers")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedWorkersStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "sessions")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedSessionsStream.callback) catch {};
            } else if (std.mem.eql(u8, rk, "llm")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedLLMBroadcast.callback) catch {};
            } else if (std.mem.eql(u8, rk, "queue")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedQueueBroadcast.callback) catch {};
            } else if (std.mem.eql(u8, rk, "design_element")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk, CallbackUnifiedDesignElementStream.callback) catch {};
            }
        }

        // 3. Send the connected handshake (the verbatim byte sequence
        //    pinned by sse_handshake_test.zig:12).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
    }

    return error.WouldBlock; // Keep connection open
}
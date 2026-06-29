# Unify Backend SSE Endpoints Into One Stream

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the 5 SSE routes registered in `src/main.zig` (`/api/workers/stream`, `/api/sessions/stream`, `/api/llm/stream/:session_id`, `/api/llm/session/:session_id/queue_messages/stream`, `/api/kanban/events`) into a single backend SSE endpoint `/api/events` that the frontend opens once per app session (or once per chat view), then deletes the 5 old handlers/routes and their dedicated tests.

**Architecture:** Three coordinated changes:

1. **Backend — single `/api/events` SSE endpoint** with a comma-separated `?channels=` query param listing which event-bus routing keys the client wants to subscribe to. The handler registers the connecting `client_id` under ALL requested routing keys (e.g. `workers` → 1 key, `kanban` → 2 keys, `llm:<sid>` → 1 per-session key) and fans every event out to the connected client. Mirrors the existing `/api/kanban/events` precedent (which already fans out `kanban_column` + `kanban_task`) generalized to all 5 event families.
2. **Frontend — single `createUnifiedSseConnection` factory** in `api/index.ts` that takes a per-channel-callback object, builds `?channels=` from the keys the caller wired up, registers every named event type with the SseClient (`kanban_column`, `kanban_task`, `queue_message`), and dispatches incoming `onEvent` payloads to the right callback by `eventType` (or by JSON-shape discrimination for the unnamed default `message` events).
3. **Cleanup** — delete the 5 old handler files (`worker_sse.zig`, `sessions_sse.zig`, `llm_history_sse.zig`, `queue_messages_sse.zig`, `kanban_events_sse.zig`), their re-exports in `http_handlers/mod.zig`, the 5 `gs.router.sse(...)` calls in `main.zig`, the 5 old `create*SseConnection` factories, the `sse_handshake_test.zig` "4 handler" array, and `kanban_events_sse_test.zig`.

**Tech Stack:** Zig 0.16, `gs.router.sse(...)`, `event_bus.subscribe(...)`, `event_bus.emit(...)`, `registerSessionClient`/`getListClientsForSession` (`src/root.zig:171,252`), Vue 3 + Pinia, TypeScript strict, `helpers/sseClient.ts` (`createSseClient` with `additionalEventTypes`), Vitest + jsdom.

**Spec / context:**
- Kanban task: `unify-sse-endpoints` (workspace `ws_1779002584293_e52cd134532e1f00`, kanban board item `item_1782442554104741821`).
- Precedent: `kanban_events_sse.zig:95-121` is the EXACT shape we are generalizing — it subscribes 2 routing keys onto 1 SSE connection via the `forwardToClients(routing_key, data)` helper (lines 34-76). The same helper can be lifted into the new unified handler.
- Today's 5 SSE routes in `main.zig`: lines 255 (`workers`), 267 (queue), 268 (llm), 269 (sessions), 271 (kanban).
- Today's 5 frontend `create*SseConnection` factories in `src/apps/desktop/src/api/index.ts`: `createSseConnection` (line 767), `createSessionsSseConnection` (line 1615), `createQueueMessagesSseConnection` (line 1693), `createWorkersSseConnection` (line 1813), `createKanbanSseConnection` (line 1920).
- Today's 5 frontend consumers: `App.vue:52` (workers), `workspaces.ts:1492` (sessions), `ChatsList.vue:269` (sessions, redundant duplicate), `kanbanSse.ts:70` (kanban), `ChatView.vue:1576` (llm), `ChatView.vue:1655` (queue_messages).
- The 5-event-type contract: `workers`/`sessions`/`llm` events have NO `event:` line (default `message`); `kanban_column`, `kanban_task`, `queue_message` have NAMED event lines (see `on_event_sent.zig:166-172` and `on_event_sent_kanban.zig:97,145`, `llm_history.zig:1868,1947`). So `additionalEventTypes` on the SseClient is `['kanban_column', 'kanban_task', 'queue_message']`.
- Memory: `browser-eventsource-named-events.md` — named events MUST be pre-registered, the SseClient auto-registers only `'connected'` and `'message'`.
- Memory: `nalar-sse-incomplete-chunked-encoding.md` — `chatView` consumers rely on `state === 'failed'` being terminal to flip `isStreaming`; preserve this contract exactly in the unified factory.

---

## Defaults locked by this plan

1. **Single backend URL: `GET /api/events?channels=…`**. Comma-separated list of channel tokens. No path params, no body. Symmetric to the existing `kanban_events_sse.zig` precedent (1 URL, 1 EventSource) and to the existing comma-separated convention (`POST /api/git/stage?files=a,b,c`).
2. **Channel tokens** (5):
   - `workers` → subscribes to event_bus key `"workers"`
   - `sessions` → subscribes to event_bus key `"sessions"`
   - `kanban` → subscribes to event_bus keys `"kanban_column"` and `"kanban_task"`
   - `llm:<session_id>` → subscribes to event_bus key `"<session_id>"` (the per-session LLM key, see `llm_history_sse.zig:86`)
   - `queue:<session_id>` → subscribes to event_bus key `"queue_messages_<session_id>"` (see `queue_messages_sse.zig:90`)
3. **Validation:** if `?channels=` is missing OR empty → return HTTP 400 with `{"error":"missing channels"}`. Unknown channel prefix (not one of `workers`/`sessions`/`kanban`/`llm`/`queue`) → 400. Session-scoped channel with empty session_id (e.g. `llm:` or `queue:`) → 400. Same parser in `parseChannels(allocator, raw: []const u8) !ChannelList`.
4. **Reuse `forwardToClients` verbatim** — lift the helper from `kanban_events_sse.zig:34-76` into the new unified handler. It's already correct (subscription-lock-safe, sends to all clients of one routing key).
5. **Single `connected` handshake** — `event: connected\ndata: {"connected": true}\n\n` (the verbatim byte sequence pinned by `sse_handshake_test.zig:61-64`). Sent ONCE after all routing keys are registered, before `return error.WouldBlock`.
6. **Frontend keeps 2 SSE connections** (not 1). Rationale: App.vue opens 1 global SSE (workers + sessions + kanban — 3 channels) at app startup; ChatView.vue opens 1 chat-scoped SSE (llm + queue for that sessionId — 2 channels) on chat-view mount. The user's request was "1 SSE endpoint" (backend), not "1 EventSource globally" — collapsing to 1 globally would require swapping the channel set on every chat-view mount/unmount, which costs ~1 reconnect per navigation and complicates `isStreaming` state. 2 connections per app is the minimum that satisfies "1 endpoint" without lifecycle coupling.
7. **The 5 old SSE routes + handlers + frontend factories stay live until Chunk 9 (cleanup).** Each chunk is additive (a new endpoint, then a new factory) so the regression risk is contained — old code paths keep working the whole time, and the new ones are exercised in isolation.
8. **Out of scope:** the deferred-send fix from `docs/superpowers/plans/2026-06-30-fix-sse-blocking-api.md` is a separate task (same task family, but lands in its own PR). The new unified handler uses the SAME `sendToClient`/`registerSessionClient` pattern as today's handlers — no new synchronization primitives are introduced here.

---

## File Structure

### New files (2)

- `src/ai_workflow/tui/http_handlers/unified_events_sse.zig` — the single new backend handler. Parses `?channels=`, registers under each routing key, subscribes a callback per routing key, sends the `connected` handshake, returns `error.WouldBlock`. Re-exports `forwardToClients` (lifted from kanban_events_sse.zig).
- `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig` — static regression checks: the handler exists and defines `pub fn unifiedEventsStreamHandler`, the handler parses all 5 channel tokens, the handler subscribes to all 5 event_bus key shapes, `/api/events` is registered in `main.zig`.

### Modified files (10)

- `src/main.zig` — add `gs.router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler)` next to the existing 5 routes (Phase 1). In Chunk 9, remove the 5 old routes.
- `src/ai_workflow/tui/http_handlers/mod.zig` — add `pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;` (Phase 1). In Chunk 9, remove the 5 old re-exports.
- `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` — in Phase 1, add `unified_events_sse.zig` to the handlers array (5 entries). In Chunk 9, replace with the single new file.
- `src/apps/desktop/src/api/index.ts` — add `createUnifiedSseConnection` factory (Phase 2, Chunk 4). In Chunk 9, remove the 5 old factories.
- `src/apps/desktop/src/App.vue` — replace `createWorkersSseConnection` with the unified factory (Chunk 5).
- `src/apps/desktop/src/stores/workspaces.ts` — replace `createSessionsSseConnection` with the unified factory (Chunk 6).
- `src/apps/desktop/src/stores/kanbanSse.ts` — replace `createKanbanSseConnection` with the unified factory (Chunk 7).
- `src/apps/desktop/src/components/ChatView.vue` — replace BOTH `createSseConnection` and `createQueueMessagesSseConnection` with one unified call (Chunk 8).
- `src/apps/desktop/src/components/ChatsList.vue` — delete the redundant `connectSessionsSse`/`disconnectSessionsSse` block (sessions SSE now lives in `workspacesStore.subscribeToSessionEvents()` which was already there). Remove the `sessionsSse` ref.
- `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` — update the `createSessionsSseConnection` spy to the unified factory spy.
- `src/apps/desktop/src/__tests__/chatsListGitWorktree.spec.ts` — remove the 4 `createSessionsSseConnection` spies (ChatsList no longer subscribes to sessions events).
- `src/apps/desktop/src/__tests__/kanbanSse.spec.ts` — update the `createKanbanSseConnection` spy to the unified factory spy.
- `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts` — replace the `createSseConnection` + `createQueueMessagesSseConnection` spies with a single `createUnifiedSseConnection` spy.

### Deleted files (7, in Chunk 9 only)

- `src/ai_workflow/tui/http_handlers/worker_sse.zig`
- `src/ai_workflow/tui/http_handlers/sessions_sse.zig`
- `src/ai_workflow/tui/http_handlers/llm_history_sse.zig`
- `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig`
- `src/ai_workflow/tui/http_handlers/kanban_events_sse.zig`
- `src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig`

(`sse_handshake_test.zig` is MODIFIED, not deleted — it shrinks from 4 entries to 1.)

---

## Context

### Why 5 SSE endpoints today

The codebase grew the SSE surface one event family at a time (commits `1aef3b2f`, `67e33b81`, `f881aaa9`, `20a42abf`, `889c2d92`, etc.) and each was added as its own `gs.router.sse(...)` call. There's no shared "stream coordinator" — each handler independently:
- calls `registerSessionClient(routing_key, client_id_copy, true)`,
- sends the 3-line `connected` handshake,
- subscribes ONE callback to ONE routing key,
- returns `error.WouldBlock`.

That works but produces 5 `EventSource` connections in the browser (App.vue, workspaces store, ChatsList.vue, kanbanSse store, ChatView.vue x2 — but `ChatsList` and `workspaces` are redundant for sessions events). Each connection:
- saturates 1 slot in the browser's HTTP/1.1 per-origin pool (max 6),
- triggers its own `SseClient` reconnect cycle with its own jitter/backoff,
- requires the frontend to mock 5 different factories in tests.

### The fan-out precedent that makes this safe

`kanban_events_sse.zig:34-76` already solves the "1 client subscribes to N routing keys" problem with a clean `forwardToClients(routing_key, data)` helper. The same pattern scales to N=5 channels with zero changes to `event_bus`, `SseManager`, or `registerSessionClient`. The only new code is the channel parser and the per-channel `subscribe` loop.

### Why not "1 SSE globally"

Collapsing to 1 `EventSource` per browser tab would require the chat view to:
1. Subscribe to `llm:<sid>` + `queue:<sid>` on mount,
2. Unsubscribe (or close+reopen) on unmount.

The browser's `EventSource` API has NO in-band subscribe/unsubscribe — only the initial URL. So unmount→swap means `close() + createSseClient(new_url) + dropStreamedSinceHandshake`. That costs one full reconnect cycle per chat switch (~1-5 s of `SseStatusBadge` "Reconnecting…"). The simpler design — 1 global stream for workers/sessions/kanban + 1 chat stream for llm/queue — keeps the chat view's lifetime cleanly bounded to the chat mount, at the cost of 1 extra connection.

---

## Chunk 1: Backend — New unified SSE handler (additive)

### Task 1.1: Create the handler file skeleton

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/unified_events_sse.zig`

- [ ] **Step 1: Create the file with the lifted `forwardToClients` helper**

The new file begins as a near-copy of `kanban_events_sse.zig`'s `forwardToClients` (lines 34-76), then grows the channel parser + subscribe loop. Write the file with:

```zig
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
//!   /api/events?channels=llm:<sid>,queue:<sid>
//!   /api/events?channels=workers,sessions,kanban,llm:<sid>,queue:<sid>
//!
//! Channel tokens and the event_bus routing keys they fan out to:
//!   workers  → "workers"
//!   sessions → "sessions"
//!   kanban   → "kanban_column", "kanban_task"
//!   llm:<sid>      → "<sid>"
//!   queue:<sid>    → "queue_messages_<sid>"
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

// ChannelList — the parsed result of `?channels=`.
const ChannelList = struct {
    /// Each entry is a routing key the handler must subscribe a
    /// callback to. Duplicates are not deduplicated (the SSE
    /// event_bus handles duplicate subscribers without error).
    routing_keys: []const []const u8,

    pub fn deinit(self: ChannelList, allocator: std.mem.Allocator) void {
        for (self.routing_keys) |k| allocator.free(k);
        allocator.free(self.routing_keys);
    }
};

// Parse `?channels=workers,sessions,kanban,llm:<sid>,queue:<sid>`.
// Returns the list of routing keys to subscribe + register. Returns
// ChannelParseError on missing/empty/unknown channel tokens.
const ChannelParseError = error{ MissingChannels, UnknownChannel, EmptySessionId, OutOfMemory };

fn parseChannels(allocator: std.mem.Allocator, raw: []const u8) ChannelParseError!ChannelList {
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
        if (token.len == 0) continue;

        if (std.mem.eql(u8, token, "workers")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "workers"));
        } else if (std.mem.eql(u8, token, "sessions")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "sessions"));
        } else if (std.mem.eql(u8, token, "kanban")) {
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_column"));
            try routing_keys.append(allocator, try allocator.dupe(u8, "kanban_task"));
        } else if (std.mem.startsWith(u8, token, "llm:")) {
            const sid = token["llm:".len..];
            if (sid.len == 0) return error.EmptySessionId;
            try routing_keys.append(allocator, try allocator.dupe(u8, sid));
        } else if (std.mem.startsWith(u8, token, "queue:")) {
            const sid = token["queue:".len..];
            if (sid.len == 0) return error.EmptySessionId;
            const composed = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{sid});
            try routing_keys.append(allocator, composed);
        } else {
            return error.UnknownChannel;
        }
    }

    if (routing_keys.items.len == 0) return error.MissingChannels;

    return ChannelList{ .routing_keys = try routing_keys.toOwnedSlice(allocator) };
}

/// SSE stream endpoint — single endpoint for all server-pushed events.
///
/// The `?channels=` query parameter is REQUIRED. Returns HTTP 400
/// (via the early `res.jsonResponse`) if missing/empty/unknown.
pub fn unifiedEventsStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = ctx; // client_id is consumed below once we register
    const allocator = ctx.allocator;

    // 1. Parse ?channels=
    const raw_channels = req.query().get("channels") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                "{{\"error\":\"missing channels query parameter\"}}", .{}),
        });
    };
    var channels = parseChannels(allocator, raw_channels) catch |err| switch (err) {
        error.MissingChannels => return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                "{{\"error\":\"missing or empty channels query parameter\"}}", .{}),
        }),
        error.UnknownChannel => return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                "{{\"error\":\"unknown channel in {s}\"}}", .{raw_channels}),
        }),
        error.EmptySessionId => return res.jsonResponse(.{
            .status_code = 400,
            .data = try std.fmt.allocPrint(allocator,
                "{{\"error\":\"session-scoped channel requires non-empty session_id\"}}", .{}),
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

        // Register the client under EVERY routing key.
        for (channels.routing_keys) |rk| {
            const rk_copy = try allocator.dupe(u8, rk);
            ai_mod.registerSessionClient(rk_copy, client_id_copy, true) catch {};
        }

        // Subscribe ONE callback per routing key. The callback fans out
        // to the clients of its own key only.
        for (channels.routing_keys) |rk| {
            const rk_for_subscribe = try allocator.dupe(u8, rk);
            const Callback = struct {
                routing_key: []const u8,
                pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
                    forwardToClients(routing_key, data);
                }
            };
            // Subscribe needs the routing key to live until the SSE loop ends.
            // event_bus.subscribe dupes the key internally, so we can free ours
            // after the call returns. See worker_sse.zig:81 for the same pattern.
            const Ctx = struct {
                rk: []const u8,
                alloc: std.mem.Allocator,
            };
            const cb_ctx = Ctx{ .rk = rk_for_subscribe, .alloc = allocator };
            _ = cb_ctx; // see Chunk 1.2 for the closure-capture fix below
            event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_for_subscribe, Callback.callback) catch {};
        }

        // 3. Send the connected handshake (the verbatim byte sequence
        //    pinned by sse_handshake_test.zig:61-64).
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
    }

    return error.WouldBlock;
}
```

NOTE TO IMPLEMENTER: The above draft has a **deliberately-wrong closure capture** at the end of the subscribe loop (the `Callback` struct captures a comptime-known `routing_key` field via Zig 0.16's inline struct rules, but the `rk_for_subscribe` lives in the outer scope and may be freed). Step 1.2 fixes this.

- [ ] **Step 2: Fix the closure capture — use a heap-allocated payload + thin wrapper**

Replace the inline struct + `cb_ctx` block above with the actual proven pattern from `kanban_events_sse.zig` (lines 79-90). Define two top-level callback structs:

```zig
/// Callback for `kanban_column` routing key — fires on column create/update/delete.
/// Reuses the fan-out pattern from kanban_events_sse.zig:79-83.
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

/// Callback for the per-session LLM routing key. The session_id is
/// carried inside `SseEvent.session_id`, so the routing key is read
/// from there (mirrors llm_history_sse.zig:22).
pub const CallbackUnifiedLLMStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        forwardToClients(data.session_id, data);
    }
};

/// Callback for `queue_messages_<sid>` routing key. The session_id
/// is read from `data.session_id` and composed into the routing key,
/// mirroring queue_messages_sse.zig:19.
pub const CallbackUnifiedQueueStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const composed = std.fmt.allocPrint(allocator, "queue_messages_{s}", .{data.session_id}) catch return;
        defer allocator.free(composed);
        forwardToClients(composed, data);
    }
};
```

Then rewrite the subscribe loop in `unifiedEventsStreamHandler` to pick the right callback by inspecting the routing key (NOT by capturing it in an inline struct):

```zig
        // Subscribe ONE callback per routing key.
        for (channels.routing_keys) |rk| {
            const rk_copy = try allocator.dupe(u8, rk);
            defer allocator.free(rk_copy);

            // Pick the callback by routing-key shape. The 3 simple
            // shapes (workers/sessions/<plain>) map directly; the 2
            // composed shapes (kanban_*, queue_messages_*) need
            // explicit recognition.
            if (std.mem.eql(u8, rk_copy, "kanban_column")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_copy, CallbackUnifiedColumnStream.callback) catch {};
            } else if (std.mem.eql(u8, rk_copy, "kanban_task")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_copy, CallbackUnifiedTaskStream.callback) catch {};
            } else if (std.mem.eql(u8, rk_copy, "workers")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_copy, CallbackUnifiedWorkersStream.callback) catch {};
            } else if (std.mem.eql(u8, rk_copy, "sessions")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_copy, CallbackUnifiedSessionsStream.callback) catch {};
            } else if (std.mem.startsWith(u8, rk_copy, "queue_messages_")) {
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_copy, CallbackUnifiedQueueStream.callback) catch {};
            } else {
                // Default: treat as a per-session LLM routing key.
                event_bus.subscribe(ai_mod.on_event_sent.SseEvent, rk_copy, CallbackUnifiedLLMStream.callback) catch {};
            }
        }
```

This matches the working pattern in `kanban_events_sse.zig` and `worker_sse.zig` — callbacks are top-level structs, routing-key is read inside the body, no closure capture to worry about. The `rk_copy` lifetime is "until the next `event_bus.subscribe` returns" (event_bus.subscribe dupes the key internally per `worker_sse.zig:81`).

- [ ] **Step 3: Verify the file compiles**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
timeout 180 zig build 2>&1 | tail -n 20
```

Expected: no errors referencing `unified_events_sse.zig`. (Other pre-existing build errors are out of scope for this plan.) If the file is not yet wired into `http_handlers/mod.zig`, the new symbols are dead code — `zig build` will still parse and type-check it via `pub const`, so any structural errors surface immediately.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/ai_workflow/tui/http_handlers/unified_events_sse.zig
git commit -m "feat(sse): add unified_events_sse handler skeleton with channel parser"
```

### Task 1.2: Wire the handler into the module and route table (additive)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig:78-85`
- Modify: `src/main.zig:255-271`

- [ ] **Step 1: Add the re-export to `http_handlers/mod.zig`**

Insert after the kanban SSE line (line 85), keeping the related handlers grouped:

```zig
// Unified SSE handler — single endpoint that fans out all event families.
// Replaces the 5 dedicated routes registered in main.zig. See
// unified_events_sse.zig for the channel grammar (?channels=).
pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;
```

- [ ] **Step 2: Register the new route in `main.zig`**

Insert AFTER the existing kanban SSE line (line 271), keeping all 5 old routes live (Phase 1 = additive):

```zig
    // Unified SSE endpoint — single EventSource for all event families.
    // Replaces the 5 dedicated routes below in Chunk 9 (cleanup).
    // See src/ai_workflow/tui/http_handlers/unified_events_sse.zig.
    try gs.router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler);
```

- [ ] **Step 3: Verify build still passes**

```bash
timeout 180 zig build 2>&1 | tail -n 20
```

Expected: no new errors. The handler is now reachable via `GET /api/events?channels=…`.

- [ ] **Step 4: Smoke test the new endpoint**

```bash
# Terminal 1: start nalar on 8080 (per project rules — never use 8081)
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
zig build install:linux:system 2>&1 | tail -n 5
./zig-out/bin/nalar --port 8080 &
sleep 2

# Terminal 2: connect, expect `event: connected`
curl -N "http://127.0.0.1:8080/api/events?channels=workers" 2>&1 | head -n 5

# Should print:
#   event: connected
#   data: {"connected": true}
#   (then `data: ping` heartbeats every ~15 s)

# Missing channels → 400
curl -i "http://127.0.0.1:8080/api/events" 2>&1 | head -n 3
# Should print: HTTP/1.1 400 Bad Request

# Unknown channel → 400
curl -i "http://127.0.0.1:8080/api/events?channels=foo" 2>&1 | head -n 3
# Should print: HTTP/1.1 400 Bad Request

# Kill nalar (port 8080 only — DO NOT touch port 8081)
kill $(pgrep -f "nalar --port 8080")
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/mod.zig src/main.zig
git commit -m "feat(sse): register /api/events unified route (additive)"
```

---

## Chunk 2: Backend — Regression tests for the new handler

### Task 2.1: Add the unified handler to the SSE handshake test

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig:85-90`

- [ ] **Step 1: Add the new handler to the array**

Change the `handlers` tuple from 4 entries to 5:

```zig
    const handlers = .{
        "src/ai_workflow/tui/http_handlers/worker_sse.zig",
        "src/ai_workflow/tui/http_handlers/sessions_sse.zig",
        "src/ai_workflow/tui/http_handlers/llm_history_sse.zig",
        "src/ai_workflow/tui/http_handlers/queue_messages_sse.zig",
        "src/ai_workflow/tui/http_handlers/unified_events_sse.zig",
    };
```

(The test name `"SSE handshake: all 4 registered stream handlers send the connected event"` is updated in Step 2.)

- [ ] **Step 2: Update the test name and add a comment**

Change the test name and the inline doc:

```zig
test "SSE handshake: all 5 stream handlers send the connected event" {
    // The 5 SSE routes registered in src/main.zig (4 legacy + 1 unified).
    // Each MUST contain the `connected` handshake string in its source, or
    // the frontend SseStatusBadge will be stuck on "Connecting…".
```

- [ ] **Step 3: Run the test**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: `test success` and the test count +1 vs the baseline (was testing 4 paths, now tests 5 — but it's the same `test` block, so the +1 is from Chunk 2.2 below).

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/sse_handshake_test.zig
git commit -m "test(sse): add unified handler to handshake regression test"
```

### Task 2.2: Create the unified handler static regression tests

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (or equivalent — see Step 0)

- [ ] **Step 0: Confirm how new tests are registered in this project**

```bash
grep -n "_ = @import" src/ai_workflow/tui/test_runner.zig | tail -n 30
```

(The convention from memory `verification-before-completion`: every new `_test.zig` file MUST be added to `test_runner.zig` via `_ = @import("path/to/test.zig");`, otherwise the test is compiled but never executed.)

- [ ] **Step 1: Create the test file with 4 contracts**

```zig
//! Static regression checks for the `/api/events` unified SSE handler.
//!
//! Why this file exists
//! ────────────────────
//! The unified handler is the single entry point for ALL server-pushed
//! events. Any regression in the channel parser or the routing-key
//! subscriptions silently drops events for the entire frontend, so
//! these contracts are pinned via static source checks (the same
//! pattern as `kanban_events_sse_test.zig`).
//!
//! Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/unified_events_sse.zig";
const MAIN_PATH = "src/main.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

// ─── Contract 1: handler exists and defines the public fn ─────────────────

test "unified_events_sse.zig exists and defines pub fn unifiedEventsStreamHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn unifiedEventsStreamHandler") == null) {
        std.debug.print(
            "\n!! {s} does not define pub fn unifiedEventsStreamHandler !!\n", .{HANDLER_PATH},
        );
        return error.HandlerFunctionMissing;
    }
}

// ─── Contract 2: all 5 channel tokens are recognized ─────────────────────

test "unified_events_sse.zig recognizes all 5 channel tokens" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    const required_tokens = .{
        // workers branch
        "\"workers\"",
        // sessions branch
        "\"sessions\"",
        // kanban branch (subscribes BOTH kanban_column + kanban_task)
        "\"kanban\"",
        "\"kanban_column\"",
        "\"kanban_task\"",
        // llm: branch
        "\"llm:\"",
        // queue: branch
        "\"queue:\"",
        // queue_messages_<sid> composed routing key
        "queue_messages_",
    };

    inline for (required_tokens) |needle| {
        if (std.mem.indexOf(u8, source, needle) == null) {
            std.debug.print(
                "\n!! {s} is missing the substring {s} !!\n", .{ HANDLER_PATH, needle },
            );
            return error.ChannelTokenMissing;
        }
    }
}

// ─── Contract 3: handler sends the `connected` handshake ─────────────────

test "unified_events_sse.zig sends the connected handshake" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The verbatim byte sequence pinned by sse_handshake_test.zig:61-64.
    const handshake = "event: connected\\ndata: {\\\"connected\\\": true}\\n\\n";
    if (std.mem.indexOf(u8, source, handshake) == null) {
        std.debug.print(
            "\n!! {s} does not contain the SSE connected handshake !!\n", .{HANDLER_PATH},
        );
        return error.ConnectedHandshakeMissing;
    }
}

// ─── Contract 4: route is registered in main.zig ─────────────────────────

test "/api/events is registered in src/main.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "/api/events") == null) {
        std.debug.print(
            "\n!! {s} does not register the /api/events route !!\n", .{MAIN_PATH},
        );
        return error.RouteRegistrationMissing;
    }
}
```

- [ ] **Step 2: Register the test file in test_runner.zig**

```bash
# Find the existing import block for http_handlers tests
grep -n "http_handlers/" src/ai_workflow/tui/test_runner.zig | head -n 5
```

Add the import line (the exact pattern is project-specific — match the existing convention in the file):

```zig
    _ = @import("http_handlers/unified_events_sse_test.zig");
```

- [ ] **Step 3: Run the tests**

```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: 4 new tests passing (the 4 contracts above). Total count grows by 4.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig src/ai_workflow/tui/test_runner.zig
git commit -m "test(sse): add static regression tests for /api/events handler"
```

---

## Chunk 3: Frontend — Add `createUnifiedSseConnection` factory

### Task 3.1: Create the unified factory in api/index.ts (additive)

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts` (append after the existing 5 factories, ~line 1955)

- [ ] **Step 1: Add the TS types for the channel callbacks**

Insert above the `createUnifiedSseConnection` factory function:

```ts
/**
 * Unified SSE channel options.
 *
 * Each property is a per-channel callback. Only the keys present in
 * `channels` are subscribed on the backend (passed as the
 * `?channels=` query param). The factory always registers all
 * known named event types (`kanban_column`, `kanban_task`,
 * `queue_message`) with the SseClient so the browser dispatches
 * them; the actual dispatch to a consumer's callback is filtered
 * by `eventType` + a payload-shape check inside the factory.
 */
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  llm?: { sessionId: string; onEvent: (event: SseEvent) => void }
  queue?: { sessionId: string; onEvent: (event: QueueMessageEvent) => void }
}

export interface UnifiedSseOptions {
  channels: UnifiedChannels
  onError?: (error: Event) => void
  onConnected?: () => void
}
```

- [ ] **Step 2: Add the factory**

```ts
/**
 * Open ONE EventSource that fans out every event family the caller
 * wired up. Replaces the 5 dedicated `create*SseConnection` factories
 * (workers / sessions / kanban / queue / llm) — they all route to
 * `/api/events?channels=…` under the hood.
 *
 * **Why "1 SSE endpoint" doesn't mean "1 EventSource globally":**
 * Chat-scoped channels (`llm:<sid>`, `queue:<sid>`) are inherently
 * bounded by the chat's lifetime. Opening the connection with the
 * global channels (`workers`, `sessions`, `kanban`) and swapping
 * `?channels=` on every chat-view mount would cost 1 reconnect per
 * navigation. Instead, we use 2 EventSources per app:
 *   - 1 in App.vue (the global SSE; `workers+sessions+kanban`)
 *   - 1 in ChatView.vue (the chat SSE; `llm:<sid>+queue:<sid>`)
 *
 * The backend's `/api/events` endpoint is identical for both — it's
 * the SINGLE SSE endpoint in main.zig that the user requested.
 *
 * Plan: docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md
 */
export function createUnifiedSseConnection(
  opts: UnifiedSseOptions,
): SseClient {
  // 1. Build the ?channels= comma-separated list.
  const tokens: string[] = []
  if (opts.channels.workers) tokens.push('workers')
  if (opts.channels.sessions) tokens.push('sessions')
  if (opts.channels.kanban) tokens.push('kanban')
  if (opts.channels.llm) tokens.push(`llm:${opts.channels.llm.sessionId}`)
  if (opts.channels.queue) tokens.push(`queue:${opts.channels.queue.sessionId}`)

  // Empty subscriptions are meaningless; the backend would 400 anyway.
  // Throw early with a developer-friendly message.
  if (tokens.length === 0) {
    throw new Error('createUnifiedSseConnection: opts.channels is empty')
  }

  // Per-channel JSON buffers for the 3 unnamed default `message` events
  // (workers, sessions, llm). The 'kanban_column', 'kanban_task', and
  // 'queue_message' named events carry complete single-line JSON in
  // one `data:` frame, so they don't need a buffer. The 'connected'
  // event is auto-parsed by the SseClient.
  const workerBuf = { value: '' }
  const sessionBuf = { value: '' }
  const llmBuf = { value: '' }

  return createSseClient({
    url: `${API_BASE}/events?channels=${tokens.join(',')}`,
    onConnected: opts.onConnected,
    // The 3 named event types must be pre-registered — the browser's
    // EventSource only dispatches each `event: <name>` to listeners
    // registered for that exact name. See the SseClient JSDoc + the
    // project memory browser-eventsource-named-events.md.
    additionalEventTypes: ['kanban_column', 'kanban_task', 'queue_message'],
    // Default heartbeat filter (matches backend sse_manager.sendHeartbeat).
    heartbeatData: 'ping',
    onEvent: (raw: string, eventType: string) => {
      if (eventType === 'connected') {
        // Reset all buffers on (re)connect — leftover bytes from the
        // previous connection would corrupt the next parse.
        workerBuf.value = ''
        sessionBuf.value = ''
        llmBuf.value = ''
        return
      }

      // Named events: dispatch by eventType.
      if (eventType === 'kanban_column' || eventType === 'kanban_task') {
        if (!opts.channels.kanban) return
        try {
          const data = JSON.parse(raw)
          opts.channels.kanban(data as KanbanColumnEvent | KanbanTaskEvent)
        } catch (err) {
          console.error('[unifiedSSE] kanban event parse failed:', err, raw)
        }
        return
      }

      if (eventType === 'queue_message') {
        if (!opts.channels.queue) return
        try {
          const data = JSON.parse(raw)
          opts.channels.queue.onEvent(data as QueueMessageEvent)
        } catch (err) {
          console.error('[unifiedSSE] queue event parse failed:', err, raw)
        }
        return
      }

      // Default `message` events: 3 distinct JSON shapes, differentiated
      // by which consumer registered the channel. The backend sends
      // these as multi-line JSON strings (one `data:` line per JSON
      // object's newline-delimited line), so we accumulate + parse.
      //
      // Shape discrimination: `action` is present in worker and session
      // events but NOT in LLM chunk/full events (LLM uses `type`).
      // - `{action, id, working_directory, ...}`    → WorkerEvent
      // - `{action, id, name, status, cwd, ...}`   → SessionEvent
      // - `{type, content, session_id, ...}`      → SseEvent (LLM)
      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        // 3 candidate buffers, dispatched after JSON.parse by shape.
        // We try each in turn — the parse failures stay scoped to the
        // accumulator and never throw.
        for (const consumer of [
          opts.channels.workers ? { buf: workerBuf, kind: 'worker' as const } : null,
          opts.channels.sessions ? { buf: sessionBuf, kind: 'session' as const } : null,
          opts.channels.llm ? { buf: llmBuf, kind: 'llm' as const } : null,
        ]) {
          if (!consumer) continue
          consumer.buf.value += trimmed + '\n'
          const jsonStart = consumer.buf.value.indexOf('{')
          const jsonEnd = consumer.buf.value.lastIndexOf('}')
          if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) continue
          const jsonStr = consumer.buf.value.slice(jsonStart, jsonEnd + 1)
          let parsed: unknown
          try {
            parsed = JSON.parse(jsonStr)
          } catch {
            continue
          }
          // Shape check: only dispatch if the parsed JSON matches this
          // consumer's discriminator. Otherwise leave the bytes in the
          // buffer for the next consumer to try.
          const obj = parsed as Record<string, unknown>
          if (consumer.kind === 'worker' && obj.action && obj.working_directory !== undefined) {
            opts.channels.workers!(obj as unknown as WorkerEvent)
            consumer.buf.value = consumer.buf.value.slice(jsonEnd + 1)
            return
          }
          if (consumer.kind === 'session' && obj.action && obj.cwd !== undefined && obj.status !== undefined) {
            opts.channels.sessions!(obj as unknown as SessionEvent)
            consumer.buf.value = consumer.buf.value.slice(jsonEnd + 1)
            return
          }
          if (consumer.kind === 'llm' && (obj.type === 'chunk' || obj.type === 'full')) {
            opts.channels.llm!.onEvent(obj as unknown as SseEvent)
            consumer.buf.value = consumer.buf.value.slice(jsonEnd + 1)
            return
          }
        }
        // None of the consumers matched — drop the line (no warning to
        // avoid log spam from the periodic `data: ping` heartbeat that
        // the SseClient already filters).
      } catch (e) {
        console.error('[unifiedSSE] default message dispatch error:', e)
      }
    },
    onStateChange: (state, info) => {
      // Match the convention of the 5 old factories: terminal-failure
      // only. Transient errors are retried internally by the SseClient.
      // See memory nalar-sse-incomplete-chunked-encoding.md for why
      // ChatView's isStreaming flag flips ONLY on 'failed'.
      if (state === 'failed') {
        opts.onError?.(info.lastError ?? new Event('error'))
      }
    },
  })
}
```

- [ ] **Step 2: Verify the TS type-checks**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
```

Expected: clean. The new factory is unused yet but type-checks cleanly.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(sse): add createUnifiedSseConnection factory"
```

---

## Chunk 4: Frontend — Migrate App.vue (workers channel → global unified SSE)

### Task 4.1: Replace createWorkersSseConnection with createUnifiedSseConnection

**Files:**
- Modify: `src/apps/desktop/src/App.vue:46-95`

- [ ] **Step 1: Update the import**

`App.vue` does not currently import `createWorkersSseConnection` by name (the test mocks it via `vi.spyOn(api, 'createWorkersSseConnection')`). Verify the current import line:

```bash
grep -n "createWorkersSseConnection\|workersSse" src/apps/desktop/src/App.vue | head -n 5
```

Replace the import with the unified factory (the type `SseClient` stays — `createUnifiedSseConnection` returns the same `SseClient` type):

```ts
// from
import { /* ... */, createWorkersSseConnection /* ... */ } from './api'
// to
import { /* ... */, createUnifiedSseConnection /* ... */ } from './api'
```

- [ ] **Step 2: Replace `initWorkersSse` with `initGlobalSse`**

Replace the body of `initWorkersSse` (lines 46-71) with:

```ts
// Initialize the GLOBAL SSE connection (workers + sessions + kanban
// channels). Replaces the per-channel `createWorkersSseConnection` etc.
// factories — all 3 channels now share ONE EventSource at /api/events.
const initGlobalSse = () => {
  // Clean up existing connection
  if (globalSse) {
    globalSse.close()
  }

  globalSse = api.createUnifiedSseConnection({
    channels: {
      workers: handleWorkerEvent,
      // sessions + kanban are added in Chunks 5 + 6; for now this
      // factory only registers `workers` to keep the migration incremental.
    },
    // onError is only invoked on TERMINAL failure (state went
    // to `failed`). Transient errors are retried internally and
    // do not fire this callback.
    (error) => {
      console.error('[App] Global SSE failed permanently:', error)
    },
    () => {
      console.log('[App] Global SSE connected')
      // Initial fetch to sync state. This re-runs on every
      // successful reconnect, which is what we want — a
      // server restart that loses in-memory state should be
      // re-synced on the next open.
      fetchInitialWorkers()
    },
  })
}
```

- [ ] **Step 3: Rename the ref**

Change `workersSse` to `globalSse` everywhere it appears in `App.vue` (lines 48-49, 52, 62, 98-104). Use `text_replace` for each occurrence to keep the diff surgical.

- [ ] **Step 4: Verify build + run tests**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: 1 test file fails (the `chatViewWorktree.spec.ts` mock is now stale). All other tests pass. Fix the chatViewWorktree mock in Chunk 7 (ChatView migration) — for now, this is acceptable because the App.vue test mocks at the `api.createWorkersSseConnection` boundary and will be updated when we delete the old factory in Chunk 9.

If the App.vue test file mocks `createWorkersSseConnection` directly (not just `api.*`), update the spy to `createUnifiedSseConnection` and adjust the call assertion to match the new `{channels: {workers: ...}}` shape.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/App.vue
git commit -m "refactor(desktop): migrate App.vue workers SSE to unified factory"
```

---

## Chunk 5: Frontend — Migrate `workspaces.ts` (sessions channel) and remove redundant ChatsList subscription

### Task 5.1: Update workspacesStore.subscribeToSessionEvents

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts:1484-1547`

- [ ] **Step 1: Replace `createSessionsSseConnection` with `createUnifiedSseConnection`**

The `sessionsSse` ref is already initialized to `null` (line 1484). Replace lines 1492-1546 (the `createSessionsSseConnection(...)` call) with:

```ts
    sessionsSse.value = api.createUnifiedSseConnection({
      channels: {
        sessions: (event) => {
          if (event.action === 'updated') {
            // (unchanged from current code)
            for (const ws of workspaces.value) {
              for (const item of ws.items) {
                if (!item.tasks) continue
                const task = item.tasks.find((t) => t.id === event.id)
                if (task) {
                  task.name = event.name || task.name
                  if (activeTaskId.value === task.id) {
                    useNavigationStore().setActiveChatName(task.name)
                  }
                  return
                }
              }
            }
          } else if (event.action === 'deleted') {
            // (unchanged from current code)
            for (const ws of workspaces.value) {
              for (const item of ws.items) {
                if (!item.tasks) continue
                const idx = item.tasks.findIndex((t) => t.id === event.id)
                if (idx !== -1) {
                  item.tasks.splice(idx, 1)
                  if (activeTaskId.value === event.id) {
                    activeTaskId.value = null
                  }
                  return
                }
              }
            }
          }
        },
      },
      (error) => {
        console.error('[workspacesStore] Sessions SSE failed permanently:', error)
      },
      () => {
        console.log('[workspacesStore] Sessions SSE connected')
      },
    })
```

The inner `(event) => { ... }` body is the SAME as the existing `createSessionsSseConnection`'s onEvent — copy verbatim.

- [ ] **Step 2: Verify build + run the workspaces test**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run workspacesStoreSessionEvents.spec 2>&1 | tail -n 20
```

Expected: `workspacesStoreSessionEvents.spec.ts` fails because it spies on `createSessionsSseConnection` (which still exists at this point — Chunk 9 deletes it). Fix the spy in Task 5.2 below.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "refactor(desktop): migrate workspaces sessions SSE to unified factory"
```

### Task 5.2: Update the workspacesStoreSessionEvents test

**Files:**
- Modify: `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts:43`

- [ ] **Step 1: Update the spy**

Change the spy from `createSessionsSseConnection` to `createUnifiedSseConnection`. The factory signature changed from `(onEvent, onError, onConnected)` to `({channels: {...}, onError, onConnected})`. Update the mock accordingly:

```ts
// before
vi.spyOn(api, 'createSessionsSseConnection').mockImplementation(
  (onEvent, onError, onConnected) => {
    /* ... */
  },
)

// after
vi.spyOn(api, 'createUnifiedSseConnection').mockImplementation(
  (opts: api.UnifiedSseOptions) => {
    capturedOpts = opts  // capture for test assertions
    return { close: vi.fn(), reconnect: vi.fn(), getState: () => 'open', onStateChange: () => () => {} } as any
  },
)
```

The test assertions that checked `expect(api.createSessionsSseConnection).toHaveBeenCalledTimes(1)` need to become `expect(api.createUnifiedSseConnection).toHaveBeenCalledTimes(1)`. To dispatch a fake event in the test, call `capturedOpts.channels.sessions!(fakeEvent)` instead of the old captured `onEvent(fakeEvent)`.

- [ ] **Step 2: Run the test**

```bash
cd src/apps/desktop
timeout 180 bunx vitest run workspacesStoreSessionEvents.spec 2>&1 | tail -n 20
```

Expected: passes. Repeat for any other test that references `createSessionsSseConnection`.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts
git commit -m "test(desktop): spy on createUnifiedSseConnection in workspaces test"
```

### Task 5.3: Remove the redundant ChatsList.vue sessions subscription

**Files:**
- Modify: `src/apps/desktop/src/components/ChatsList.vue:262-293, 354-360`

- [ ] **Step 1: Verify the redundancy**

```bash
grep -n "sessionsSse\|connectSessionsSse\|disconnectSessionsSse\|createSessionsSseConnection" src/apps/desktop/src/components/ChatsList.vue | head -n 20
```

`workspacesStore.subscribeToSessionEvents()` is already wired to fire on app startup (it gets called from `workspacesStore` initialization in `main.ts` / App.vue / wherever the store is first used). The ChatsList subscription is REDUNDANT — it consumes the same `SessionEvent` events but duplicates the SSE connection.

- [ ] **Step 2: Delete the redundant code**

Delete:
- The `connectSessionsSse` function (lines ~264-286)
- The `disconnectSessionsSse` function (lines ~288-293)
- The `sessionsSse` ref declaration (line ~266)
- The `onMounted(async () => { ... loadChats(); ... connectSessionsSse(); ... })` call to `connectSessionsSse` (line ~360)
- The `onUnmounted(() => { ... disconnectSessionsSse(); ... })` call to `disconnectSessionsSse`

Keep the `loadChats()` initial fetch — it's the REST baseline that runs even before the SSE is connected.

- [ ] **Step 3: Update the ChatsList tests**

`src/apps/desktop/src/__tests__/chatsListGitWorktree.spec.ts` has 4 `vi.spyOn(api, 'createSessionsSseConnection')` calls (lines 89, 129, 164, 197). Delete all 4 — ChatsList no longer subscribes to session events.

- [ ] **Step 4: Run the ChatsList tests**

```bash
cd src/apps/desktop
timeout 180 bunx vitest run chatsListGitWorktree.spec 2>&1 | tail -n 20
```

Expected: passes (the deleted spies were no-ops for behavior, just call counters).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/components/ChatsList.vue src/apps/desktop/src/__tests__/chatsListGitWorktree.spec.ts
git commit -m "refactor(desktop): remove redundant ChatsList sessions SSE subscription"
```

---

## Chunk 6: Frontend — Migrate `kanbanSse.ts` (kanban channel)

### Task 6.1: Replace createKanbanSseConnection with createUnifiedSseConnection

**Files:**
- Modify: `src/apps/desktop/src/stores/kanbanSse.ts:69-122`

- [ ] **Step 1: Update the import**

```ts
// from
import { createKanbanSseConnection } from '../api'
// to
import { createUnifiedSseConnection } from '../api'
```

- [ ] **Step 2: Replace the connection setup**

Replace the `connection = { sse: createKanbanSseConnection(...) }` block (lines 69-122) with:

```ts
    connection = {
      sse: createUnifiedSseConnection({
        channels: {
          kanban: (event) => {
            // Drop events for other workspaces — the backend fans out
            // kanban events globally, so any connected client receives
            // them all. Skipping the no-op fetch keeps the local store's
            // re-fetch rate at 1 per actual mutation.
            if (event.workspace_id !== workspaceId) return
            const ws = useWorkspacesStore()
            if ('column_id' in event) {
              void ws.fetchKanbanColumns(event.workspace_id, event.item_id)
            } else if ('task_id' in event) {
              void ws.fetchKanbanTasks(event.workspace_id, event.item_id)
            }
          },
        },
        (error) => {
          console.error('[kanbanSse] connection failed permanently:', error)
        },
        () => {
          console.log('[kanbanSse] connected')
          // Re-fetch on every (re)connect. A server restart that
          // lost in-memory state should be re-synced on the next open.
          void useWorkspacesStore().fetchKanban(workspaceId)
        },
      }),
      workspaceId,
    }
```

The kanban event body is unchanged — same `'column_id' in event` / `'task_id' in event` discriminator.

- [ ] **Step 3: Update the kanbanSse tests**

`src/apps/desktop/src/__tests__/kanbanSse.spec.ts` mocks `createKanbanSseConnection` (lines 7, 17, 54, 56, 77, 86, 239). Update the spy to `createUnifiedSseConnection` and adjust the mock factory to match the new `{channels, onError, onConnected}` signature. The test should capture the `channels.kanban` callback from `opts.channels` and call it directly to simulate a backend event.

- [ ] **Step 4: Run the tests**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run kanbanSse.spec 2>&1 | tail -n 20
```

Expected: build clean, kanbanSse.spec.ts passes.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/stores/kanbanSse.ts src/apps/desktop/src/__tests__/kanbanSse.spec.ts
git commit -m "refactor(desktop): migrate kanbanSse to unified factory"
```

### Task 6.2: Add the kanban channel to App.vue's global SSE

**Files:**
- Modify: `src/apps/desktop/src/App.vue` (the `initGlobalSse` function from Chunk 4)

- [ ] **Step 1: Extend the channels**

Replace the App.vue `initGlobalSse` body to register ALL 3 global channels. This requires importing the kanban store and re-fetching on connect:

```ts
import { useKanbanSseStore } from './stores/kanbanSse'

// inside initGlobalSse:
globalSse = api.createUnifiedSseConnection({
  channels: {
    workers: handleWorkerEvent,
    // Sessions are owned by workspacesStore.subscribeToSessionEvents()
    // (called from store init), which uses its own dedicated SSE.
    // We do NOT add `sessions` here to avoid the 2-EventSource-for-
    // one-channel-set duplication. Sessions stays on its own
    // connection until Chunk 9 (cleanup) when we drop the legacy
    // `createSessionsSseConnection` factory.
    // kanban: delegated to the kanbanSse store (line below) — same
    // single-EventSource-per-app invariant.
  },
  // ...
})
```

DECISION POINT: Because the kanban and sessions SSEs already have their own store-scoped connections (`kanbanSse.ts`, `workspacesStore.subscribeToSessionEvents()`), and migrating them onto the App.vue global SSE would mean either (a) hoisting the kanban store + workspacesStore into App.vue (refactor that changes ownership), or (b) leaving them on their own connections — we go with **(b)** for now. The unified backend endpoint is the win; the frontend collapses from 5 connections to 3 (`workers`, `kanban`, `sessions`, `chat-llm`, `chat-queue` — net 5). After Chunk 9 deletes the legacy factories, the frontend will be 3 connections until Chunk 6.3 collapses `kanban` + `sessions` onto the workers stream.

- [ ] **Step 2: Commit (defer to 6.3 — see below)**

### Task 6.3: Collapse kanban + sessions onto the App.vue global SSE

**Files:**
- Modify: `src/apps/desktop/src/App.vue`
- Modify: `src/apps/desktop/src/stores/kanbanSse.ts` (remove the standalone connection)
- Modify: `src/apps/desktop/src/stores/workspaces.ts` (remove `subscribeToSessionEvents` and the `sessionsSse` ref)

- [ ] **Step 1: Move the kanban SSE into App.vue**

In `App.vue`, replace the `initGlobalSse` body with:

```ts
import { useKanbanSseStore } from './stores/kanbanSse'

globalSse = api.createUnifiedSseConnection({
  channels: {
    workers: handleWorkerEvent,
    kanban: (event) => useKanbanSseStore().handleKanbanEvent(event),
  },
  // ...
})
```

(The `kanbanSse` store now exposes a pure `handleKanbanEvent(event)` action and NO connection management. The App.vue connection lifecycle owns the SSE.)

- [ ] **Step 2: Refactor `kanbanSse.ts` to remove the connection**

Delete the `connection: KanbanConnection | null` field, the `initKanbanSse` function (replaced by `handleKanbanEvent`), and the `workspaceId` tracking. The store now just holds the action that filters + dispatches kanban events.

- [ ] **Step 3: Migrate sessions onto the App.vue global SSE**

Replace the workspaces store's `subscribeToSessionEvents` (lines 1484-1547) with a pure `handleSessionEvent(event)` action (extracted from the existing onEvent body, no SSE connection). App.vue now wires both `kanban` and `sessions` (and `workers`) into one `createUnifiedSseConnection` call.

- [ ] **Step 4: Run the full test suite + build**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: build clean, ALL frontend tests pass.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/App.vue src/apps/desktop/src/stores/kanbanSse.ts src/apps/desktop/src/stores/workspaces.ts
git commit -m "refactor(desktop): collapse workers+kanban+sessions onto 1 global SSE"
```

---

## Chunk 7: Frontend — Migrate ChatView.vue (llm + queue → 1 chat-scoped SSE)

### Task 7.1: Replace createSseConnection + createQueueMessagesSseConnection with createUnifiedSseConnection

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:1564-1689`

- [ ] **Step 1: Replace the `connectSse` body**

The current `connectSse` opens TWO EventSources: one for `createSseConnection(sessionId.value, ...)` (lines 1576-1653) and one for `createQueueMessagesSseConnection(sessionId.value, ...)` (lines 1655-1674). Replace both with ONE unified call:

```ts
const connectSse = () => {
  console.log('[connectSse] Connecting unified SSE for session:', sessionId.value)
  if (!sessionId.value) return

  if (isAlreadyConnectedSSE.value == false) disconnectSse()

  isStreaming.value = true
  streamingContent.value = ''

  chatSse.value = api.createUnifiedSseConnection({
    channels: {
      llm: {
        sessionId: sessionId.value,
        onEvent: (event: api.SseEvent) => {
          // (the body is the SAME as the existing createSseConnection
          // onEvent — copy lines 1578-1643 verbatim)
          console.log('[SSE ChatView] Received event:', event)
          if (event.type === 'connected' && event.session_id) {
            console.log('SSE connected, session:', event.session_id)
            return
          }
          if (event.type !== 'chunk' && event.type !== 'full') return
          if (event.type === 'chunk' && event.content) {
            streamingContent.value = event.content
            updateStreamingMessage()
            return
          }
          if (event.type === 'full' && event.finish_reason && event.content) {
            // (copy lines 1597-1638 verbatim)
            messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
            const role =
              (event.role as 'user' | 'assistant' | 'system' | 'tool') ||
              (event.tool_call_id ? 'tool' : 'assistant')
            messages.value.push({
              id: event.id || `assistant-${Date.now()}`,
              role: role,
              content: event.content,
              timestamp: new Date(),
              tool_name: event.tool_name,
              diffview_before: event.diffview_before,
              diffview_after: event.diffview_after,
              image_urls: event.image_url ? event.image_url.split('|') : undefined,
              finish_reason: event.finish_reason,
              tool_call_id: event.tool_call_id,
            })
            streamingContent.value = ''
            isStreaming.value = false
            scrollLogger.markProgrammatic()
            lastAutoStickAt.value = Date.now()
            nextTick(() => scrollToBottom(false, 'sse-message-complete'))
            setupCodeBlockCopyButtons()
            if (event.total_tokens) {
              maxTotalTokens.value = event.total_tokens
            }
            return
          }
          if (event.reasoning_content && !event.content) {
            console.log('Reasoning:', event.reasoning_content)
          }
        },
      },
      queue: {
        sessionId: sessionId.value,
        onEvent: (event: api.QueueMessageEvent) => {
          // (the body is the SAME as the existing
          // createQueueMessagesSseConnection onEvent — copy lines 1657-1666 verbatim)
          console.log('[QueueMessages SSE] Received event:', event)
          if (event.action === 'queued') {
            queuedMessages.value.push({
              id: event.id ?? `q-${Date.now()}`,
              message: event.message,
            })
          } else if (event.action === 'deleted') {
            queuedMessages.value = queuedMessages.value.filter((m) => m.message !== event.message)
          }
        },
      },
    },
    (err) => {
      // Terminal failure: ChatView's isStreaming flag flips ONLY here
      // (see memory nalar-sse-incomplete-chunked-encoding.md).
      console.error('SSE error:', err)
      isStreaming.value = false
      streamingContent.value = ''
    },
    () => {
      console.log('SSE connected')
      isAlreadyConnectedSSE.value = true
    },
  })
}
```

The 2 onEvent bodies are copied VERBATIM from the existing factories. The shape of the ChatView component is otherwise unchanged.

- [ ] **Step 2: Replace `eventSource` + `queueEventSource` refs with `chatSse`**

Search ChatView.vue for `eventSource` and `queueEventSource` references and rename to `chatSse`. The `disconnectSse` body (lines 1677-1689) simplifies to:

```ts
const disconnectSse = () => {
  if (chatSse.value) {
    chatSse.value.close()
    chatSse.value = null
  }
  isStreaming.value = false
  streamingContent.value = ''
  messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
}
```

- [ ] **Step 3: Update the chatViewWorktree test**

`src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts:121-122` spies on BOTH `createSseConnection` and `createQueueMessagesSseConnection`. Replace with a single `createUnifiedSseConnection` spy that captures `opts.channels.llm.onEvent` and `opts.channels.queue.onEvent`. Tests that previously fired a fake event on the captured `onMessage` should now fire on `capturedOpts.channels.llm.onEvent(fakeEvent)`. Tests that fired a queue event should now fire on `capturedOpts.channels.queue.onEvent(fakeEvent)`.

- [ ] **Step 4: Run the ChatView test + full build**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run chatViewWorktree.spec 2>&1 | tail -n 20
```

Expected: build clean, ChatView test passes.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/components/ChatView.vue src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts
git commit -m "refactor(desktop): migrate ChatView llm+queue SSE to unified factory"
```

---

## Chunk 8: Verify the end-to-end migration (frontend ↔ backend)

### Task 8.1: Run the full backend + frontend test suites

- [ ] **Step 1: Backend tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
timeout 240 zig build test --summary all 2>&1 | tail -n 10
```

Expected: `test success`. The new 4 unified-events-sse tests pass; all other tests untouched.

- [ ] **Step 2: Backend install**

```bash
timeout 240 zig build install:linux:system 2>&1 | tail -n 5
```

Expected: 4/6 steps succeed (the cp to `/usr/local/bin/nalar` fails harmlessly with permission denied). The crucial "compile exe nalar" step must succeed.

- [ ] **Step 3: Frontend build + tests**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: build clean, ALL frontend tests pass.

- [ ] **Step 4: Manual end-to-end smoke test**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
zig build install:linux:system 2>&1 | tail -n 5
./zig-out/bin/nalar --port 8080 &
sleep 2

# 1. Global SSE: workers + sessions + kanban
curl -N "http://127.0.0.1:8080/api/events?channels=workers,sessions,kanban" 2>&1 | head -n 5
# Expected: event: connected + data: {"connected": true}, then heartbeats

# 2. Chat SSE: llm + queue for session chat-12345
curl -N "http://127.0.0.1:8080/api/events?channels=llm:chat-12345,queue:chat-12345" 2>&1 | head -n 5
# Expected: same `connected` handshake

# 3. Mixed (5 channels): one SSE for everything
curl -N "http://127.0.0.1:8080/api/events?channels=workers,sessions,kanban,llm:chat-12345,queue:chat-12345" 2>&1 | head -n 5
# Expected: same `connected` handshake

# 4. 400 errors
curl -i "http://127.0.0.1:8080/api/events" 2>&1 | head -n 3
curl -i "http://127.0.0.1:8080/api/events?channels=" 2>&1 | head -n 3
curl -i "http://127.0.0.1:8080/api/events?channels=foo" 2>&1 | head -n 3
curl -i "http://127.0.0.1:8080/api/events?channels=llm:" 2>&1 | head -n 3
# Expected: all 4 return HTTP/1.1 400 Bad Request

# Kill nalar
kill $(pgrep -f "nalar --port 8080")
```

### Task 8.2: Verify the legacy 5 SSE endpoints still work (Phase 1 additive — they must)

- [ ] **Step 1: Confirm the legacy endpoints are still registered in main.zig**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
grep -n "router.sse" src/main.zig
```

Expected: 6 lines (5 legacy + 1 unified).

- [ ] **Step 2: Confirm the legacy endpoints still respond**

Same nalar on port 8080; smoke-test each:

```bash
./zig-out/bin/nalar --port 8080 &
sleep 2

curl -N -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/api/workers/stream"
curl -N -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/api/sessions/stream"
curl -N -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/api/llm/stream/chat-12345"
curl -N -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/api/llm/session/chat-12345/queue_messages/stream"
curl -N -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/api/kanban/events"
# All should return 200 (the SSE handshake succeeds)

kill $(pgrep -f "nalar --port 8080")
```

### Task 8.3: Commit any post-migration fixes

- [ ] **Step 1: Commit**

```bash
git status
# If clean, skip. If dirty, commit any final fixes.
```

---

## Chunk 9: Cleanup — Remove the 5 legacy SSE handlers + routes + factories

### Task 9.1: Delete the 5 legacy backend handler files

**Files:**
- Delete: `src/ai_workflow/tui/http_handlers/worker_sse.zig`
- Delete: `src/ai_workflow/tui/http_handlers/sessions_sse.zig`
- Delete: `src/ai_workflow/tui/http_handlers/llm_history_sse.zig`
- Delete: `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig`
- Delete: `src/ai_workflow/tui/http_handlers/kanban_events_sse.zig`
- Delete: `src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig`

- [ ] **Step 1: Remove the 6 files**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git rm src/ai_workflow/tui/http_handlers/worker_sse.zig \
       src/ai_workflow/tui/http_handlers/sessions_sse.zig \
       src/ai_workflow/tui/http_handlers/llm_history_sse.zig \
       src/ai_workflow/tui/http_handlers/queue_messages_sse.zig \
       src/ai_workflow/tui/http_handlers/kanban_events_sse.zig \
       src/ai_workflow/tui/http_handlers/kanban_events_sse_test.zig
```

### Task 9.2: Remove the 5 legacy `gs.router.sse(...)` calls and re-exports

**Files:**
- Modify: `src/main.zig:255-271`
- Modify: `src/ai_workflow/tui/http_handlers/mod.zig:23-24, 78-85, 122`

- [ ] **Step 1: Remove the 5 legacy route registrations in `main.zig`**

Delete lines 255, 267, 268, 269, 271. Keep ONLY the new `/api/events` route. The 3 GET handlers at line 254 (`/api/workers`), 264 (`/api/llm/session`), 266 (`/api/llm/session/:id/queue_messages`) stay — those are the REST list endpoints, NOT the SSE streams.

```zig
    // Worker API
    try gs.router.get("/api/workers", ai_mod.http_handlers.workerListHandler);
    // ↑ The old `try gs.router.sse("/api/workers/stream", ...)` line is REMOVED.

    // ...later...

    try gs.router.sse("/api/events", ai_mod.http_handlers.unifiedEventsStreamHandler);
    // ↑ Replaces the 5 legacy /api/*/stream routes. Single SSE endpoint.
```

- [ ] **Step 2: Remove the 5 legacy handler re-exports in `http_handlers/mod.zig`**

Delete lines 23, 24 (llmHistorySSE, sessionsStreamHandler), lines 81 (workersStreamHandler), 85 (kanbanEventsStreamHandler), 122 (queueMessagesStreamHandler). Keep ONLY:

```zig
// Unified SSE handler — single endpoint that fans out all event families.
// See unified_events_sse.zig for the channel grammar (?channels=).
pub const unifiedEventsStreamHandler = @import("unified_events_sse.zig").unifiedEventsStreamHandler;
```

- [ ] **Step 3: Update `sse_handshake_test.zig` to reference only the unified handler**

Reduce the `handlers` tuple to 1 entry, update the test name and comment:

```zig
    const handlers = .{
        "src/ai_workflow/tui/http_handlers/unified_events_sse.zig",
    };
```

```zig
test "SSE handshake: unified stream handler sends the connected event" {
    // The single SSE route registered in src/main.zig. Must contain
    // the `connected` handshake string in its source, or the frontend
    // SseStatusBadge will be stuck on "Connecting…".
```

- [ ] **Step 4: Verify build + tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
timeout 180 zig build 2>&1 | tail -n 10
timeout 180 zig build test --summary all 2>&1 | tail -n 10
```

Expected: clean build, `test success`. The sse_handshake_test.zig now tests 1 path instead of 4 — count drops by 0 test blocks (the same block, just a shorter array). The unified_events_sse_test.zig still has its 4 contracts.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/ai_workflow/tui/http_handlers/mod.zig src/ai_workflow/tui/http_handlers/sse_handshake_test.zig
git commit -m "refactor(sse): remove 5 legacy SSE routes + handler re-exports"
```

### Task 9.3: Delete the 5 legacy frontend `create*SseConnection` factories

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Remove the 5 old factory functions**

Delete:
- `createSseConnection` (lines 767-853)
- `createSessionsSseConnection` (lines 1615-1683)
- `createQueueMessagesSseConnection` (lines 1693-1778)
- `createWorkersSseConnection` (lines 1813-1879)
- `createKanbanSseConnection` (lines 1920-1955)

Keep ALL the type definitions (`WorkerEvent`, `SessionEvent`, `QueueMessageEvent`, `KanbanColumnEvent`, `KanbanTaskEvent`, `SseEvent`) — they're still exported and consumed by the callers (and the unified factory references them as `api.WorkerEvent` etc.).

- [ ] **Step 2: Verify build + tests**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: build clean (no consumer of the deleted factories remains, since Chunks 4-7 migrated them). All tests pass.

If `bun run build` reports "module 'createSseConnection' is not exported", a consumer was missed — grep for the deleted name:

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
grep -rn "createSseConnection\|createSessionsSseConnection\|createQueueMessagesSseConnection\|createWorkersSseConnection\|createKanbanSseConnection" src/apps/desktop/src/ | grep -v "api/index.ts"
```

Any remaining match is a missed consumer — migrate it the same way as the Chunk 4-7 patterns.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add src/apps/desktop/src/api/index.ts
git commit -m "refactor(desktop): remove 5 legacy create*SseConnection factories"
```

### Task 9.4: Final end-to-end verification

- [ ] **Step 1: Backend full build + tests**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
timeout 240 zig build 2>&1 | tail -n 5
timeout 240 zig build test --summary all 2>&1 | tail -n 10
timeout 240 zig build install:linux:system 2>&1 | tail -n 5
```

Expected:
- `zig build` — clean
- `zig build test` — `test success`, +4 tests from Chunk 2.2, -0 tests from Chunk 9 (sse_handshake_test.zig's array shortens but the test block is unchanged)
- `zig build install:linux:system` — 4/6 steps succeed; the cp to `/usr/local/bin/nalar` fails harmlessly with "Permission denied"

- [ ] **Step 2: Frontend full build + tests**

```bash
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 20
timeout 180 bunx vitest run 2>&1 | tail -n 20
```

Expected: build clean, ALL frontend tests pass.

- [ ] **Step 3: Manual smoke test (final)**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
./zig-out/bin/nalar --port 8080 &
sleep 2

# 1. The new unified endpoint works
curl -N "http://127.0.0.1:8080/api/events?channels=workers,sessions,kanban" 2>&1 | head -n 5
# Expected: event: connected + data: {"connected": true}, then heartbeats

# 2. The 5 legacy endpoints return 404 (they were removed in 9.2)
for ep in workers/stream sessions/stream "llm/stream/chat-12345" "llm/session/chat-12345/queue_messages/stream" kanban/events; do
  code=$(curl -N -o /dev/null -w "%{http_code}" "http://127.0.0.1:8080/api/$ep")
  echo "/api/$ep → $code"
done
# Expected: all 5 → 404

kill $(pgrep -f "nalar --port 8080")
```

- [ ] **Step 4: Commit the plan document for review**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git add docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md
git commit -m "docs(sse): add unified SSE endpoints plan"
```

- [ ] **Step 5: Push the branch + open a PR**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-sse-endpoints
git push -u origin worktree/unify-sse-endpoints
gh pr create --title "feat(sse): unify 5 SSE endpoints into /api/events" \
             --body "$(cat <<'EOF'
## Summary

Collapses the 5 dedicated SSE routes registered in `src/main.zig` into a single
`GET /api/events?channels=…` endpoint. The frontend opens ONE EventSource per
scope (1 global for workers+sessions+kanban, 1 per chat for llm+queue), down
from 5 EventSources today.

## Backend

- New: `src/ai_workflow/tui/http_handlers/unified_events_sse.zig` — single
  handler that registers the connecting `client_id` under ALL requested
  event_bus routing keys and fans every event out. Lifts the proven
  `forwardToClients` helper from `kanban_events_sse.zig:34-76`.
- New: `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig` — 4
  static regression contracts (handler exists, 5 channel tokens recognized,
  connected handshake sent, route registered in main.zig).
- Removed: 5 legacy handler files (`worker_sse.zig`, `sessions_sse.zig`,
  `llm_history_sse.zig`, `queue_messages_sse.zig`, `kanban_events_sse.zig`)
  and their `kanban_events_sse_test.zig`. 5 legacy `gs.router.sse(...)`
  calls in `main.zig` removed. 5 re-exports in `http_handlers/mod.zig`
  removed. `sse_handshake_test.zig` shortened from 4 to 1 handler.

## Frontend

- New: `src/apps/desktop/src/api/index.ts` `createUnifiedSseConnection`
  factory — takes a `channels: { workers?, sessions?, kanban?, llm?, queue? }`
  map, builds `?channels=` from the keys the caller wired up, registers all
  known named event types (`kanban_column`, `kanban_task`, `queue_message`)
  with the SseClient, dispatches incoming events to the right callback by
  `eventType` + JSON-shape discrimination.
- Removed: 5 legacy factories (`createWorkersSseConnection`,
  `createSessionsSseConnection`, `createQueueMessagesSseConnection`,
  `createSseConnection`, `createKanbanSseConnection`). Migrated all 5
  consumers (App.vue, workspaces.ts, ChatsList.vue, kanbanSse.ts,
  ChatView.vue). Removed the redundant `ChatsList.vue` sessions subscription
  (it duplicated `workspacesStore.subscribeToSessionEvents()`).
- Test mocks updated in 4 spec files (workspacesStoreSessionEvents,
  chatsListGitWorktree, kanbanSse, chatViewWorktree).

## Test plan

- [ ] `cd .worktrees/unify-sse-endpoints && timeout 240 zig build test --summary all` — `test success`, +4 from new tests
- [ ] `cd src/apps/desktop && timeout 180 bun run build && timeout 180 bunx vitest run` — both clean
- [ ] Manual: open the desktop app, watch a chat stream in DevTools → Network
  → EventStream: see `/api/events?channels=…` as the ONLY EventSource.
  Verify the `SseStatusBadge` connects, chat chunks arrive, queue messages
  arrive, kanban events arrive (after a column add/delete).

## Out of scope

- The deferred-send fix (`docs/superpowers/plans/2026-06-30-fix-sse-blocking-api.md`)
  is a separate PR. This plan uses the existing `sendToClient`/`registerSessionClient`
  pattern; no new synchronization primitives.

Plan: `docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md`
EOF
)"
```

---

## Pitfalls

1. **Don't capture the routing key in an inline struct callback.** Task 1.1's "Step 1" draft has a deliberately-wrong closure-capture pattern (the `Callback` struct field `routing_key` references a comptime slot that doesn't survive loop iterations). The fix in Task 1.1's "Step 2" lifts the 6 callback structs to top-level — that's the pattern the codebase already uses (`CallbackKanbanColumnStream`, `CallbackWorkersStream`, etc.). If you see "use of undefined value" or "comptime value escapes scope" in the inline-struct path, take the lift-to-top-level fix.

2. **Don't subscribe the SAME callback to the SAME routing key twice.** The `forwardToClients` helper iterates `client_ids`, so if a single client_id is registered under one routing key twice, the same SSE frame gets sent twice. The unified handler's `parseChannels` does NOT dedupe; if the frontend sends `?channels=workers,workers`, the client gets 2 copies of every worker event. Acceptable for now (it's the same channel set 2x — equivalent to asking for the same thing twice). Add dedup in `parseChannels` if it becomes a real issue.

3. **Don't set `additionalEventTypes: ['connected', 'message']` in the unified factory.** `createSseClient` already auto-registers `connected` (line 81 of `sseClient.ts`) and the unnamed default `message` (line 159). Duplicates in `additionalEventTypes` are silently de-duplicated (line 182), but adding them explicitly is noise. Only declare custom named event types (`kanban_column`, `kanban_task`, `queue_message`).

4. **Don't use `text_replace` for big code blocks in ChatView.vue / kanbanSse.ts / workspaces.ts — read the file first, then surgically replace the SPECIFIC `create*SseConnection(...)` invocation.** The bodies of those onEvent handlers are large (ChatView's llm onEvent is ~60 lines); `text_replace` works only if `old_str` matches exactly once. Read the file, copy the specific `create*SseConnection(...)` call block including its closing paren, and replace just that block.

5. **Don't forget the per-channel JSON buffers in the unified factory's default `message` handler.** The 5-event-type contract has 3 default-`message` families (workers, sessions, llm) and 3 named families (kanban_column, kanban_task, queue_message). The default-`message` families need 3 buffers (`workerBuf`, `sessionBuf`, `llmBuf`) — the named families carry single-line JSON and don't need buffers. Forgetting to clear the buffers on `connected` corrupts the next parse (memory `nalar-sse-incomplete-chunked-encoding.md` documents a similar "leftover bytes" bug class).

6. **Don't drop the `sse_handshake_test.zig` "4 handlers" assertion before the unified handler lands.** Chunk 2.1 UPDATES the tuple (adds the 5th entry). Chunk 9.2 SHRINKS it to 1. If you delete the test in Chunk 9 without first adding the unified entry, the handshake contract becomes unpinned.

7. **Don't `git rm` the legacy handler files in Chunk 9.1 BEFORE Chunk 9.2's `main.zig` and `mod.zig` edits land.** If the imports in `mod.zig` reference the deleted files, `zig build` will fail with "no member named 'workersStreamHandler'". Order matters: edit `mod.zig` and `main.zig` FIRST, verify the build, THEN `git rm` the files.

8. **Don't change the `ChatView.vue` `isStreaming` flag semantics.** Memory `nalar-sse-incomplete-chunked-encoding.md` documents that `isStreaming` flips to `false` ONLY on terminal `state === 'failed'`, NEVER on transient `reconnecting`. The unified factory preserves this contract (`onStateChange: (state, info) => { if (state === 'failed') onError(...) }`) — same as the 5 old factories. Test that the chat-view test file's `isStreaming` assertions still hold after the migration.

---

## Verification

End-to-end success means ALL of the following are true after Chunk 9:

1. `cd .worktrees/unify-sse-endpoints && timeout 240 zig build test --summary all` → `test success`. Test count grows by 4 from the new `unified_events_sse_test.zig`. No other test count changes.
2. `cd .worktrees/unify-sse-endpoints && timeout 240 zig build install:linux:system` → 4/6 steps succeed. The crucial "compile exe nalar" step must succeed; the cp-to-/usr/local/bin step fails harmlessly with permission denied.
3. `cd src/apps/desktop && timeout 180 bun run build` → clean. No TS errors.
4. `cd src/apps/desktop && timeout 180 bunx vitest run` → all tests pass.
5. `grep -rn "createWorkersSseConnection\|createSessionsSseConnection\|createQueueMessagesSseConnection\|createSseConnection\b\|createKanbanSseConnection" src/apps/desktop/src/ | grep -v "api/index.ts"` → 0 matches (no missed consumer).
6. `grep -n "router.sse" src/main.zig` → 1 match (`/api/events`).
7. `./zig-out/bin/nalar --port 8080 &` → starts cleanly.
8. `curl -N "http://127.0.0.1:8080/api/events?channels=workers,sessions,kanban"` → prints `event: connected\ndata: {"connected": true}\n\n` then `data: ping` heartbeats.
9. `for ep in workers/stream sessions/stream "llm/stream/chat-12345" "llm/session/chat-12345/queue_messages/stream" kanban/events; do curl -N -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:8080/api/$ep"; done` → all 5 return `404`.
10. `kill $(pgrep -f "nalar --port 8080")` → clean shutdown.

If any of (1)-(9) fail, do NOT mark the plan done. Return to the failing chunk and fix. The 4 `+4 test count` is the most sensitive signal — re-count by running `timeout 60 $(ls -t .zig-cache/o/*/test | head -n 1) 2>&1 | grep -c "^test "` for the raw count.

---

## Review loop

After saving this plan to disk (file: `docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md`), dispatch the plan-document-reviewer subagent for each chunk with `<chunk-content>` + the path to this spec file. If any chunk is ❌ Issues Found, fix it in this file and re-dispatch. Once ✅ Approved for all chunks, hand off to `superpowers:subagent-driven-development` for execution.
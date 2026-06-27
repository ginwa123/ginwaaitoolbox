# Plan: Fix stuck "Connecting…" badge on chat stream

**Date:** 2026-06-05
**Status:** Proposed
**Severity:** Cosmetic / UX confusion (no functional impact — the stream is live)
**Scope:** 2 backend handlers, 1 frontend badge, 1 regression test

---

## Symptom (user report)

Screenshot of the chat bottom-bar shows the SSE status badge stuck on
`Connecting…` even after the backend is fully connected, the chat is loaded,
and an LLM turn has finished. The user reads the badge as "the stream is not
yet live" and is confused why LLM tokens are arriving anyway.

The chat top bar (the one driven by the workers stream) does NOT have this
problem — it correctly hides after a successful `open` transition.

---

## Root cause (full trace)

### What the badge is wired to

`src/apps/desktop/src/components/ChatView.vue:1980`

```vue
<SseStatusBadge :client="eventSource" />
```

`eventSource` is assigned in `ChatView.vue:1074`:

```ts
eventSource.value = api.createSseConnection(
  sessionId,
  onMessage,
  onError,
  onConnected,
)
```

`createSseConnection` (in `src/apps/desktop/src/api/index.ts:434`) builds an
`SseClient` against:

```ts
url: `${API_BASE}/llm/stream/${sessionId}`,
```

### What the URL resolves to

`src/main.zig:202` registers:

```zig
try gs.router.sse("/api/llm/stream/:session_id", ai_mod.http_handlers.llmHistorySSE);
```

So the URL is served by `src/ai_workflow/tui/http_handlers/llm_history_sse.zig`.

### What the handler does

`llm_history_sse.zig:54-75`:

```zig
pub fn llmHistorySSE(ctx, req, res) !gserverz.HttpResponse {
    // ... parameter validation ...

    if (ctx.client_id) |client_id| {
        const session_id_copy = try global_allocator.dupe(u8, session_id);
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient(session_id_copy, client_id_copy, true) catch {};
    }

    const event_bus = di.event_bus;
    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, session_id, CallbackAiStream.callback) catch {};

    return error.WouldBlock; // ← keeps the connection alive
}
```

**It never sends `event: connected`.** It just registers, subscribes, and
hands the socket back to the server so the worker can push events into it.

### What the badge is waiting for

`SseStatusBadge.vue:46` initializes:

```ts
const state = ref<SseState>('connecting')
```

…and only transitions to `'open'` when the `SseClient` calls back with
state `'open'`. The `SseClient` only emits `'open'` on the
`connectedEventName` named event (default `'connected'`)
(`sseClient.ts:380-411`):

```ts
instance.addEventListener(connectedEventName, (e: Event) => {
  // ...
  hasBeenOpen = true
  emitState('open', { attempt, reason: 'manual' })
  // ...
})
```

The `EventSource` raw `open` event (HTTP 200 + headers) is **deliberately
ignored** as the liveness signal — see the comment in `sseClient.ts:170-180`
explaining why (the server can still reject at the protocol level).

### The asymmetry

| URL                              | Handler                       | Sends `event: connected`? | Badge hides on open? |
|----------------------------------|-------------------------------|---------------------------|----------------------|
| `/api/workers/stream`            | `workersStreamHandler`        | ✅ yes (`worker_sse.zig:71`) | ✅ yes |
| `/api/sessions/stream`           | `sessionsStreamHandler`       | ✅ yes (`sessions_sse.zig:72`) | ✅ yes |
| `/api/llm/session/:id/queue_messages/stream` | `queueMessagesStreamHandler` | ❌ NO | ❌ stuck |
| `/api/llm/stream/:session_id`    | `llmHistorySSE`               | ❌ NO  ← **this one**     | ❌ stuck |

The two handlers that DO send it have an identical 3-line block right after
`registerSessionClient` (see `worker_sse.zig:70-73`):

```zig
// Send "connected" event to the newly connected client
const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
```

The two handlers that DO NOT send it (`llm_history_sse.zig`,
`queue_messages_sse.zig`) were written before the SseClient-based
reconnection layer landed — at the time, the badge did not exist, so the
absence was invisible. When the frontend was migrated to `createSseClient`,
the comment in `createQueueMessagesSseConnection` (api/index.ts:985-989) was
updated to say "the SseClient-based version uses the proper 'connected'
named event" — but the backend was never updated to actually send it.

### Why the chat still works despite the badge

The chat only listens to **`message`** events for actual data
(`createSseConnection` in api/index.ts:453-505, `eventType === 'message'`).
The `connected` event is used purely as the liveness handshake. So data
flows, the LLM streams, tokens arrive, the chat works — the badge just
never sees the magic event that means "transition out of connecting."

---

## Proposed fix

**Backend-only change (recommended).** Mirror the `event: connected` send
from the working handlers into the two broken ones. This restores the
contract documented in `sseClient.ts:170-180` and the state machine in the
file header.

### Changes

**1. `src/ai_workflow/tui/http_handlers/llm_history_sse.zig`**

After `registerSessionClient` (line 65-69), add the same 3-line block
already used in `worker_sse.zig:70-73`. This file currently does not
reference `server` at the top, so add `const server = di.server;` after
`const di = try nalar_core.getSingleton();` (line 57).

Concretely, change lines 57-69 from:

```zig
const di = try nalar_core.getSingleton();
const global_allocator = di.allocator;

const session_id = req.params.get("session_id") orelse { ... };

// Register the client_id mapping (set by http_server after registerClient)
if (ctx.client_id) |client_id| {
    const session_id_copy = try global_allocator.dupe(u8, session_id);
    const client_id_copy: [16]u8 = client_id;
    ai_mod.registerSessionClient(session_id_copy, client_id_copy, true) catch {};
}
```

to:

```zig
const di = try nalar_core.getSingleton();
const global_allocator = di.allocator;
const server = di.server;

const session_id = req.params.get("session_id") orelse { ... };

// Register the client_id mapping (set by http_server after registerClient)
if (ctx.client_id) |client_id| {
    const session_id_copy = try global_allocator.dupe(u8, session_id);
    const client_id_copy: [16]u8 = client_id;
    ai_mod.registerSessionClient(session_id_copy, client_id_copy, true) catch {};

    // Send "connected" event so the SseClient transitions out of
    // 'connecting'. Mirrors worker_sse.zig and sessions_sse.zig.
    const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
    server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
}
```

**2. `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig`**

Same change. The file already has `const server = di.server;` on line 15,
so only the 3-line block needs adding. After `registerSessionClient` /
`event_bus.subscribe` (lines 87-98), add the same block. **Caveat:** the
current handler does not capture `client_id_copy` as a separate variable
(it inlines it into the call). Refactor to:

```zig
if (ctx.client_id) |client_id| {
    const copy_key_for_register = try global_allocator.dupe(u8, copy_key_for_event_bus);
    const client_id_copy: [16]u8 = client_id;
    ai_mod.registerSessionClient(copy_key_for_register, client_id_copy, true) catch {
        std.debug.print("SSE_QUEUE_DEBUG: failed to register client\n", .{});
    };

    // Send "connected" event so the SseClient transitions out of
    // 'connecting'. Mirrors worker_sse.zig and sessions_sse.zig.
    const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
    server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
}
```

### Optional frontend defense (defense-in-depth, NOT a substitute for the backend fix)

Add a `connectedGraceMs` option to `createSseClient` that, if the
`connected` event has not arrived within N ms after `open`, emits `'open'`
anyway with `reason: 'timeout'`. This protects against future handlers that
forget the handshake. **But:** it weakens the documented contract (the
comment at sseClient.ts:170-180 says the raw `open` is NOT a "live"
signal). So:

- If added, default to `0` (disabled) — the existing handlers must
  explicitly opt in by passing a non-zero value, OR
- Skip this entirely; the regression test below is cheaper defense.

### Regression test

A new Zig test that walks the four registered stream URLs and asserts each
one sends the `event: connected` event within a short window. The test
sits in `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` and is
registered in `test_runner.zig` next to the other `*_test.zig` files in
that directory.

The test:
1. Spins up a `gserverz.Server` on an ephemeral port with the 4 SSE
   routes registered (or imports the production `main.zig` route block
   directly — TBD at implementation time, whichever is cheaper).
2. Opens 4 `std.http.Client` streaming GETs in parallel (one per URL).
3. Reads the response body byte-by-byte until it finds a line starting
   with `event: connected`.
4. Asserts each stream finds the line within 1 000 ms of its HTTP `open`.
5. Fails loudly with the stream name + first 256 bytes if any of the 4
   streams is missing the event.

(The frontend `sseClient.spec.ts` already covers the `SseClient` side —
that the `connected` event transitions to `open`. The new test is the
backend mirror: that the 4 handlers actually SEND the event.)

### Manual verification (post-fix)

1. `bun run build` (catches TypeScript regressions — see NALAR.md lesson
   "Desktop app: ALWAYS run `bun run build`")
2. `bun run test:unit` — all 31 + N new tests pass
3. `zig build` — backend compiles, new test registered
4. `zig build test` — new `sse_handshake_test` passes
5. Hard-refresh the desktop app (Cmd/Ctrl+Shift+R).
6. Open a chat. The "Connecting…" badge in the bottom bar should:
   - Appear briefly during the initial `EventSource` connect
   - Hide within ~100 ms of the HTTP `open`
   - Stay hidden for the rest of the session (the chat is open)
7. Open ChatsList (sidebar). The "Connecting…" badge in the header should
   behave the same way (this one was already working — the `sessionsSse`
   client works correctly today — but it's a good regression check).
8. Reconnect test: kill the backend (`pgrep -f nalar` → `kill`), restart
   it, the badge should reappear and then hide again on the new
   `connected` event.

---

## Files changed

| File | Change | Lines |
|------|--------|-------|
| `src/ai_workflow/tui/http_handlers/llm_history_sse.zig` | Add `event: connected` send after `registerSessionClient` | +4 |
| `src/ai_workflow/tui/http_handlers/queue_messages_sse.zig` | Add `event: connected` send after `registerSessionClient` | +4 |
| `src/ai_workflow/tui/http_handlers/sse_handshake_test.zig` | NEW — assert all 4 streams send `event: connected` | ~80 |
| `test_runner.zig` (or whatever registers the handler tests) | Register the new test | +1 |

Total: **2 surgical backend changes + 1 regression test**. No frontend
changes required. No public API changes. The `SseStatusBadge` and
`SseClient` code is already correct — they were just receiving the wrong
signal from two of the four handlers.

---

## Out of scope (deliberately)

- **No "fall back to raw `open`" change to `SseClient`.** Would weaken
  the documented contract and let the next handler that forgets the
  handshake silently work — hiding the bug rather than catching it.
  The regression test is a better defense.
- **No change to the badge template or visibility logic.** The badge is
  already correct — it transitions to `open` (and hides) the moment
  `SseClient` emits `'open'`, which is the moment the server sends
  `event: connected`. The two broken handlers just never send it.
- **No refactor of the 4 SSE handlers into a shared helper.** The 3-line
  `event: connected` send is too small to abstract, and the handlers
  differ in too many other ways (different routing keys, different
  callbacks, different parameter validation). A helper would obscure
  more than it would save.

---

## Lessons to capture in NALAR.md after verification

1. **The `SseClient` `connected` event is a contract, not a suggestion.**
   When a new SSE handler is added, it MUST send
   `event: connected\ndata: {"connected": true}\n\n` to its newly
   registered client before returning `error.WouldBlock`. Otherwise the
   frontend `SseStatusBadge` will be stuck on "Connecting…" forever
   even though the connection is live. The new regression test enforces
   this.
2. **A frontend-only fix is incomplete.** A previous attempt migrated
   the frontend to `SseClient` and updated the comment in
   `createQueueMessagesSseConnection` to say "the SseClient-based
   version uses the proper 'connected' named event" — but the backend
   was never updated. Comments in adapters are not enforcement. The
   regression test is.
3. **`wouldBlock` SSE handlers need a "hello" before they go quiet.**
   When a handler returns `error.WouldBlock` to keep the socket alive,
   it should send at least one event (the `connected` handshake) before
   the first real event, so the client knows it's not staring at a
   silent connection. This is the same idea as HTTP 100-continue for
   long-lived requests.

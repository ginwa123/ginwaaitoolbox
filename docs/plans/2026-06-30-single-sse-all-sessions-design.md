# Single SSE Stream + Client-Side Session Filter — Design

> **Status:** Design approved 2026-06-30. Supersedes PR #51's per-session EventSource refcount design.
> **Brainstorming session:** `docs/superpowers/plans/2026-06-30-unify-frontend-sse.md` (predecessor) + this doc.
> **Implementation plan:** pending (will be created by the writing-plans skill after this doc commits).

## Problem

PR #51's design opens a per-session EventSource (`/api/events?channels=llm:<sid>,queue:<sid>`) on chat mount and closes it on unmount. This means **every chat switch causes a TCP close + TCP open + SSE handshake** (~1-5s of flicker, 1 new server-side subscriber per switch, and a per-origin HTTP/1.1 connection slot used briefly).

For a power user cycling through 20 chats/session, that's 20 TCP handshakes/session. Real cost, real UX cost.

The user's directive: "just have the backend publish all events and let the frontend filter." Kafka-style: one subscription, server filters by routing key, client filters by payload field.

## Goal

Replace PR #51's per-session EventSource refcount machinery with **a single global EventSource** carrying ALL channels (`workers`, `sessions`, `kanban`, `llm`, `queue`). The frontend filters `llm` and `queue` events by `event.session_id` against the active chat's id.

**Result:** ONE TCP connection per app for the app's lifetime. Chat switches = zero TCP activity.

This is the same pattern PR #51's bus already uses for `workers`/`sessions`/`kanban` (global channels with broadcast semantics); this design extends that pattern to `llm`/`queue` by adding central event-bus keys for them.

## Design

### High-level architecture

```
┌───────────────────────────────────────────────────────────┐
│  App.vue (root)                                           │
│  • installSseBus()                                        │
│  • opens ONE SseClient to:                                │
│    /api/events?channels=workers,sessions,kanban,          │
│                        llm,queue                          │
│  • reconnect-resync via watch(bus.state, ...)              │
└────────────────────────┬──────────────────────────────────┘
                         │ single global EventSource (persistent)
┌────────────────────────┴──────────────────────────────────┐
│  sseBus (module-level singleton)                         │
│  • on(type, cb) → unsubscribe                             │
│  • off(type, cb)                                          │
│  • state: ShallowRef<SseState>                            │
│  • reconnectGlobal(), close()                             │
│  NO session-scoped EventSource machinery                  │
└────────┬────────────────────────────────────────────────┘
         │ fans out via 5 typed listener Sets
  App.vue            workspaces store     ChatView.vue
   (worker)           (session, fan out    (llm + queue
                      to ChatsList)         filtered by
                      kanbanSse              event.session_id
                      (kanban, filter        === mySid,
                       by workspace_id)     listener-side)
                      useSubAgentPeek
                       (llm filtered by
                        event.session_id
                        === peekSid)
                      SseStatusBadge
                       (renders bus.state)
```

**One TCP connection per app for the app's lifetime.** Switching chats = update a `mySessionId.value` ref in ChatView. Listeners re-evaluate the filter on the next event — zero new connections.

### Public bus API (simpler than PR #51)

```ts
export interface SseBus {
  on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void
  off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void
  readonly state: ShallowRef<SseState>
  reconnectGlobal(): void
  close(): void
}
```

**Removed from PR #51:**
- `subscribeSessionChannels(sid): void`
- `unsubscribeSessionChannels(sid): void`
- The internal session-client Map + refcount Map
- `_sessionFactory` test override + `__setSseBusSessionFactory(...)`

**Unchanged:**
- `installSseBus(app?)`, `useSseBus()`, `__resetSseBus()`, `__dispatchSseBus()`, `__setSseBusGlobalClient()`, `__getSseBusGlobalClient()`
- Swap-aware `close()`/`reconnectGlobal()` (commit `bbfe742c`)
- All 5 listener channels + `SseEventMap` types

### Listener-side filter (defense-in-depth)

Even though the backend can now broadcast all sessions' events to one client, every listener that cares about a specific session still does:

```ts
bus.on('llm', (event) => {
  if (event.session_id !== mySid.value) return
  // ...
})
```

**Why keep the filter (server already broadcasts everything):**
- Future server-side bug or routing regression could send wrong-session events — the listener filter catches it before it reaches the UI
- One integer comparison per event (sub-microsecond)
- Same pattern as PR #51 — keeps the listener contract consistent with the per-session filter (filter is the layer that knows which session is "current")

The filter is the SAME code that PR #51 used; the only thing that changes is there's no second EventSource to open/close.

### Backend change (one global stream for everything)

**3 files change on the backend:**

1. **`src/ai_workflow/tui/http_handlers/unified_events_sse.zig`** — `parseChannels` accepts 2 new tokens (bare `llm` and bare `queue`):
   ```zig
   } else if (std.mem.eql(u8, token, "llm")) {
       try routing_keys.append(allocator, try allocator.dupe(u8, "llm"))
   } else if (std.mem.eql(u8, token, "queue")) {
       try routing_keys.append(allocator, try allocator.dupe(u8, "queue"))
   ```
   Bare `llm` and bare `queue` register the client under central routing keys `"llm"` and `"queue"`. **Removed:** the `llm:<sid>` and `queue:<sid>` token paths (clean replacement per Option 2 from Q1).

2. **`src/ai_workflow/tui/on_event_sent.zig`** — the LLM and queue emitters ADDITIONALLY broadcast on the central keys (in addition to per-session keys, which stay for any future server-side fan-out):
   ```zig
   // In the LLM event callback (around line 299-302):
   event_bus.emit(SseEvent, input.session_id, event)  // existing (per-session)
   event_bus.emit(SseEvent, "llm", event)             // NEW: central broadcast
   
   // In the queue callback (around line 202):
   event_bus.emit(SseEvent, composed, data)             // existing (queue_messages_<sid>)
   event_bus.emit(SseEvent, "queue", data)             // NEW: central broadcast
   ```

3. **Tests** — `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig`:
   - ADD 2 tests: `parseChannels: bare "llm" routes to central "llm" key`, `parseChannels: bare "queue" routes to central "queue" key`
   - UPDATE 2 existing tests: `parseChannels: llm:<sid> routes to per-session` and `queue:<sid>` variants — change to expect `error.UnknownChannel` (the per-session tokens are gone)
   - UPDATE 1 existing test: `parseChannels: mixed 5 channels` — change the test input from per-session tokens to bare tokens

Subscribers, listeners, callback wiring, `forwardToClients` — **all unchanged**.

### Frontend change (drop the session-scoped EventSource machinery)

**5 files change on the frontend:**

1. **`src/apps/desktop/src/api/index.ts`** — `UnifiedChannels.llm` and `.queue` accept `{ sessionId?: string; onEvent: ... }` (sessionId now optional). When `sessionId` is omitted, the factory sends bare `llm` / `queue` tokens; when present, it sends `llm:<sid>` / `queue:<sid>` (unused under this plan but kept for back-compat with any future server-side-filter caller).

2. **`src/apps/desktop/src/helpers/sseBus.ts`** — the global SseClient opens with **bare `llm` and `queue`** (no sessionId). No session-scoped factory, no refcount pool, no `subscribeSessionChannels`. Two of the 12 sseBus tests get deleted (the refcount tests from Chunk 4); 1 new test added: `"installSseBus with bare llm+queue opens a single global EventSource"`.

3. **`src/apps/desktop/src/components/ChatView.vue`** — drop the `bus.subscribeSessionChannels(sid)` and `bus.unsubscribeSessionChannels(sid)` calls in `connectSse`/`disconnectSse`. Keep the `bus.on('llm', ...)` and `bus.on('queue', ...)` listeners with their `event.session_id !== sid` filters — those still work because the backend's central `llm` key now delivers ALL sessions' events.

4. **`src/apps/desktop/src/composables/useSubAgentPeek.ts`** — same as ChatView: drop `subscribeSessionChannels`/`unsubscribeSessionChannels`, keep the listener with its `session_id` filter.

5. **Test files** — `chatViewWorktree.spec.ts` and `useSubAgentPeek.spec.ts`:
   - Drop `__setSseBusSessionFactory` setup (no longer exists)
   - Drop refcount-related assertions
   - ADD 1 cross-session isolation assertion: dispatching an `llm` event for sid=A while ChatView listens for sid=B should NOT trigger the handler (the filter works); then dispatching for sid=B DOES trigger. Verifies that ONE global EventSource + listener filter is sufficient — no per-session connection needed.

### What we DON'T change

**Saved from PR #51 (all GOOD):**
- ✅ Module-level singleton bus pattern (`installSseBus`/`useSseBus`)
- ✅ 5 listener Sets with typed `SseEventMap`
- ✅ `__dispatchSseBus` test escape hatch
- ✅ `__setSseBusGlobalClient` + `__getSseBusGlobalClient` test escape hatches
- ✅ Swap-aware `close()`/`reconnectGlobal()` fix (commit `bbfe742c`)
- ✅ `state: ShallowRef<SseState>` mirror
- ✅ `makeStubClient` test helper
- ✅ Idempotent installation, JSDoc on every public method
- ✅ Both non-llm/queue call-site migrations (App.vue, workspaces, kanbanSse, SseStatusBadge)

**Removed (regression vs PR #51):**
- ❌ `subscribeSessionChannels` / `unsubscribeSessionChannels` — per-session EventSource machinery
- ❌ `_sessionFactory` test override
- ❌ `sessionClients` Map, `sessionRefcounts` Map in the bus closure
- ❌ 2 of the 12 sseBus tests (the refcount tests)

### Verification chain

After implementation:

```bash
# All 3 should be 0 in production code (tests/comments allowed):
rg "createUnifiedSseConnection" src/apps/desktop/src     # only in sseBus.ts (internal) + api/index.ts (def)
rg "subscribeSessionChannels" src/apps/desktop/src        # ZERO hits
rg "new EventSource" src/apps/desktop/src                  # only in sseClient.ts (the wrapper) + setup.ts (polyfill)

# All must pass:
cd src/apps/desktop && timeout 180 bunx vitest run
cd src/apps/desktop && timeout 120 bun run build
cd src/apps/desktop && timeout 60 bunx oxlint src/helpers/sseBus.ts src/components/ChatView.vue src/composables/useSubAgentPeek.ts src/api/index.ts src/__tests__/chatViewWorktree.spec.ts src/__tests__/useSubAgentPeek.spec.ts src/__tests__/sseBus.spec.ts
```

**Manual browser test:**
1. Open the app, open DevTools Network tab, filter by "events"
2. Open ChatView for chat A → expect 1 EventSource (the global `?channels=workers,sessions,kanban,llm,queue`)
3. Switch to chat B → expect the SAME EventSource to persist (no close, no new connection)
4. Open the sub-agent peek panel → expect the SAME EventSource (the peek's `llm` listener fires for the sub-agent's session id)
5. Close the peek → SAME EventSource

Before this PR: every chat switch opened a 2nd EventSource briefly (cross-session peek: 3 EventSources simultaneously). After this PR: 1 EventSource forever.

### Risk assessment

- **Backend change** is small (3 files, ~10 lines total). Easy to revert if something breaks.
- **Frontend change** is meaningful — touches ChatView's connect/disconnect lifecycle. The `event.session_id` filter is the load-bearing piece. If backend regression causes the filter to misroute, the BUG is loud (wrong session's events shown in the UI) and easy to spot.
- **The 2 tests being deleted** are specifically testing the refcount machinery. They become dead tests if kept (they'd still pass, but they'd be testing code that no longer exists). Deleting them keeps the suite honest.
- **Open PR #51** must be updated in place (Option 1 from Q3) — modifying the open PR via direct commits to its branch BEFORE merge. No merge-conflict risk since this is the same author and the changes are isolated to the bus + ChatView + useSubAgentPeek (the rest of PR #51 is unchanged).

### Out of scope

- Server-side wildcard subscription (`llm:*`) — explicitly rejected by user; client filter is simpler
- Multi-tab / multi-window behavior (each tab opens its own bus + 1 EventSource — same as today's Post-PR-#51 behavior)
- `SseClient` library changes (reused unchanged)
- Pre-existing test failures in `kanban-board.spec.ts` — auto-resolve on merge with current main

## Next step

Invoke the **writing-plans** skill to convert this design into a step-by-step implementation plan with TDD bite-sized tasks.

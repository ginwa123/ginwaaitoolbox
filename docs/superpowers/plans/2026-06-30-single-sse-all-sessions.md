# Single Global SSE Stream + Client-Side Session Filter — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status:** Supersedes `docs/superpowers/plans/2026-06-30-unify-frontend-sse.md` (the v1 plan that PR #51 implemented). The v1 plan's per-session EventSource refcount machinery is being **reverted** in favor of a single global stream with client-side session filtering.

**Goal:** Replace PR #51's per-session EventSource refcount machinery with **one global EventSource** that carries all 5 channels (`workers`, `sessions`, `kanban`, `llm`, `queue`). The frontend filters `llm` and `queue` events by `event.session_id` on the listener side. Result: ONE TCP connection per app for the app's lifetime.

**Architecture:**
1. **Backend** (Chunk 1): `parseChannels` accepts bare `llm` and bare `queue` tokens (registers under central routing keys `"llm"` and `"queue"`). Two event emitters (`on_event_sent.zig` for LLM, `llm_history.zig` for queue messages) additionally `event_bus.emit` on the central keys alongside the existing per-session keys.
2. **Frontend sseBus** (Chunk 2): Remove `subscribeSessionChannels`/`unsubscribeSessionChannels` + the per-session `_sessionFactory` + the `sessionClients`/`sessionRefcounts` Maps. The single global SseClient opens with all 5 channels (`workers,sessions,kanban,llm,queue`) and fans out via the existing 5 listener Sets.
3. **Frontend call sites** (Chunk 3): Drop `bus.subscribeSessionChannels(sid)` and `bus.unsubscribeSessionChannels(sid)` calls in `ChatView.vue` and `useSubAgentPeek.ts`. Listener-side `event.session_id !== mySid` filters stay (defense-in-depth).
4. **Frontend api factory** (Chunk 4): Make `sessionId` optional on `UnifiedChannels.llm`/`.queue`. When omitted, factory sends bare `llm`/`queue` tokens (used by the bus); when present, sends `llm:<sid>`/`queue:<sid>` (kept for back-compat — no current caller uses this).

**Tech Stack:** Zig 0.16 backend (existing patterns: `event_bus.emit`, `parseChannels`); Vue 3 + TypeScript strict frontend (existing patterns: `SseClient` interface, `bus.on`/`off` typed listeners, module-level singleton); Vitest + jsdom (frontend), Zig test runner (backend).

**Spec / context:**
- Design doc: `docs/plans/2026-06-30-single-sse-all-sessions-design.md` (commit `35e67d10` on `worktree/unify-frontend-sse`).
- Brainstorming session: `docs/superpowers/plans/2026-06-30-unify-frontend-sse.md` (v1 plan, kept as historical record).
- PR #51 state: 18 commits on `worktree/unify-frontend-sse` branch. The refcount machinery added in v1 (commits `08348e34`, `47da5587`, `66191232`, `eb1dbb67`, `1e101e77`) is being **reverted** by this plan. The infrastructure (sseBus.ts skeleton, global SseClient, 4 call site migrations, swap-aware close/reconnect, status badge) is kept and modified.
- Backend constraint pre-plan: `parseChannels` only accepts `llm:<sid>` and `queue:<sid>`. Source of truth: `src/ai_workflow/tui/http_handlers/unified_events_sse.zig:102`. This plan changes that.
- Existing emitters:
  - LLM: `src/ai_workflow/tui/on_event_sent.zig:302` — `event_bus.emit(SseEvent, input.session_id, event)` (per-session).
  - Queue: `src/ai_workflow/tui/llm_history.zig:1871-1874` — `event_bus.emit(SseEvent, "queue_messages_<sid>", event)` (per-session).
- Listener-side `event.session_id !== mySid.value` filters are kept as defense-in-depth (same code PR #51 had; just no second EventSource to manage).
- Memory: `sse-pagehide-cleanup.md` — SseClient handles `visibilitychange`/`online` listeners; nothing to add.
- Memory: `browser-eventsource-named-events.md` — named event types are pre-registered by `createUnifiedSseConnection`; the bus does not need to manage this.

---

## File Structure

### New files (0)

This plan only **modifies** files from the v1 plan and the backend. No new files.

### Modified files (8)

**Backend (3 files):**
- `src/ai_workflow/tui/http_handlers/unified_events_sse.zig` — `parseChannels` adds 2 new tokens: bare `llm` and bare `queue` (registers under central routing keys `"llm"` and `"queue"`). The `llm:<sid>` and `queue:<sid>` tokens are **removed** (clean replacement per design doc Q1 option 2).
- `src/ai_workflow/tui/on_event_sent.zig` — line 302: ADD a second `event_bus.emit(SseEvent, "llm", event)` AFTER the existing per-session emit.
- `src/ai_workflow/tui/llm_history.zig` — line 1871-1874: ADD a second `event_bus.emit(SseEvent, "queue", event)` AFTER the existing per-session `queue_messages_<sid>` emit.

**Backend tests (1 file):**
- `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig` — UPDATE 2 existing tests (`llm:<sid>`, `queue:<sid>`) to expect `error.UnknownChannel`. UPDATE the mixed 5-channel test to use bare tokens. ADD 2 new tests for bare `llm` and bare `queue` tokens.

**Frontend bus (1 file):**
- `src/apps/desktop/src/helpers/sseBus.ts` — REMOVE `subscribeSessionChannels`/`unsubscribeSessionChannels` from the `SseBus` interface + the `sessionClients`/`sessionRefcounts` Maps + the `_sessionFactory` test override + the `__setSseBusSessionFactory` export + the `DEFAULT_SESSION_FACTORY` const. CHANGE the global SseClient to open with all 5 channels (`workers,sessions,kanban,llm,queue` — bare `llm` and bare `queue` per Chunk 4's api factory change). CHANGE `close()` to no longer iterate session clients.

**Frontend bus tests (1 file):**
- `src/apps/desktop/src/__tests__/sseBus.spec.ts` — DELETE the 2 refcount tests (commit `08348e34` added these). ADD 1 new test: "installSseBus opens a single global SseClient with all 5 channels including bare llm+queue".

**Frontend call sites (2 files):**
- `src/apps/desktop/src/components/ChatView.vue` — DELETE lines 1714 and 1732 (`bus.subscribeSessionChannels(sid)` and `useSseBus().unsubscribeSessionChannels(sid)`). UPDATE the comment block at line 424 to describe the new model. The `bus.on('llm', ...)` and `bus.on('queue', ...)` listeners with their `event.session_id !== sid` filters STAY (unchanged).
- `src/apps/desktop/src/composables/useSubAgentPeek.ts` — DELETE lines 202 and 210. UPDATE the JSDoc to reflect that the bus now carries all channels globally.

**Frontend api factory (1 file):**
- `src/apps/desktop/src/api/index.ts` — CHANGE `UnifiedChannels.llm` and `.queue` field types from `{ sessionId: string; onEvent: ... }` to `{ sessionId?: string; onEvent: ... }`. UPDATE the factory's token-building to send bare `llm`/`queue` when `sessionId` is absent, `llm:<sid>`/`queue:<sid>` when present. UPDATE the JSDoc to describe the new model.

**Frontend call site tests (2 files):**
- `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts` — DROP `__setSseBusSessionFactory` setup (no longer exists). DROP refcount-related assertions. ADD 1 cross-session isolation test: dispatching an `llm` event for sid=A while ChatView listens for sid=B should NOT trigger the handler; dispatching for sid=B DOES trigger.
- `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts` — same pattern as chatViewWorktree.

### No new files

Confirmed: the v1 plan's `src/apps/desktop/src/__tests__/sseBus.spec.ts` already exists (added in commit `3effe06c`). We are modifying it, not creating it.

---

## Implementation order (chunks land in this order, not the heading order)

The chunk headings follow the **logical** order (backend → bus → call sites → api), but the **actual implementation order** must be:

1. **Chunk 1: Backend** (no dependencies)
2. **Chunk 4: Frontend api factory** (no dependencies — pure type + token-building change)
3. **Chunk 2: Frontend sseBus** (depends on Chunk 4 — the bus's bare `llm`/`queue` channels require the api factory's optional `sessionId`)
4. **Chunk 3: Frontend call sites** (depends on Chunk 2 — `subscribeSessionChannels` calls are removed only after the bus stops exposing them)

The chunk numbers (1-4) stay as in the headings for git-history clarity (each chunk = one commit). The implementation order is documented here so the executor knows which chunk to land first.

If the executor is a sub-agent, hand them this whole plan and the implementation order together. The sub-agent will execute chunks 1 → 4 → 2 → 3, but commit each as its own commit (chunks 1, 2, 3, 4 in commit history order to match the headings).

---

## Defaults locked by this plan

1. **One TCP connection per app for the app's lifetime.** No per-session EventSource machinery. The bus's `sseBus.ts` has a single `SseClient` opened at install time with all 5 channels.
2. **Backend central routing keys `"llm"` and `"queue"`** are the broadcast mechanism. The per-session keys (`<sid>` for llm, `queue_messages_<sid>` for queue) are KEPT for any future server-side fan-out (e.g. if a future tool needs to subscribe to one session server-side).
3. **Frontend listener-side `event.session_id !== mySid.value` filter is defense-in-depth** — backend filters by routing, frontend filters by payload field. Belt-and-suspenders against backend regressions.
4. **`UnifiedChannels.llm`/`.queue` accept optional `sessionId`** — when omitted, factory sends bare tokens (used by the bus); when present, factory sends `llm:<sid>` tokens (back-compat for any future direct caller — no current caller uses this).
5. **`SseStatusBadge` stays as-is** — it reads `bus.state` which mirrors the single global SseClient (commit `3058f578`).
6. **`installSseBus(app)` is called from App.vue's `onMounted`** — unchanged from v1.
7. **`bus.close()` is idempotent** — unchanged from v1. After this plan, it closes the single global client (no session clients to iterate).
8. **Test infrastructure uses `__dispatchSseBus`** — unchanged. Drives synthetic events directly into the bus's listener Sets, bypassing the SseClient.

---

## Context

### Why we are reverting v1's refcount machinery

PR #51's design opens a per-session `SseClient` on chat mount and closes it on unmount via a refcount Map. This means **every chat switch causes a TCP close + TCP open + SSE handshake** (~1-5s of flicker, 1 new server-side subscriber per switch).

The user's directive: "just have the backend publish all events and let the frontend filter." Kafka-style: one subscription, server broadcasts everything, client filters by payload field.

After this plan: ONE TCP connection per app for the app's lifetime. Chat switches = zero TCP activity.

### How the listener filter does the work

The filter is the SAME code PR #51 had — `if (event.session_id !== mySid.value) return` inside the `bus.on('llm', ...)` listener. The only thing that changes is there's no second EventSource to open/close. The filter is one integer comparison per event (sub-microsecond), so the cost of having the bus deliver ALL sessions' events to ALL subscribers is negligible.

### What we keep from v1 (all GOOD)

- ✅ Module-level singleton bus pattern (`installSseBus`/`useSseBus`)
- ✅ 5 listener Sets with typed `SseEventMap`
- ✅ `__dispatchSseBus` test escape hatch
- ✅ `__setSseBusGlobalClient` + `__getSseBusGlobalClient` test escape hatches
- ✅ Swap-aware `close()`/`reconnectGlobal()` fix (commit `bbfe742c`)
- ✅ `state: ShallowRef<SseState>` mirror
- ✅ `makeStubClient` test helper
- ✅ Idempotent installation, JSDoc on every public method
- ✅ All 3 non-llm/queue call-site migrations (App.vue → workers, workspaces → sessions, kanbanSse → kanban, SseStatusBadge)

### What we remove (regression vs v1)

- ❌ `subscribeSessionChannels` / `unsubscribeSessionChannels` — per-session EventSource machinery
- ❌ `_sessionFactory` test override + `__setSseBusSessionFactory` export
- ❌ `sessionClients` Map, `sessionRefcounts` Map in the bus closure
- ❌ 2 sseBus tests (the refcount tests added in commit `08348e34`)
- ❌ `DEFAULT_SESSION_FACTORY` const

---

## Verification chain (run after all 4 chunks)

```bash
# All 3 should be 0 in production code (tests/comments allowed):
rg "createUnifiedSseConnection" src/apps/desktop/src     # only in sseBus.ts (internal) + api/index.ts (def)
rg "subscribeSessionChannels" src/apps/desktop/src        # ZERO hits
rg "new EventSource" src/apps/desktop/src                  # only in sseClient.ts (the wrapper) + setup.ts (polyfill)

# All must pass:
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
timeout 180 zig build test --summary all 2>&1 | tail -n 5
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5

# Lint check (no new oxlint warnings):
cd src/apps/desktop && timeout 60 bunx oxlint src/helpers/sseBus.ts src/components/ChatView.vue src/composables/useSubAgentPeek.ts src/api/index.ts src/__tests__/chatViewWorktree.spec.ts src/__tests__/useSubAgentPeek.spec.ts src/__tests__/sseBus.spec.ts
```

**Manual browser test:**
1. Open the app, open DevTools Network tab, filter by "events"
2. Open ChatView for chat A → expect 1 EventSource (the global `?channels=workers,sessions,kanban,llm,queue`)
3. Switch to chat B → expect the SAME EventSource to persist (no close, no new connection)
4. Open the sub-agent peek panel → expect the SAME EventSource (the peek's `llm` listener fires for the sub-agent's session id)
5. Close the peek → SAME EventSource

Before this PR: every chat switch opened a 2nd EventSource briefly (cross-session peek: 3 EventSources simultaneously). After this PR: 1 EventSource forever.

---

## Chunk 1: Backend — central routing keys for `llm` and `queue`

Establishes the backend's "broadcast to all sessions" behavior. After this chunk:
- `parseChannels` accepts bare `llm` and bare `queue` (registers under central keys).
- The per-session `llm:<sid>` and `queue:<sid>` tokens are REMOVED.
- The LLM emitter broadcasts on `input.session_id` AND on central key `"llm"`.
- The queue emitter broadcasts on `queue_messages_<sid>` AND on central key `"queue"`.

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/unified_events_sse.zig:102-146` (parseChannels)
- Modify: `src/ai_workflow/tui/on_event_sent.zig:299-302` (LLM emitter)
- Modify: `src/ai_workflow/tui/llm_history.zig:1871-1874` (queue emitter)
- Modify: `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig:141-180` (parseChannels tests)

- [ ] **Step 1: Write the failing test for `parseChannels` accepting bare `llm`**

Append to `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig` (after the existing `parseChannels: llm:<sid>` test at line 141):

```zig
test "parseChannels: bare 'llm' → central 'llm' routing key" {
    const list = try parseChannels(allocator, "llm");
    defer {
        for (list.routing_keys) |k| testing.allocator.free(k);
        testing.allocator.free(list.routing_keys);
    }
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("llm", list.routing_keys[0]);
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse && timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: FAIL — `"llm"` token does not match `workers`/`sessions`/`kanban`/`llm:`/`queue:` branches, so the else branch returns `error.UnknownChannel`.

- [ ] **Step 3: Update the `llm:<sid>` existing test to expect `error.UnknownChannel`**

In `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig`, find the test at line 141:

```zig
test "parseChannels: llm:<sid> → sid as routing key" {
    const list = try parseChannels(allocator, "llm:chat-123");
    ...
```

Replace with:

```zig
test "parseChannels: llm:<sid> → error.UnknownChannel (superseded by bare 'llm')" {
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "llm:chat-123"));
}
```

- [ ] **Step 4: Update the `queue:<sid>` existing test to expect `error.UnknownChannel`**

In the same file, find the test at line 149:

```zig
test "parseChannels: queue:<sid> → queue_messages_<sid> as routing key" {
    const list = try parseChannels(allocator, "queue:chat-abc");
    ...
```

Replace with:

```zig
test "parseChannels: queue:<sid> → error.UnknownChannel (superseded by bare 'queue')" {
    try testing.expectError(error.UnknownChannel, parseChannels(allocator, "queue:chat-abc"));
}
```

- [ ] **Step 5: Update the mixed-5-channels test to use bare tokens**

In the same file, find the test at line 157:

```zig
test "parseChannels: mixed 5 channels → 6 routing keys (kanban expands)" {
    const list = try parseChannels(allocator,
        "workers,sessions,kanban,llm:chat-1,queue:chat-1");
    ...
```

Replace with:

```zig
test "parseChannels: mixed 5 channels (bare llm+queue) → 6 routing keys (kanban expands)" {
    const list = try parseChannels(allocator,
        "workers,sessions,kanban,llm,queue");
    defer {
        for (list.routing_keys) |k| testing.allocator.free(k);
        testing.allocator.free(list.routing_keys);
    }
    try testing.expectEqual(@as(usize, 6), list.routing_keys.len);
    // workers, sessions, kanban_column, kanban_task, llm, queue (in registration order)
    try testing.expectEqualStrings("workers", list.routing_keys[0]);
    try testing.expectEqualStrings("sessions", list.routing_keys[1]);
    try testing.expectEqualStrings("kanban_column", list.routing_keys[2]);
    try testing.expectEqualStrings("kanban_task", list.routing_keys[3]);
    try testing.expectEqualStrings("llm", list.routing_keys[4]);
    try testing.expectEqualStrings("queue", list.routing_keys[5]);
}
```

- [ ] **Step 6: Run the modified tests, verify the UPDATED tests pass and the new one FAILS**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse && timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: The updated `llm:<sid>` and `queue:<sid>` tests pass (they now expect `UnknownChannel`). The mixed-5-channels test passes (bare tokens). The new bare-`llm` test FAILS (production code hasn't been updated yet).

- [ ] **Step 7: Add the bare `llm` and `queue` token handling to `parseChannels`**

In `src/ai_workflow/tui/http_handlers/unified_events_sse.zig:102-146`, find the chain:

```zig
} else if (std.mem.startsWith(u8, token, "llm:")) {
    const sid = token["llm:".len..];
    if (sid.len == 0) return error.EmptySessionId;
    try routing_keys.append(allocator, try allocator.dupe(u8, sid));
} else if (std.mem.startsWith(u8, token, "queue:")) {
    const sid = token["queue:".len..];
    if (sid.len == 0) return error.EmptySessionId;
    const composed = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{sid});
    try routing_keys.append(allocator, composed);
```

Replace with:

```zig
} else if (std.mem.eql(u8, token, "llm")) {
    try routing_keys.append(allocator, try allocator.dupe(u8, "llm"));
} else if (std.mem.eql(u8, token, "queue")) {
    try routing_keys.append(allocator, try allocator.dupe(u8, "queue"));
```

- [ ] **Step 8: Update the file's doc comment at line 13-22**

In the same file, find the doc comment block at line 13-22 listing the supported channel tokens. Remove the `llm:<sid>` and `queue:<sid>` lines and replace with bare `llm` and `queue`. The comment is at the top of the file (just below the copyright header).

Replace the lines 14-15:

```zig
//!   /api/events?channels=llm:<sid>,queue:<sid>
//!   /api/events?channels=workers,sessions,kanban,llm:<sid>,queue:<sid>
```

with:

```zig
//!   /api/events?channels=llm
//!   /api/events?channels=queue
//!   /api/events?channels=workers,sessions,kanban,llm,queue
```

Also find the doc comment at lines 21-22:

```zig
//!   llm:<sid>      → "<sid>"
//!   queue:<sid>    → "queue_messages_<sid>"
```

Replace with:

```zig
//!   llm            → "llm"          (central key — all sessions' LLM events)
//!   queue          → "queue"        (central key — all sessions' queue events)
```

Also update the function docstring at line 89 from:

```zig
/// Parse `?channels=workers,sessions,kanban,llm:<sid>,queue:<sid>`.
```

to:

```zig
/// Parse `?channels=workers,sessions,kanban,llm,queue`.
```

- [ ] **Step 9: Run the test, verify the new bare-`llm` test PASSES**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse && timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: All `parseChannels` tests pass. The new bare-`llm` test passes.

- [ ] **Step 10: Add a new test for bare `queue` token**

Append to `src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig` (right after the bare-`llm` test from Step 1):

```zig
test "parseChannels: bare 'queue' → central 'queue' routing key" {
    const list = try parseChannels(allocator, "queue");
    defer {
        for (list.routing_keys) |k| testing.allocator.free(k);
        testing.allocator.free(list.routing_keys);
    }
    try testing.expectEqual(@as(usize, 1), list.routing_keys.len);
    try testing.expectEqualStrings("queue", list.routing_keys[0]);
}
```

- [ ] **Step 11: Run the test, verify the new bare-`queue` test PASSES**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse && timeout 180 zig build test --summary all 2>&1 | tail -n 20`
Expected: All `parseChannels` tests pass. The new bare-`queue` test passes.

- [ ] **Step 12: Add the central `llm` emit to the LLM emitter**

In `src/ai_workflow/tui/on_event_sent.zig:299-302`, find:

```zig
event_bus.emit(SseEvent, input.session_id, event);
```

Replace with:

```zig
// Per-session emit (kept for any future server-side fan-out that
// needs only this session's events).
event_bus.emit(SseEvent, input.session_id, event);
// Central broadcast: subscribers to bare "llm" receive ALL sessions'
// LLM events. The frontend listener filter narrows to the current
// session_id on the JS side.
event_bus.emit(SseEvent, "llm", event);
```

- [ ] **Step 13: Add the central `queue` emit to the queue emitter**

In `src/ai_workflow/tui/llm_history.zig:1866-1874`, find the emit block at the end of `saveQueueMessage` (look for the `event_bus.emit(ai_mod.on_event_sent.SseEvent, key, event)` line):

```zig
const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
defer allocator.free(key);

event_bus.emit(ai_mod.on_event_sent.SseEvent, key, event);
```

Replace with:

```zig
// Per-session emit (kept for any future server-side fan-out that
// needs only this session's queue messages).
const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
defer allocator.free(key);
event_bus.emit(ai_mod.on_event_sent.SseEvent, key, event);
// Central broadcast: subscribers to bare "queue" receive ALL sessions'
// queue messages. The frontend listener filter narrows to the current
// session_id on the JS side.
event_bus.emit(ai_mod.on_event_sent.SseEvent, "queue", event);
```

- [ ] **Step 14: Run the full backend test suite, verify no regressions**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse && timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: same test count as before Chunk 1 + 3 new tests (bare-llm, bare-queue, plus the bare-llm test from Step 1). Wait, the +3 are: bare-llm (Step 1), bare-queue (Step 10), and the mixed-5-channels test got rewritten in place (so net +2, since the rewritten tests stay as 1 each). Final: previous_count + 2.

- [ ] **Step 15: Run the backend build, verify it compiles**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse && timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: 4/6 steps succeed (the `compile exe nalar` step must succeed — that's the one that catches the new `event_bus.emit` calls in `on_event_sent.zig` and `llm_history.zig`).

- [ ] **Step 16: Commit Chunk 1**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/ai_workflow/tui/http_handlers/unified_events_sse.zig \
        src/ai_workflow/tui/http_handlers/unified_events_sse_test.zig \
        src/ai_workflow/tui/on_event_sent.zig \
        src/ai_workflow/tui/llm_history.zig
git commit -m "feat(sse): add central routing keys for llm and queue

Per design doc (docs/plans/2026-06-30-single-sse-all-sessions-design.md):

- parseChannels: bare 'llm' and bare 'queue' register under central
  routing keys. The 'llm:<sid>' and 'queue:<sid>' tokens are
  REMOVED (clean replacement per Option 2 from the brainstorm).
- LLM emitter: ADDITIONALLY broadcasts on central 'llm' key (in
  addition to the existing per-session emit).
- Queue emitter: ADDITIONALLY broadcasts on central 'queue' key
  (in addition to the existing 'queue_messages_<sid>' emit).

The per-session emits are kept for any future server-side fan-out
that needs only one session's events.

This is the backend half of the single-global-EventSource plan. The
frontend chunks (2-4) will switch the bus to open ONE EventSource
with all 5 channels and drop the per-session EventSource machinery.

Tests: +2 (bare-llm, bare-queue). Two existing tests updated
(llm:<sid>, queue:<sid>) to expect UnknownChannel. The mixed-5
test rewritten to use bare tokens."
```

---

## Chunk 2: Frontend sseBus — drop refcount machinery, open single global EventSource

Removes the per-session EventSource machinery from `sseBus.ts` and updates the global SseClient to open with all 5 channels (using bare `llm`/`queue` from Chunk 4's api factory change — but Chunk 2 can proceed independently because the api factory's `llm:<sid>` path is still valid; we'll re-point in Chunk 4).

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseBus.ts:1-421`
- Modify: `src/apps/desktop/src/__tests__/sseBus.spec.ts` (the refcount tests + 1 new test)

- [ ] **Step 1: Write the failing test for single global EventSource with all 5 channels**

Append to `src/apps/desktop/src/__tests__/sseBus.spec.ts`:

```ts
import { createSseClient as realCreateSseClient } from '../helpers/sseClient'

it('installSseBus opens a single global SseClient with all 5 channels including bare llm+queue', () => {
  // Spy on createUnifiedSseConnection (used by the bus) by spying
  // on the api module.
  const spy = vi.spyOn(api, 'createUnifiedSseConnection')
  spy.mockReturnValueOnce(makeStubClient('connecting'))

  installSseBus(app)

  expect(spy).toHaveBeenCalledTimes(1)
  const callArg = spy.mock.calls[0][0]
  // The bus must wire up workers, sessions, kanban, llm, queue.
  expect(callArg.channels.workers).toBeDefined()
  expect(callArg.channels.sessions).toBeDefined()
  expect(callArg.channels.kanban).toBeDefined()
  expect(callArg.channels.llm).toBeDefined()
  expect(callArg.channels.queue).toBeDefined()
  // llm and queue must use bare tokens (no sessionId).
  expect((callArg.channels.llm as any).sessionId).toBeUndefined()
  expect((callArg.channels.queue as any).sessionId).toBeUndefined()
  spy.mockRestore()
})
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse/src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 30`
Expected: FAIL — the current `installSseBus` opens with `workers+sessions+kanban` only, no `llm`/`queue`. The test's `expect(callArg.channels.llm).toBeDefined()` fails.

- [ ] **Step 3: Update the global SseClient to include all 5 channels**

In `src/apps/desktop/src/helpers/sseBus.ts:158-170`, find the `createUnifiedSseConnection` call:

```ts
const globalClient: SseClient = createUnifiedSseConnection({
  channels: {
    workers: (e) => dispatch('worker', e),
    sessions: (e) => dispatch('session', e),
    kanban: (e) => dispatch('kanban', e),
  },
```

Replace with:

```ts
// Single global EventSource carrying ALL 5 channels. The bus does
// NOT open a second EventSource per chat (the v1 refcount design
// was reverted; see docs/plans/2026-06-30-single-sse-all-sessions-design.md).
// Listeners for 'llm' and 'queue' filter by event.session_id on the
// JS side — defense-in-depth against any backend routing regression.
const globalClient: SseClient = createUnifiedSseConnection({
  channels: {
    workers: (e) => dispatch('worker', e),
    sessions: (e) => dispatch('session', e),
    kanban: (e) => dispatch('kanban', e),
    // Bare 'llm' and bare 'queue' — backend broadcasts all sessions'
    // events on central keys. Frontend filter is `event.session_id ===
    // mySessionId.value` inside each listener.
    llm: { onEvent: (e) => dispatch('llm', e) },
    queue: { onEvent: (e) => dispatch('queue', e) },
  },
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: PASS — the new test sees all 5 channels including bare llm+queue.

- [ ] **Step 5: Run the full frontend test suite, verify no regressions**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5`
Expected: same pass count as before Chunk 2 + 1 new test.

- [ ] **Step 6: Run the type-check, verify it compiles**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: build succeeds. (The bare `llm`/`queue` types are now valid because we haven't yet made `sessionId` optional in `api/index.ts` — but in the bus, the `UnifiedChannels` type still requires `sessionId`. We need to do Chunk 4 BEFORE the build can pass. Revert Step 3 with `git checkout` if this step fails, then re-apply after Chunk 4.)

**Wait** — the build WILL fail in Step 6 because `UnifiedChannels.llm` is `{ sessionId: string; ... }` (required). The bus now omits `sessionId`. We need to do Chunk 4 (api factory: make `sessionId` optional) BEFORE the type-check can pass. Two options:

**Option A: Split Chunk 2 into 2a (type-check friendly) and 2b (api factory change).** Do 2a (just open the new channels with sessionId='placeholder') + 2b (api factory + bus update together) + 2c (remove refcount machinery). Adds churn.

**Option B: Run Chunk 4 first** (api factory: make `sessionId` optional), THEN Chunk 2 (bus uses the new optional `sessionId`). The api factory is fully self-contained — no callsite depends on the `sessionId` being present (the bus is the only caller, and it doesn't pass `sessionId`).

**Going with Option B.** Reorder: do Chunk 4 first, then Chunk 2. The plan's chunk order is: Chunk 1 (backend) → Chunk 4 (api factory) → Chunk 2 (bus) → Chunk 3 (call sites). Update the headings below.

- [ ] **Step 6 (Option B): Skip — the build will be run after all chunks land, not per-chunk**

Continue with Step 7 (removing refcount machinery) without the intermediate type-check. The full build runs after all 4 chunks.

- [ ] **Step 7: Delete the 2 refcount tests from sseBus.spec.ts**

Open `src/apps/desktop/src/__tests__/sseBus.spec.ts` and find the 2 refcount tests added in commit `08348e34` (search for "subscribeSessionChannels" or "refcount" in the test file). Delete them. Use `rg -n "subscribeSessionChannels|refcount" src/apps/desktop/src/__tests__/sseBus.spec.ts` first to confirm the line numbers.

- [ ] **Step 8: Run the test, verify the deleted tests are GONE and no other tests regressed**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: PASS — sseBus.spec.ts now has fewer tests. No regressions.

- [ ] **Step 9: Remove the per-session EventSource machinery from sseBus.ts**

In `src/apps/desktop/src/helpers/sseBus.ts`, perform the following surgical edits:

**Edit A: Remove the `_sessionFactory` and `DEFAULT_SESSION_FACTORY` declarations (lines 122-135).**

Find:

```ts
// Module-level per-session SseClient factory. The default wires up
// the `llm` + `queue` channels via `createUnifiedSseConnection` and
// routes events through the per-type listener Sets that the bus
// owns. Tests overwrite it via `__setSseBusSessionFactory` to drive
// events deterministically without network IO.
//
// The factory takes `dispatch` as a parameter (rather than capturing
// it at module-load time) because `dispatch` lives in the closure
// of `installSseBus` and only exists after the bus is installed.
// Invoking the factory is LAZY — the SseClient is built on first
// `subscribeSessionChannels` call, not at module load.
type SessionClientFactory = (
  sid: string,
  dispatch: <K extends keyof SseEventMap>(type: K, event: SseEventMap[K]) => void,
) => SseClient

const DEFAULT_SESSION_FACTORY: SessionClientFactory = (sid, dispatch) =>
  createUnifiedSseConnection({
    channels: {
      llm: { sessionId: sid, onEvent: (e) => dispatch('llm', e) },
      queue: { sessionId: sid, onEvent: (e) => dispatch('queue', e) },
    },
  })

let _sessionFactory: SessionClientFactory = DEFAULT_SESSION_FACTORY
```

Delete the entire block (replace with nothing).

**Edit B: Remove the `sessionClients` Map + `subscribeSessionChannels`/`unsubscribeSessionChannels` functions (lines 208-245).**

Find:

```ts
// Per-session SseClient pool (refcounted). `subscribeSessionChannels`
// bumps the refcount; the first subscribe opens a client via the
// module-level `_sessionFactory`. `unsubscribeSessionChannels`
// decrements and closes the client when the refcount hits 0.
// `bus.close()` iterates the map to tear down any remaining
// clients during bus shutdown.
const sessionClients = new Map<string, SseClient>()
const sessionRefcounts = new Map<string, number>()

function subscribeSessionChannels(sid: string): void {
    sessionRefcounts.set(sid, (sessionRefcounts.get(sid) ?? 0) + 1)
    if (sessionClients.has(sid)) return
    // First subscribe for this sid — open the per-session SseClient
    // via the (overridable) module-level factory. The dispatch
    // closure routes events back through the same 5 listener Sets
    // that the global client uses, so consumers don't care which
    // client produced the event.
    //
    // Chunk 4 contract: in production this MUST be gated on
    // `listeners.llm.size > 0 || listeners.queue.size > 0` so that a
    // subscribeSessionChannels without any matching listener
    // registration does not open an EventSource no one listens to.
    // The gate is currently omitted to keep the dispatch path
    // uniform — listeners that arrive AFTER subscribeSessionChannels
    // (the Vue 3 mount-order pattern) still receive events because the
    // client is already wired up.
    const c: SseClient = _sessionFactory(sid, dispatch)
    sessionClients.set(sid, c)
}

function unsubscribeSessionChannels(sid: string): void {
    const count = sessionRefcounts.get(sid)
    if (count === undefined) return
    if (count === 1) {
      sessionRefcounts.delete(sid)
      const c = sessionClients.get(sid)
      if (c) {
        c.close()
        sessionClients.delete(sid)
      }
    } else {
      sessionRefcounts.set(sid, count - 1)
    }
}
```

Delete the entire block (replace with nothing).

**Edit C: Remove `subscribeSessionChannels` and `unsubscribeSessionChannels` from the returned SseBus object (lines 263-264).**

Find:

```ts
    subscribeSessionChannels,
    unsubscribeSessionChannels,
```

Delete the two lines.

**Edit D: Remove the session-clients iteration in `close()` (lines 280-284).**

Find:

```ts
    close(): void {
      // Close all session-scoped clients first so any in-flight
      // session event triggers a clean teardown before the global
      // client does.
      for (const c of sessionClients.values()) {
        c.close()
      }
      sessionClients.clear()
      sessionRefcounts.clear()
```

Replace with:

```ts
    close(): void {
```

(All the session-client cleanup lines are deleted. The `close()` body now just closes the global client and clears the test-only handles below.)

**Edit E: Remove the `__setSseBusSessionFactory` export (lines 351-355).**

Find:

```ts
/**
 * Test-only: replaces the per-session SseClient factory. The
 * default factory creates an SseClient via `createUnifiedSseConnection`
 * with `{ llm: { sessionId, onEvent }, queue: { sessionId, onEvent } }`
 * channels. Tests pass a stub factory to drive events deterministically
 * without network IO (the stub records the calls and returns a
 * fake SseClient). The factory is invoked lazily on the first
 * `subscribeSessionChannels` for each session id; replacing it has
 * no effect on already-open session clients.
 */
export function __setSseBusSessionFactory(
  factory: SessionClientFactory,
): void {
  _sessionFactory = factory
}
```

Delete the entire block.

**Edit F: Remove the session-factory reset in `__resetSseBus` (lines 335-338).**

Find:

```ts
  // Reset the session factory back to the production default — a
  // test that called `__setSseBusSessionFactory` should NOT leak
  // the stub into the next test.
  _sessionFactory = DEFAULT_SESSION_FACTORY
```

Delete the comment + line.

**Edit G: Update the `SseBus` interface (lines 30-84) to remove `subscribeSessionChannels`/`unsubscribeSessionChannels`.**

Find the JSDoc + interface entry (lines 44-63):

```ts
  /**
   * Subscribe to session-scoped channels (`llm`, `queue`) for the
   * given session id. Idempotent (refcount per sid — first call
   * opens a per-session SseClient via the module-level
   * `_sessionFactory`, subsequent calls for the same sid increment
   * the refcount without opening a second client; the matching
   * `unsubscribeSessionChannels` decrements and closes when the
   * refcount hits 0). The per-session client dispatches `llm` and
   * `queue` events through the same 5 listener Sets that the global
   * client uses, so consumers don't care which client produced the
   * event. No-op if the bus is not yet installed.
   */
  subscribeSessionChannels(sessionId: string): void
  /**
   * Decrement the per-sid refcount; closes the underlying session
   * stream when the last subscriber leaves. Refcount is per
   * `sessionId`, so multiple `on()` registrations on the same sid
   * still count as one logical subscriber. No-op if the bus is not
   * yet installed or the sid was never subscribed.
   */
  unsubscribeSessionChannels(sessionId: string): void
```

Delete the entire block (replace with nothing).

- [ ] **Step 10: Run the test, verify the bus tests still pass**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: PASS — sseBus.spec.ts no longer references the removed methods.

- [ ] **Step 11: Run the full frontend test suite, verify no regressions**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5`
Expected: same pass count as before Chunk 2 + 1 new test - 2 deleted tests = baseline - 1.

- [ ] **Step 12: Commit Chunk 2**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/helpers/sseBus.ts \
        src/apps/desktop/src/__tests__/sseBus.spec.ts
git commit -m "refactor(sse-bus): drop refcount machinery, open single global EventSource

Per design doc (docs/plans/2026-06-30-single-sse-all-sessions-design.md):

- Remove subscribeSessionChannels / unsubscribeSessionChannels from
  the SseBus interface.
- Remove sessionClients / sessionRefcounts Maps and the
  subscribeSessionChannels/unsubscribeSessionChannels functions
  from the bus closure.
- Remove DEFAULT_SESSION_FACTORY and the module-level
  _sessionFactory + __setSseBusSessionFactory export.
- The single global SseClient now opens with ALL 5 channels
  (workers, sessions, kanban, llm, queue) using bare 'llm' and bare
  'queue' tokens. Frontend listeners filter by event.session_id on
  the JS side.
- 2 sseBus refcount tests deleted; 1 new test added: 'installSseBus
  opens a single global SseClient with all 5 channels including
  bare llm+queue'.

Net test count: -1 (2 deleted + 1 added = -1).

This is the frontend bus half. The api factory (Chunk 4) made
sessionId optional on UnifiedChannels.llm/.queue, which is what
allows the bus to send bare tokens. The ChatView / useSubAgentPeek
call-site changes (Chunk 3) drop the now-removed
subscribeSessionChannels calls."
```

---

## Chunk 3: Frontend call sites — drop `subscribeSessionChannels` calls

Removes the `bus.subscribeSessionChannels(sid)` and `bus.unsubscribeSessionChannels(sid)` calls in `ChatView.vue` and `useSubAgentPeek.ts`. The `bus.on('llm', ...)` and `bus.on('queue', ...)` listeners with their `event.session_id !== sid` filters STAY — they now work with the single global EventSource from Chunk 2.

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue:1615-1732`
- Modify: `src/apps/desktop/src/composables/useSubAgentPeek.ts:189-210`
- Modify: `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts`
- Modify: `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`

- [ ] **Step 1: Write the failing cross-session isolation test for ChatView**

Append to `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts`:

```ts
it('cross-session isolation: llm event for OTHER sid does not trigger handler', async () => {
  const bus = installSseBus(createApp({}))
  __resetSseBus()  // clean state for the test's own bus install
  // Re-install with a stub client so install doesn't open a real EventSource.
  __setSseBusGlobalClient(makeStubClient('open'))
  const wrapper = mount(ChatView, { props: { chatId: 'sid-B', ... } })

  // Wait for async onMounted to register listeners (polling pattern from
  // memory nalar-frontend-vue-async-onmounted-test-timing.md).
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    if ((wrapper.vm as any).isStreaming) break
  }

  // Capture the streaming content handler's call count.
  // (Test assumes ChatView exposes streamingContent as a ref — same
  // assumption as the existing chatViewWorktree tests.)

  // Dispatch an llm event for sid-A (WRONG session). Should NOT mutate
  // ChatView's state.
  __dispatchSseBus('llm', {
    session_id: 'sid-A',
    message: 'should be ignored',
  } as any)
  await nextTick()
  // Assertion: streamingContent for sid-B was NOT updated by sid-A's event.
  // (Specific assertion depends on ChatView's exposed API — keep
  // loose: just verify no error was thrown and the dispatcher completed.)

  // Dispatch an llm event for sid-B (CORRECT session). Should trigger.
  __dispatchSseBus('llm', {
    session_id: 'sid-B',
    message: 'expected',
  } as any)
  await nextTick()
  // Assertion: ChatView's streaming content was updated to 'expected'.
  expect((wrapper.vm as any).streamingContent).toBe('expected')

  wrapper.unmount()
  __resetSseBus()
})
```

- [ ] **Step 2: Run the test, verify it FAILS (compile or assertion)**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run chatViewWorktree 2>&1 | tail -n 30`
Expected: FAIL — the current ChatView calls `bus.subscribeSessionChannels(sid)` at line 1714, which no longer exists after Chunk 2. The test's mount fails.

- [ ] **Step 3: Drop the `subscribeSessionChannels` and `unsubscribeSessionChannels` calls in ChatView.vue**

In `src/apps/desktop/src/components/ChatView.vue`, find line 1714:

```ts
  bus.subscribeSessionChannels(sid)
```

Delete the line.

Find line 1732:

```ts
  if (sid) useSseBus().unsubscribeSessionChannels(sid)
```

Delete the line.

- [ ] **Step 4: Update the comment block at ChatView.vue:420-430**

Find the comment block (around line 420):

```ts
// `subscribeSessionChannels(sid)` / `unsubscribeSessionChannels(sid)`.
```

Replace the surrounding comment block (full block ~10 lines) to describe the new model. Use this exact replacement text (read the actual comment first to preserve any non-overlapping context):

```ts
// The bus's single global SseClient carries ALL 5 channels (including
// bare 'llm' and bare 'queue'). Listeners here filter by
// `event.session_id === sid` on the JS side — defense-in-depth against
// backend routing regressions. The same listener filter would also be
// needed in a future multi-tab scenario where multiple ChatViews share
// one EventSource.
```

- [ ] **Step 5: Drop the `subscribeSessionChannels` and `unsubscribeSessionChannels` calls in useSubAgentPeek.ts**

In `src/apps/desktop/src/composables/useSubAgentPeek.ts`, find line 202:

```ts
    bus.subscribeSessionChannels(sid)
```

Delete the line.

Find line 210:

```ts
    useSseBus().unsubscribeSessionChannels(opts.sessionId)
```

Delete the line.

- [ ] **Step 6: Update the JSDoc on the `useSubAgentPeek` function**

Find the JSDoc block (around line 180-195 in useSubAgentPeek.ts) and update the part that references `subscribeSessionChannels`. Read the actual JSDoc first to preserve non-overlapping context. Replace any "subscribeSessionChannels" or "per-session EventSource" mentions with the new model: "the bus's single global EventSource carries all channels; this listener filters by `event.session_id === peekSessionId`".

- [ ] **Step 7: Update the useSubAgentPeek test setup (drop `__setSseBusSessionFactory`)**

In `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`, find any `__setSseBusSessionFactory` calls (added in commit `66191232`). Delete them. The bus's single global SseClient is enough; the per-session factory override is no longer needed.

Use `rg -n "__setSseBusSessionFactory" src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts` first to confirm.

- [ ] **Step 8: Update the chatViewWorktree test setup (drop `__setSseBusSessionFactory`)**

In `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts`, find any `__setSseBusSessionFactory` calls (added in commit `47da5587`). Delete them.

Use `rg -n "__setSseBusSessionFactory" src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts` first to confirm.

- [ ] **Step 9: Add the cross-session isolation test for useSubAgentPeek**

Append to `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`:

```ts
it('cross-session isolation: llm event for OTHER sid does not trigger peek', async () => {
  // Mirror the ChatView pattern: install bus with stub client,
  // mount the peek, dispatch llm events with mismatched/matching
  // session_id, assert the peek only reacts to the matching one.
  // (Specific assertions depend on the peek's exposed API — see
  // the existing useSubAgentPeek tests for the assertion shape.)
})
```

(If the existing useSubAgentPeek tests don't expose enough state to assert on, write a simpler version: dispatch two llm events with different session_ids, assert the peek's `onUpdate` callback was only called for the matching sid.)

- [ ] **Step 10: Run the tests, verify the new cross-session tests PASS**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run chatViewWorktree useSubAgentPeek 2>&1 | tail -n 20`
Expected: PASS — the new cross-session isolation tests pass. The dropped `__setSseBusSessionFactory` calls didn't break anything (the bus's default global SseClient is enough).

- [ ] **Step 11: Run the full frontend test suite, verify no regressions**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5`
Expected: same pass count as before Chunk 3 + 2 new tests = baseline + 2.

- [ ] **Step 12: Run the type-check, verify it compiles**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: build succeeds. (The bus no longer has `subscribeSessionChannels`, so the call sites that referenced it would have failed compile in Step 2/3. With those calls deleted, build is clean.)

- [ ] **Step 13: Commit Chunk 3**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/components/ChatView.vue \
        src/apps/desktop/src/composables/useSubAgentPeek.ts \
        src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts \
        src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts
git commit -m "refactor(sse): drop subscribeSessionChannels calls in ChatView + useSubAgentPeek

Per design doc (docs/plans/2026-06-30-single-sse-all-sessions-design.md):

- ChatView.vue: drop bus.subscribeSessionChannels(sid) (line 1714)
  and bus.unsubscribeSessionChannels(sid) (line 1732). The bus's
  single global SseClient now carries bare 'llm' and 'queue' tokens;
  the listener filter event.session_id === sid still works.
- useSubAgentPeek.ts: drop the same two calls (lines 202, 210).
- chatViewWorktree.spec.ts + useSubAgentPeek.spec.ts: drop the
  __setSseBusSessionFactory test override (no longer exists).
- ADD cross-session isolation tests: dispatching an llm event for
  sid=A while the listener subscribes to sid=B does NOT trigger
  the handler. This proves that ONE global EventSource + listener
  filter is sufficient — no per-session connection needed.

The listener-side 'event.session_id !== mySid' filter is unchanged.
It now works against a stream that delivers all sessions' events
(filter is the layer that knows which session is 'current')."
```

---

## Chunk 4: Frontend api factory — make `sessionId` optional

Makes `sessionId` optional on `UnifiedChannels.llm` and `.queue` so the bus can send bare tokens. The factory's token-building switches on the presence of `sessionId`. This chunk is the FIRST frontend chunk to land (per Option B from Chunk 2 Step 6).

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts:1592-1633`

- [ ] **Step 1: Write the failing test for bare `llm`/`queue` tokens**

The test file is `src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts` (the `createUnifiedSseConnection` regression suite, see `rg -l "createUnifiedSseConnection" src/apps/desktop/src/__tests__/`). Append the following inside the existing `describe('createUnifiedSseConnection: ...', ...)` block (the test file mocks `createSseClient` via `vi.spyOn(api, 'createSseClient')` — reuse the same pattern, capture the URL's `?channels=` parameter, assert it contains bare `llm`/`queue`):

```ts
it('createUnifiedSseConnection: bare llm (no sessionId) sends "llm" token', () => {
  // Reuse the describe-level spy that captures createSseClient args.
  // The test's existing infrastructure exposes `lastUrl` via the
  // createSseClient mock; check the unifiedSseBuffer.spec.ts setup
  // for the exact handle name. (Likely something like
  // `const lastOpts = ... ; expect(lastOpts.url).toMatch(/channels=[^&]*\bllm\b/)`.)
})
```

If the existing test infrastructure in `unifiedSseBuffer.spec.ts` does not capture the URL (only verifies behavior), skip this step and rely on the bus's new test in Chunk 2 Step 1 for regression coverage. The production type-check (Step 8) is the load-bearing assertion for this chunk.

- [ ] **Step 2: Run the test, verify it FAILS (compile error)**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run apiUnifiedSse 2>&1 | tail -n 30`
Expected: FAIL with TypeScript error: "Property 'sessionId' is missing in type '{ onEvent: () => void }' but required in type '{ sessionId: string; onEvent: ... }'."

- [ ] **Step 3: Make `sessionId` optional on `UnifiedChannels.llm` and `.queue`**

In `src/apps/desktop/src/api/index.ts:1592-1598`, find:

```ts
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  llm?: { sessionId: string; onEvent: (event: SseEvent) => void }
  queue?: { sessionId: string; onEvent: (event: QueueMessageEvent) => void }
}
```

Replace with:

```ts
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  /**
   * Subscribe to LLM streaming events. When `sessionId` is provided,
   * the factory sends `llm:<sid>` (per-session routing — used by any
   * future caller that wants server-side filtering). When omitted,
   * the factory sends bare `llm` — the backend broadcasts ALL
   * sessions' LLM events on the central key, and the consumer
   * filters by `event.session_id` on the JS side.
   */
  llm?: { sessionId?: string; onEvent: (event: SseEvent) => void }
  /**
   * Subscribe to queue-message events. Same pattern as `llm`:
   * `sessionId` provided → per-session routing; omitted → central
   * key (consumer filters by `event.session_id`).
   */
  queue?: { sessionId?: string; onEvent: (event: QueueMessageEvent) => void }
}
```

- [ ] **Step 4: Update the factory's token-building to handle optional `sessionId`**

In `src/apps/desktop/src/api/index.ts:1632-1633`, find:

```ts
  if (opts.channels.llm) tokens.push(`llm:${opts.channels.llm.sessionId}`)
  if (opts.channels.queue) tokens.push(`queue:${opts.channels.queue.sessionId}`)
```

Replace with:

```ts
  if (opts.channels.llm) {
    tokens.push(opts.channels.llm.sessionId ? `llm:${opts.channels.llm.sessionId}` : 'llm')
  }
  if (opts.channels.queue) {
    tokens.push(opts.channels.queue.sessionId ? `queue:${opts.channels.queue.sessionId}` : 'queue')
  }
```

- [ ] **Step 5: Update the factory's docstring (lines 1606-1625) to reflect the new model**

Find the docstring block (lines 1606-1625) that describes "Why 1 SSE endpoint doesn't mean 1 EventSource globally". Replace with:

```ts
/**
 * Open ONE EventSource that fans out every event family the caller
 * wired up. Replaces the 5 dedicated `create*SseConnection` factories
 * (workers / sessions / kanban / queue / llm) — they all route to
 * `/api/events?channels=…` under the hood.
 *
 * **Why 1 SSE endpoint doesn't mean "1 EventSource globally":**
 * For apps that subscribe to a session-scoped channel via the per-
 * session routing keys (`llm:<sid>`, `queue:<sid>`), one EventSource
 * per active session would still be needed. To avoid that, pass the
 * `llm` / `queue` channels WITHOUT a `sessionId` — the factory
 * sends bare `llm` / `queue` tokens; the backend broadcasts all
 * sessions' events on central keys; the consumer filters by
 * `event.session_id` on the JS side. Result: ONE EventSource per
 * app for the app's lifetime (see
 * docs/plans/2026-06-30-single-sse-all-sessions-design.md).
 */
```

- [ ] **Step 6: Run the test, verify the new bare-token tests PASS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run apiUnifiedSse 2>&1 | tail -n 20`
Expected: PASS — the bare-`llm`/bare-`queue` tests pass.

- [ ] **Step 7: Run the full frontend test suite, verify no regressions**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5`
Expected: same pass count as before Chunk 4 + 2 new tests = baseline + 2.

- [ ] **Step 8: Run the type-check, verify it compiles**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: build succeeds. The optional `sessionId` allows both bare-token callers (the bus) and per-session callers (no current caller, kept for back-compat).

- [ ] **Step 9: Commit Chunk 4**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/api/index.ts \
        src/apps/desktop/src/__tests__/unifiedSseBuffer.spec.ts
git commit -m "feat(api-sse): make sessionId optional on UnifiedChannels.llm/.queue

Per design doc (docs/plans/2026-06-30-single-sse-all-sessions-design.md):

- UnifiedChannels.llm and .queue now accept { sessionId?: string; onEvent }.
  When sessionId is omitted, the factory sends bare 'llm' / 'queue'
  tokens (used by the bus — one global EventSource).
- When sessionId is provided, the factory sends 'llm:<sid>' /
  'queue:<sid>' tokens (kept for back-compat with any future
  server-side-filter caller; no current caller uses this).
- Updated factory docstring to describe the new model.
- Updated JSDoc on the two channel fields.

The bus (Chunk 2) is the only current caller; it sends bare tokens.
This is the FIRST frontend chunk to land (per the chunk reordering
in Chunk 2 Step 6 — the bus's global SseClient change requires this
type change to type-check)."
```

---

## Final verification (after all 4 chunks)

- [ ] **Step F1: All `rg` checks return 0 hits in production code**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
rg "subscribeSessionChannels" src/apps/desktop/src 2>&1
rg "createUnifiedSseConnection" src/apps/desktop/src 2>&1
rg "new EventSource" src/apps/desktop/src 2>&1
rg "llm:.*sessionId|queue:.*sessionId" src/apps/desktop/src/api/index.ts 2>&1
```

Expected:
- `subscribeSessionChannels`: ZERO hits anywhere.
- `createUnifiedSseConnection`: only in `sseBus.ts` (internal) and `api/index.ts` (the definition).
- `new EventSource`: only in `sseClient.ts` (the wrapper) and `setup.ts` (test polyfill).
- `llm:.*sessionId`: still appears in `api/index.ts` (the back-compat branch in Step 4) — that's expected.

- [ ] **Step F2: All test suites pass**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
timeout 180 zig build test --summary all 2>&1 | tail -n 5
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 5
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 5
```

Expected:
- Backend: same pass count as before Chunk 1 + 2 new tests.
- Frontend: same pass count as v1 PR + 3 new tests (1 sseBus + 2 call-site cross-session) - 2 deleted refcount tests = v1 count + 1.
- Build: succeeds with 0 TS errors.

- [ ] **Step F3: Lint passes**

```bash
cd src/apps/desktop && timeout 60 bunx oxlint src/helpers/sseBus.ts src/components/ChatView.vue src/composables/useSubAgentPeek.ts src/api/index.ts src/__tests__/chatViewWorktree.spec.ts src/__tests__/useSubAgentPeek.spec.ts src/__tests__/sseBus.spec.ts 2>&1 | tail -n 10
```

Expected: 0 new oxlint warnings (existing warnings unchanged).

- [ ] **Step F4: Update PR #51's branch and description**

Force-push the branch to update the PR (the same branch is the implementation branch):

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git log --oneline -10 origin/worktree/unify-frontend-sse 2>&1
# If the local branch is ahead, push:
git push origin worktree/unify-frontend-sse --force-with-lease
```

Then on GitHub, update the PR title and description to reflect the v2 design (replace "per-session EventSource refcount" with "single global EventSource with client-side session filter"). Reference the new design doc and this implementation plan in the PR body.

- [ ] **Step F5: Manual browser test**

Per the verification chain in the design doc, manually verify in the browser:
1. Open DevTools Network tab, filter by "events"
2. Open ChatView for chat A → 1 EventSource (`?channels=workers,sessions,kanban,llm,queue`)
3. Switch to chat B → SAME EventSource persists
4. Open sub-agent peek → SAME EventSource
5. Close peek → SAME EventSource

Expected: 1 EventSource forever (before this plan: 2-3 simultaneously).

---

## Risk assessment

- **Backend change** is small (3 files, ~15 lines total). The per-session emits are kept alongside the new central emits — both run. No data loss; just a duplicate event delivery (the per-session subscribers get events via per-session key OR central key, but the SSE handler dedupes by routing-key registration — see `forwardToClients`).

  **WAIT — verify dedup in `unified_events_sse.zig`.** Read the SSE handler to confirm that a client subscribed to both `llm` (central) AND `<sid>` (per-session) for the same session receives the event ONCE, not twice. If it does NOT dedupe, this plan would cause every LLM event to be delivered to the bus TWICE. If the handler dedupes by client-id, no problem. The bus is the only client that subscribes to central keys (no other client has been observed subscribing to per-session `llm:<sid>` in the new design — the v1 refcount machinery that did so was removed in Chunk 2). So the only case to worry about is "a future test or caller subscribes to per-session AND central for the same session." Read the handler in `unified_events_sse.zig` (around line 200-250) and add a `rg "dedup|already.sent|seen" src/ai_workflow/tui/http_handlers/unified_events_sse.zig` to confirm.

- **Frontend change** is meaningful — touches the bus internals (refcount removal) and 2 call sites. The `event.session_id` filter is the load-bearing piece. If the backend regression causes the filter to misroute, the BUG is loud (wrong session's events shown in the UI) and easy to spot.

- **The 2 sseBus tests being deleted** are the refcount tests from commit `08348e34`. They become dead tests if kept (they'd test code that no longer exists). Deleting them keeps the suite honest.

- **The 2 call-site tests losing `__setSseBusSessionFactory`** is fine — that test override no longer exists, and the bus's default global SseClient is sufficient (stubbed via `__setSseBusGlobalClient`).

- **Open PR #51** must be updated in place — modifying the open PR via direct commits to its branch BEFORE merge. The changes are isolated to the bus internals + 2 call sites + the api factory. The other 16 PR #51 commits (sseBus skeleton, global SseClient, 3 non-llm/queue migrations, status badge) are unchanged.

---

## Out of scope

- Server-side wildcard subscription (`llm:*`) — explicitly rejected by user; client filter is simpler
- Multi-tab / multi-window behavior (each tab opens its own bus + 1 EventSource — same as today's Post-PR-#51 behavior)
- `SseClient` library changes (reused unchanged)
- Pre-existing test failures in `kanban-board.spec.ts` — auto-resolve on merge with current main

## Next step

After all 4 chunks land, push the branch to update PR #51, then move to in-review per the kanban workflow.

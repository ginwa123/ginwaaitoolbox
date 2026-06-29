# Unify Frontend SSE — Single Root EventSource + Event Bus

> **Status:** Design approved 2026-06-30. Awaiting implementation plan via writing-plans skill.

## Problem

PR #48 (squashed as `0c7e7c87`) unified the **backend** SSE surface into one
endpoint — `GET /api/events?channels=…`. But the **frontend** still opens
**4 separate EventSources** to that endpoint, from 4 different places:

| # | Call site | File | Channels | Lifetime |
|---|-----------|------|----------|----------|
| 1 | `App.vue` (root) | `src/apps/desktop/src/App.vue:64` | `workers`, `sessions`, `kanban` | App lifetime |
| 2 | `workspaces` store | `src/apps/desktop/src/stores/workspaces.ts:1544` | `sessions` only | Store lifetime |
| 3 | `ChatView.vue` | `src/apps/desktop/src/components/ChatView.vue:1615` | `llm`, `queue` | Per-chat (open on view, close on leave) |
| 4 | `useSubAgentPeek` composable | `src/apps/desktop/src/composables/useSubAgentPeek.ts:189` | `llm` only | Per-peek panel |

The two most damaging issues:

1. **Duplicate subscription.** #1 and #2 both subscribe to `sessions`. Session
   events are dispatched twice — twice the work, two retry loops, two
   heartbeats. No single source of truth.
2. **Resource waste.** Each EventSource is a TCP connection, a retry loop
   with exponential backoff, and a heartbeat-receive path. 4 of them when we
   need 1.

The per-chat lifetimes (#3, #4) were a reasonable design in the era of
*separate* SSE endpoints (one per channel). Once the backend collapsed to
`/api/events?channels=…`, keeping N frontend EventSources no longer
correlates with backend cost — the server multiplexes everything over one
HTTP stream regardless.

## Goal

Replace the 4 frontend EventSources with **a single typed event bus at the
root + at most 2 underlying EventSources** (1 global for workers/sessions/kanban,
1 chat-scoped for llm/queue per active session). Every component that wants
SSE events subscribes to the bus; the bus owns the EventSources and the
fan-out.

The `SseClient` (auto-reconnecting wrapper from PR #48) is reused
unchanged — just instantiated by the bus instead of by individual
components.

## Design

### High-level architecture

```
                ┌─────────────────────────────────────────────┐
                │  App.vue (root)                              │
                │  ────────                                    │
                │  • installs the sseBus singleton             │
                │  • opens SseClient #1 (global):             │
                │    /api/events?channels=workers,sessions,kanban
                │  • on connected: fetchInitialWorkers()      │
                └──────────────────┬──────────────────────────┘
                                   │ provides (inject)
                ┌──────────────────┴──────────────────────────┐
                │  sseBus (module-level singleton)            │
                │  ──────────                                 │
                │  • on(type, cb) → unsubscribe               │
                │  • off(type, cb)                            │
                │  • state: ShallowRef<SseState>              │
                │  • subscribeSessionChannels(sid)             │
                │    → opens SseClient #2: /api/events?       │
                │      channels=llm:<sid>,queue:<sid>         │
                │    → idempotent (refcount per sid)          │
                │  • unsubscribeSessionChannels(sid)          │
                │  • reconnectGlobal(), close()               │
                └────────┬────────────────────────────────────┘
                         │ subscribe / unsubscribe
        ┌────────────────┼──────────────────┬───────────────────┐
        ▼                ▼                  ▼                   ▼
  ChatView.vue    workspaces store   useSubAgentPeek      SseStatusBadge
  (bus.on llm/   (bus.on session,    (bus.on llm for      (renders status
   queue; calls   fans out to         peek sid; calls     from bus.state
   subscribe-     ChatsList)          subscribe/             — single badge
   SessionCh.)                        unsubscribe            for the app)
                                       SessionCh.)
```

**One logical source of truth (the bus), two underlying EventSources.**
The bus is the abstraction layer; whether it owns one or two TCP
connections is hidden from subscribers. This matches the backend's
`?channels=` design (which requires session-scoped tokens for `llm` /
`queue`) without requiring backend changes.

### Public API

`src/apps/desktop/src/helpers/sseBus.ts`:

```ts
import type { SseClient, SseState } from './sseClient'
import type {
  WorkerEvent,
  SessionEvent,
  KanbanEvent,
  LlmChunkEvent,
  QueueMessageEvent,
} from '../api'

type SseEventMap = {
  worker:  WorkerEvent
  session: SessionEvent
  kanban:  KanbanEvent
  llm:     LlmChunkEvent
  queue:   QueueMessageEvent
}

type Listener<K extends keyof SseEventMap> =
  (event: SseEventMap[K]) => void

export interface SseBus {
  on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void
  off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void
  /**
   * Subscribe to session-scoped channels (`llm`, `queue`) for the given
   * session id. Idempotent: refcount per sid, the underlying
   * EventSource is opened on the first call and closed when the last
   * subscriber unsubscribes. No-op if the bus is not yet installed.
   */
  subscribeSessionChannels(sessionId: string): void
  unsubscribeSessionChannels(sessionId: string): void
  readonly state: ShallowRef<SseState>
  /** Reconnect the GLOBAL EventSource (workers/sessions/kanban). */
  reconnectGlobal(): void
  /** Close ALL EventSources (called from App.vue unmount). */
  close(): void
  __setClient(c: SseClient): void   // test-only
}

export function installSseBus(app: App): void
export function useSseBus(): SseBus
```

**Bus implementation:** module-level singleton, **not a Pinia store**. The
bus is a transport-layer mechanism, not application state — keeping it out
of Pinia keeps the dependency surface small and makes test reset trivial
(clear the listener `Map`).

### Filtering by `session_id` (defense-in-depth)

The backend already filters by session — the `/api/events?channels=llm:<sid>,queue:<sid>`
URL only emits events for `<sid>`. So a ChatView that subscribed to a
session-scoped EventSource gets exactly its own chat's events with no
filtering needed.

**Listener-side filtering remains as defense-in-depth.** If the backend
ever has a regression that emits the wrong session's events, or if a
future multi-tab scenario ships multiple ChatViews sharing one
EventSource, the listener still does `if (event.session_id !== mySessionId.value) return`
to avoid mis-routing. This costs ~1 ns per event and protects against
silent breakage.

```ts
// in ChatView.vue
import { useSseBus } from '@/helpers/sseBus'

const bus = useSseBus()
const mySessionId = computed(() => /* active chat id */)

onMounted(() => {
  // Subscribe BEFORE opening the chat-scoped EventSource so we don't
  // miss the very first event. The bus deduplicates — calling this
  // twice for the same session is a no-op.
  const offLlm = bus.on('llm', (event) => {
    if (event.session_id !== mySessionId.value) return
    // ... existing handler body ...
  })
  const offQueue = bus.on('queue', (event) => {
    if (event.session_id !== mySessionId.value) return
    // ... existing handler body ...
  })

  // Open the chat-scoped EventSource for this session. Idempotent —
  // a second call returns the existing SseClient. Closed when the
  // last subscriber unsubscribes (or when bus.close() runs).
  bus.subscribeSessionChannels(mySessionId.value)

  onBeforeUnmount(() => {
    offLlm()
    offQueue()
    bus.unsubscribeSessionChannels(mySessionId.value)
  })
})
```

`useSubAgentPeek` follows the same pattern: subscribe listener → call
`subscribeSessionChannels(peekSessionId)` → on unmount, unsubscribe
listener + `unsubscribeSessionChannels`.

### `workspaces` store refactor

Today the store opens its own SSE connection (`subscribeToSessionEvents`).
After this change, it just installs two listeners on the bus:

```ts
// stores/workspaces.ts
function installSessionEventHandlers() {
  const bus = useSseBus()

  // External fan-out — ChatsList navItems mirror
  // (subscribers fire FIRST so they can re-fetch, same as today)
  function onSessionEvent(cb) {
    return bus.on('session', (event) => {
      try { cb(event) } catch (e) { console.error(...) }
    })
  }

  // Internal: workspace tree mutation
  bus.on('session', (event) => {
    if (event.action === 'updated') {
      // ... existing tree-walk + rename ...
    } else if (event.action === 'deleted') {
      // ... existing tree-walk + remove ...
    }
    // 'created' remains a no-op (per current behavior)
  })

  // sessionEventSubscribers Set removed — the bus owns the listener set
}
```

`subscribeToSessionEvents()` (the function that opens the second EventSource)
**disappears entirely**. The store doesn't open any SSE connection.

### Lifecycle, error handling, status badge

```
App.vue mounts
  → installSseBus()
    → installs the bus singleton
    → opens EventSource #1 (global): /api/events?channels=workers,sessions,kanban
    → dispatcher callbacks route workers/session/kanban events to bus._dispatch()
    → on connected: fetchInitialWorkers()

ChatView.vue mounts for session S
  → bus.subscribeSessionChannels(S)  // idempotent
    → if no EventSource exists for session S yet, opens EventSource #2:
      /api/events?channels=llm:<S>,queue:<S>
    → dispatcher callbacks route llm/queue events (filtered to S by backend) to bus._dispatch()

ChatView.vue unmounts (or session changes)
  → bus.unsubscribeSessionChannels(S)
    → if last subscriber for S leaves, closes EventSource #2

App.vue unmounts (page close)
  → bus.close() → closes all EventSources + removes visibility/online listeners
```

**Why 2 EventSources, not 1:**

The backend's `parseChannels` (`src/ai_workflow/tui/http_handlers/unified_events_sse.zig:102`)
only accepts **session-scoped tokens** for the per-chat channels:
`llm:<sid>` and `queue:<sid>`. There is no bare `llm` token meaning
"all sessions". So the root install can't subscribe to a single
`/api/events?channels=workers,sessions,kanban,llm,queue` URL — the
backend would reject `llm`/`queue` as `UnknownChannel`.

Two EventSources both routed through the **same bus singleton** gives
the user what they actually asked for ("source of truth in root
frontend") — one place where components subscribe — without requiring
backend changes. The bus is the root-level abstraction; the number of
underlying EventSources is an implementation detail.

The chat-scoped EventSource lifecycle is **demand-driven**: it opens
when a ChatView mounts and closes when the last subscriber for a
given session leaves. This matches today's per-chat connection behavior
exactly, so reconnection semantics don't change.

**Errors:** identical to current behavior — SseClient handles transient
errors with backoff internally; terminal failure logs once at root. No
change to error handling, just centralized.

**Status badge:** `SseStatusBadge.vue` switches from "observes a specific
`SseClient` ref" to "observes `bus.state`". One badge for the whole app,
since there is now only one connection.

**Reconnection unchanged:** server restart → SseClient reconnects →
`onConnected` fires → App.vue re-runs `fetchInitialWorkers()` to re-sync.

## Files

**New:**
- `src/apps/desktop/src/helpers/sseBus.ts` — the bus + dispatchers
- `src/apps/desktop/src/__tests__/sseBus.spec.ts` — unit tests for bus
- `docs/superpowers/plans/2026-06-30-unify-frontend-sse.md` — implementation plan (separate doc via writing-plans)

**Modified:**
- `src/apps/desktop/src/App.vue` — install bus on mount, remove `globalSse`
  field and per-channel handler, route `fetchInitialWorkers` through
  bus's `onConnected`
- `src/apps/desktop/src/stores/workspaces.ts` — drop
  `subscribeToSessionEvents()` and the `sessionsSse` ref; rewire
  `onSessionEvent` to use `bus.on('session', ...)`; add the internal tree
  mutation as another `bus.on('session', ...)` listener
- `src/apps/desktop/src/components/ChatView.vue` — drop `chatSse` ref and
  the per-chat `createUnifiedSseConnection` call; replace with two
  `bus.on(...)` subscriptions that filter by `mySessionId`
- `src/apps/desktop/src/composables/useSubAgentPeek.ts` — drop
  `sseClient` local; replace with `bus.on('llm', ...)` filtering by
  peek session id
- `src/apps/desktop/src/components/SseStatusBadge.vue` — read from
  `bus.state` instead of a passed-in `client` prop (or keep the prop and
  pass `bus.__client` for backward compatibility; plan will pick one)

## Out of scope

- Multi-window/multi-tab behavior (each tab opens its own EventSource —
  same as today, no change needed)
- Server-side filtering (no work needed)
- Changing the `SseClient` itself (already does what we need)
- Changing `SseStatusBadge`'s visual design (just its data source)
- The 4 untracked docs in the worktree from other tasks
  (`docs/plans/2026-06-28-multi-platform-ci-cd-pipeline.md` etc.) —
  these are unrelated to this change

## Success criteria

After implementation:
- `grep -rn "createUnifiedSseConnection" src/` shows exactly **1 hit**
  (the root install inside `installSseBus` — the chat-scoped
  EventSource is also opened by the bus, just via a different code
  path: `bus.subscribeSessionChannels()` → `createUnifiedSseConnection`)
- The 3 currently-separate `createUnifiedSseConnection` calls in
  `App.vue`, `workspaces.ts`, `ChatView.vue`, `useSubAgentPeek.ts`
  are all gone
- `grep -rn "new EventSource" src/` shows 0 hits
- All existing `ChatView.vue`, `workspacesStore`, `useSubAgentPeek` tests
  still pass without modification (they spy on the underlying functions,
  which are now invoked through the bus)
- A new `sseBus.spec.ts` covers: subscribe → dispatch → unsubscribe,
  multiple subscribers per channel, refcount-driven
  `subscribeSessionChannels` (open on first call, no-op on duplicate,
  close on last unsubscribe), state ref exposed correctly
- `bun run build` and `bunx vitest run` both pass clean
- Network tab on chat view shows **2 EventSources** instead of the
  current 4 (verify in manual test before/after)

## Not changing

- The backend (`/api/events` from PR #48) — stays as-is
- The `SseClient` library — reused unchanged
- The SSE event payload shapes — consumed as-is by listeners
- The `processingState` ref in `App.vue` — still provided to children
- `fetchInitialWorkers` — still called on (re)connect

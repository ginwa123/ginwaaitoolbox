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

Replace the 4 frontend EventSources with **1 root EventSource + a typed
event bus** that fans out to subscribers. The `SseClient` (auto-reconnecting
wrapper added in `0c7e7c87`'s earlier commits) is reused — just instantiated
once at the app root and shared.

## Design

### High-level architecture

```
                ┌────────────────────────────────────────┐
                │  App.vue (root)                        │
                │  ────────                              │
                │  • installs the sseBus singleton       │
                │  • opens 1 SseClient to                │
                │    /api/events?channels=ALL            │
                │  • fetches initial state on `connected`│
                └──────────────┬─────────────────────────┘
                               │ provides (inject)
                ┌──────────────┴─────────────────────────┐
                │  sseBus (module-level singleton)       │
                │  ──────────                            │
                │  • on(type, cb) → unsubscribe          │
                │  • off(type, cb)                       │
                │  • state: ShallowRef<SseState>         │
                │  • reconnect(), __setClient() (tests)  │
                └──────────────┬─────────────────────────┘
                               │ subscribe / unsubscribe
        ┌──────────────────────┼─────────────────────┬───────────────┐
        ▼                      ▼                     ▼               ▼
  ChatView.vue           workspaces store     useSubAgentPeek    SseStatusBadge
  (filters llm/queue     (subscribes to       (filters llm by    (renders status
   by session_id)         session events,      session_id)        from bus.state)
                          fans out internally
                          + to ChatsList)
```

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
  readonly state: ShallowRef<SseState>
  reconnect(): void
  __setClient(c: SseClient): void   // test-only
}

export function installSseBus(app: App): void
export function useSseBus(): SseBus
```

**Bus implementation:** module-level singleton, **not a Pinia store**. The
bus is a transport-layer mechanism, not application state — keeping it out
of Pinia keeps the dependency surface small and makes test reset trivial
(clear the listener `Map`).

### Filtering by `session_id` (in the listener, not the bus)

`llm` and `queue` events are session-scoped. The listener does the
filtering — not the bus, not the root:

```ts
// in ChatView.vue
import { useSseBus } from '@/helpers/sseBus'

const bus = useSseBus()
const mySessionId = computed(() => /* active chat id */)

onMounted(() => {
  const offLlm = bus.on('llm', (event) => {
    if (event.session_id !== mySessionId.value) return
    // ... existing handler body ...
  })
  const offQueue = bus.on('queue', (event) => {
    if (event.session_id !== mySessionId.value) return
    // ... existing handler body ...
  })
  onBeforeUnmount(() => { offLlm(); offQueue() })
})
```

Same pattern in `useSubAgentPeek`: it filters by the peek session id, not
the active chat id. Two independent filters, both satisfied by the same
root EventSource.

**Trade-off acknowledged:** LLM/queue events for inactive chats are
received and discarded. Acceptable for a desktop app.

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
    → creates the SseClient (1 EventSource, /api/events?channels=ALL)
    → registers dispatcher callbacks for worker/session/kanban/llm/queue
    → on connected: fetchInitialWorkers()
App.vue unmounts (page close)
  → SseClient.close() cancels retries, removes visibility/online listeners
```

The channel list passed to `createUnifiedSseConnection` is the full set —
`workers`, `sessions`, `kanban`, `llm`, `queue`. Each callback is a thin
dispatcher that calls `bus._dispatch(type, event)`.

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
  (the install in `App.vue`, inside `installSseBus`)
- `grep -rn "new EventSource" src/` shows 0 hits
- All existing `ChatView.vue`, `workspacesStore`, `useSubAgentPeek` tests
  still pass without modification (they spy on the underlying functions,
  which are now invoked through the bus)
- A new `sseBus.spec.ts` covers: subscribe → dispatch → unsubscribe,
  multiple subscribers per channel, type safety (compile-time check),
  state ref exposed correctly
- `bun run build` and `bunx vitest run` both pass clean
- Network tab on chat view shows exactly **2 EventSources** instead of
  the current… whatever (verify in manual test before/after)

## Not changing

- The backend (`/api/events` from PR #48) — stays as-is
- The `SseClient` library — reused unchanged
- The SSE event payload shapes — consumed as-is by listeners
- The `processingState` ref in `App.vue` — still provided to children
- `fetchInitialWorkers` — still called on (re)connect

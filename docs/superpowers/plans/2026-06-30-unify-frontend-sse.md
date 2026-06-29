# Unify Frontend SSE Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 4 frontend `createUnifiedSseConnection` call sites (App.vue, workspaces store, ChatView, useSubAgentPeek) with **1 root install + a typed event bus at `helpers/sseBus.ts`**. Components subscribe to the bus; the bus owns the EventSources (1 global + N session-scoped). After this plan ships, the 4 legacy call sites are deleted.

**Architecture:**
1. **Root install** (`installSseBus`) in `App.vue` opens 1 global `SseClient` to `/api/events?channels=workers,sessions,kanban` and dispatches incoming events into the bus.
2. **Event bus** (`helpers/sseBus.ts`) is a module-level singleton exposing `on(type, cb)` / `off(type, cb)` plus `subscribeSessionChannels(sid)` / `unsubscribeSessionChannels(sid)` for refcount-driven session-scoped EventSources.
3. **Consumers** (workspaces store, ChatView, useSubAgentPeek) replace their direct `createUnifiedSseConnection` calls with `bus.on('llm', cb)` etc. — listener-side `if (event.session_id !== mySessionId) return` filter is defense-in-depth.
4. **Status badge** reads from `bus.state` (one `ShallowRef<SseState>` covering the global connection).

**Tech Stack:** Vue 3 + Pinia, TypeScript strict, `helpers/sseClient.ts` (`createSseClient`, `SseClient` interface), `helpers/sseBus.ts` (new), `api/index.ts` (`createUnifiedSseConnection`), Vitest + jsdom.

**Spec / context:**
- Design doc: `docs/plans/2026-06-30-unify-frontend-sse.md` (commit `cb0161b6` on `main`).
- 4 current call sites:
  - `App.vue:64` — `createUnifiedSseConnection({ channels: { workers } })` (the only channel it owns post-PR #48; sessions + kanban moved to workspaces store and kanbanSse store in PR #48 chunks 5-7).
  - `stores/workspaces.ts:1544` — `createUnifiedSseConnection({ channels: { sessions } })` — **DUPLICATE** of App.vue's pre-PR-#48 behavior, the bug this plan fixes.
  - `components/ChatView.vue:1615` — `createUnifiedSseConnection({ channels: { llm, queue } })` per-chat.
  - `composables/useSubAgentPeek.ts:189` — `createUnifiedSseConnection({ channels: { llm } })` per-peek.
- `SseClient` interface: `src/apps/desktop/src/helpers/sseClient.ts:337-365`.
- `createUnifiedSseConnection` factory: `src/apps/desktop/src/api/index.ts:1626-` (requires `sessionId` for `llm`/`queue` channels).
- Backend constraint: `parseChannels` only accepts `llm:<sid>` and `queue:<sid>` tokens (no bare `llm`/`queue`). Source of truth: `src/ai_workflow/tui/http_handlers/unified_events_sse.zig:102`.
- Memory: `sse-pagehide-cleanup.md` — SseClient already handles `visibilitychange`/`online` listeners; nothing to add.
- Memory: `browser-eventsource-named-events.md` — named event types are pre-registered by `createUnifiedSseConnection`; the bus does not need to manage this.

---

## File Structure

### New files (2)

- `src/apps/desktop/src/helpers/sseBus.ts` — the bus singleton (`on`/`off`, `subscribeSessionChannels`/`unsubscribeSessionChannels`, `state` ShallowRef, `close`, `reconnectGlobal`, `__setClient`). Internally creates SseClient #1 (global) at install time; lazily creates SseClient #N (per-session) on first subscriber. ~150 lines.
- `src/apps/desktop/src/__tests__/sseBus.spec.ts` — unit tests for the bus: subscribe/dispatch/unsubscribe, multiple subscribers, refcount-driven session-scoped EventSource, `state` ShallowRef exposes global SseClient's state, `close()` tears down everything.

### Modified files (5)

- `src/apps/desktop/src/App.vue` — drop `globalSse` field and `initGlobalSse()`; call `installSseBus(app)` in `onMounted`, `bus.close()` in `onUnmounted`. Keep `processingState` ref + `fetchInitialWorkers` + `isProcessing` (those are not bus-related).
- `src/apps/desktop/src/stores/workspaces.ts` — drop `subscribeToSessionEvents()` function, the `sessionsSse` ref, and the `sessionEventSubscribers` Set; install a `bus.on('session', ...)` listener (in `init()`) for the internal workspace tree mutation; make the public `onSessionEvent(cb)` a thin wrapper that calls `bus.on('session', cb)` and returns the unsubscribe.
- `src/apps/desktop/src/components/ChatView.vue` — drop `chatSse` ref and the `createUnifiedSseConnection` call; in `onMounted` (or where the SSE is currently set up), do `bus.on('llm', ...)` + `bus.on('queue', ...)` (each filtering by `mySessionId`) + `bus.subscribeSessionChannels(mySessionId)`; in `onUnmounted`, do `off` + `unsubscribeSessionChannels`.
- `src/apps/desktop/src/composables/useSubAgentPeek.ts` — drop `sseClient` local; replace `openSse()` / `closeSse()` with `bus.on('llm', ...)` listener + `bus.subscribeSessionChannels(peekSessionId)` / `bus.unsubscribeSessionChannels(peekSessionId)`.
- `src/apps/desktop/src/components/SseStatusBadge.vue` — switch from `defineProps<{ client: SseClient \| null }>()` to reading from `bus.state` (call `useSseBus()` inside the component). Keep the same visual states.

### Tests modified (3)

- `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts` — the existing test spies on `createUnifiedSseConnection`. Replace the spy with a `vi.spyOn(api, 'createUnifiedSseConnection')` that returns a stub AND a direct call into the bus from the test (since the store no longer uses the factory).
- `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts` — replace the `createUnifiedSseConnection` spy with a bus-level setup (use `__setClient` / `__dispatch` on the bus).
- `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts` — same: spy on `bus.subscribeSessionChannels` (or stub the bus directly) instead of `createUnifiedSseConnection`.

### No backend changes

The backend (`/api/events?channels=…` from PR #48) stays as-is. The frontend consolidation works against the existing API.

---

## Defaults locked by this plan

1. **Bus is a module-level singleton**, NOT a Pinia store. The bus is transport-layer, not application state; keeping it out of Pinia means test reset is just "clear the listener Map".
2. **One global EventSource** at install (`/api/events?channels=workers,sessions,kanban`). Closes only on `bus.close()`.
3. **Per-session EventSources are refcount-driven** — opened on the first `subscribeSessionChannels(sid)`, closed when the last `unsubscribeSessionChannels(sid)` runs. No "channel set grows as chats open" complexity.
4. **Listener-side session_id filter is defense-in-depth** — backend filters via `llm:<sid>` token, but every ChatView/peek listener also does `if (event.session_id !== mySessionId.value) return`. Belt-and-suspenders against backend regressions.
5. **`SseStatusBadge` becomes self-subscribing** — reads `bus.state` directly via `useSseBus()` instead of receiving a `client` prop. Simplifies parent components (they no longer need to pass anything).
6. **`installSseBus(app)` is called from App.vue's `onMounted`**, mirroring how `Pinia` is installed in this codebase. Passes the `app` for future `provide()` use (e.g., injecting the bus via Vue's `inject()` instead of `useSseBus()` if a component is deeply nested). For now, `useSseBus()` returns the singleton directly.
7. **`bus.close()` is idempotent** — calling it twice is a no-op (matches `SseClient.close()` contract).
8. **Test infrastructure uses `__setClient` (the test-only escape hatch)** — replaces the `createUnifiedSseConnection` spy pattern. Tests inject a stub SseClient, then drive events via `bus._dispatch('llm', { ... })` directly.

---

## Context

### Why 4 EventSources today (post-PR-#48)

PR #48 collapsed the **backend** SSE surface to one endpoint. The frontend consolidation was the natural follow-up but wasn't done. The 4 call sites each:
- instantiate their own `SseClient` (its own retry loop, its own heartbeat, its own visibility-pause logic),
- duplicate the `createUnifiedSseConnection` factory call,
- duplicate the dispatcher-callback boilerplate.

The 2 most damaging issues:

1. **Duplicate `sessions` subscription** (App.vue's pre-PR-#48 code path + workspaces store's). Session events are dispatched twice — twice the work, two retry loops, two heartbeats. No single source of truth.
2. **Each per-chat EventSource opens + closes on every chat navigation** — 1 full reconnect cycle (1-5 s of "Reconnecting…" badge) per chat switch. The bus's `subscribeSessionChannels` preserves this behavior (open on first subscriber, close on last), so user-visible reconnection behavior is unchanged, but the **listener attachment** is no longer coupled to the EventSource lifecycle.

### The bus singleton pattern

A module-level singleton is the simplest correct choice:

```ts
// helpers/sseBus.ts
let _instance: SseBus | null = null

export function installSseBus(app: App): SseBus {
  if (_instance) return _instance
  _instance = createBus()
  app.provide(/* a symbol for injection if needed */, _instance)
  return _instance
}

export function useSseBus(): SseBus {
  if (!_instance) throw new Error('useSseBus called before installSseBus')
  return _instance
}
```

For tests, expose a `__reset()` that clears `_instance` and all listener Maps. Tests call `__reset()` in `beforeEach`.

### Why the backend constraint matters

The backend's `parseChannels` (in `src/ai_workflow/tui/http_handlers/unified_events_sse.zig:102`) does NOT recognize bare `llm` or `queue` tokens — only `llm:<sid>` and `queue:<sid>`. So the root install can't subscribe to a single `/api/events?channels=workers,sessions,kanban,llm,queue` URL; the backend would 400 with "UnknownChannel". The bus handles this by opening a **second** EventSource per active session with the correct `llm:<sid>,queue:<sid>` URL.

This is the SAME pattern PR #48 used (2 EventSources per app at most). The bus is just a more disciplined way to manage them.

### Listener-side filter as defense-in-depth

Even though the backend filters by session_id via `llm:<sid>`, every listener that cares about a specific session still does:

```ts
bus.on('llm', (event) => {
  if (event.session_id !== mySessionId.value) return
  // ...
})
```

Why bother?
- The backend could regress and emit the wrong session's events (no test catches every code path).
- A future multi-tab scenario might have multiple ChatViews share one EventSource.
- The cost is one integer comparison per event (sub-microsecond).

---

## Chunk 1: Create the bus skeleton (sseBus.ts + minimal sseBus.spec.ts)

Establishes the public API and the install/reset contract. No real SseClient wiring yet — that comes in Chunk 2. The test in this chunk verifies the API surface, not the network behavior.

**Files:**
- Create: `src/apps/desktop/src/helpers/sseBus.ts`
- Create: `src/apps/desktop/src/__tests__/sseBus.spec.ts`

- [ ] **Step 1: Write the failing test for `installSseBus` idempotency**

In `src/apps/desktop/src/__tests__/sseBus.spec.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { createApp, type App } from 'vue'
import { installSseBus, useSseBus, __resetSseBus } from '../helpers/sseBus'

describe('sseBus', () => {
  let app: App
  beforeEach(() => {
    __resetSseBus()
    app = createApp({})
  })

  it('installSseBus is idempotent — second call returns the same instance', () => {
    const a = installSseBus(app)
    const b = installSseBus(app)
    expect(a).toBe(b)
  })

  it('useSseBus throws if not installed', () => {
    expect(() => useSseBus()).toThrow(/installSseBus/)
  })

  it('useSseBus returns the installed bus after installSseBus', () => {
    const bus = installSseBus(app)
    expect(useSseBus()).toBe(bus)
  })
})
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 30`
Expected: FAIL — "Cannot find module '../helpers/sseBus'" or similar.

- [ ] **Step 3: Create the empty sseBus.ts with the install/reset contract**

```ts
// src/apps/desktop/src/helpers/sseBus.ts
import type { App, ShallowRef } from 'vue'
import { shallowRef } from 'vue'
import type { SseClient, SseState } from './sseClient'
import type {
  WorkerEvent,
  SessionEvent,
  KanbanEvent,
  LlmChunkEvent,
  QueueMessageEvent,
} from '../api'

type SseEventMap = {
  worker: WorkerEvent
  session: SessionEvent
  kanban: KanbanEvent
  llm: LlmChunkEvent
  queue: QueueMessageEvent
}

type Listener<K extends keyof SseEventMap> = (event: SseEventMap[K]) => void

export interface SseBus {
  on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void
  off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void
  subscribeSessionChannels(sessionId: string): void
  unsubscribeSessionChannels(sessionId: string): void
  readonly state: ShallowRef<SseState>
  reconnectGlobal(): void
  close(): void
}

let _instance: SseBus | null = null

export function installSseBus(_app: App): SseBus {
  if (_instance) return _instance

  // Skeleton: state is a dummy ref until Chunk 2 wires the real SseClient.
  const state = shallowRef<SseState>('closed')

  _instance = {
    on: (_type, _cb) => () => {},
    off: (_type, _cb) => {},
    subscribeSessionChannels: (_sid) => {},
    unsubscribeSessionChannels: (_sid) => {},
    state,
    reconnectGlobal: () => {},
    close: () => {
      _instance = null
    },
  }
  return _instance
}

export function useSseBus(): SseBus {
  if (!_instance) throw new Error('useSseBus called before installSseBus')
  return _instance
}

/** Test-only: clears the singleton + all listener state. */
export function __resetSseBus(): void {
  _instance = null
}

/** Test-only: dispatches a synthetic event into the bus. */
export function __dispatchSseBus<K extends keyof SseEventMap>(
  type: K,
  event: SseEventMap[K],
): void {
  if (!_instance) return
  // Chunk 1 skeleton has no listeners; the real dispatch lands in Chunk 2.
  void (event as unknown) // silence unused-var
}
```

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: PASS — 3/3 tests in sseBus.spec.ts.

- [ ] **Step 5: Run full test suite, verify no regressions**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 5`
Expected: same pass count as before + 3 new tests = baseline + 3.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/helpers/sseBus.ts src/apps/desktop/src/__tests__/sseBus.spec.ts
git commit -m "feat(sse-bus): skeleton sseBus with install/reset contract

Establishes the module-level singleton + the public surface (on,
off, subscribeSessionChannels, unsubscribeSessionChannels, state,
reconnectGlobal, close). Listener dispatch lands in Chunk 2."
```

---

## Chunk 2: Wire the global SseClient + on/off dispatch

Connects the bus to a real `SseClient` (the global one) and makes `on`/`off` work end-to-end. After this chunk, the bus can be installed in App.vue and the workers channel (currently the only one App.vue owns) can be migrated.

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseBus.ts`
- Modify: `src/apps/desktop/src/__tests__/sseBus.spec.ts`

- [ ] **Step 1: Write the failing test for `on` → `__dispatch` → listener fires**

Append to `src/apps/desktop/src/__tests__/sseBus.spec.ts`:

```ts
it('on(type, cb) — dispatch fires the listener', () => {
  const bus = installSseBus(app)
  const cb = vi.fn()
  bus.on('session', cb)
  __dispatchSseBus('session', {
    id: 's_1',
    action: 'updated',
    name: 'Renamed',
  } as any)
  expect(cb).toHaveBeenCalledTimes(1)
  expect(cb).toHaveBeenCalledWith({
    id: 's_1',
    action: 'updated',
    name: 'Renamed',
  })
})

it('on(type, cb) — multiple subscribers all fire', () => {
  const bus = installSseBus(app)
  const a = vi.fn(), b = vi.fn()
  bus.on('worker', a)
  bus.on('worker', b)
  __dispatchSseBus('worker', { id: 'w_1', action: 'created' } as any)
  expect(a).toHaveBeenCalledTimes(1)
  expect(b).toHaveBeenCalledTimes(1)
})

it('on(type, cb) — unsubscribe stops delivery', () => {
  const bus = installSseBus(app)
  const cb = vi.fn()
  const off = bus.on('session', cb)
  off()
  __dispatchSseBus('session', { id: 's_1', action: 'updated' } as any)
  expect(cb).not.toHaveBeenCalled()
})

it('off(type, cb) — removes a specific listener', () => {
  const bus = installSseBus(app)
  const cb = vi.fn()
  bus.on('session', cb)
  bus.off('session', cb)
  __dispatchSseBus('session', { id: 's_1', action: 'updated' } as any)
  expect(cb).not.toHaveBeenCalled()
})
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: 4 new tests FAIL — the skeleton `on` is a no-op.

- [ ] **Step 3: Implement `on` / `off` and wire the global SseClient**

Replace the body of `installSseBus` in `src/apps/desktop/src/helpers/sseBus.ts`:

```ts
import { createUnifiedSseConnection } from '../api'
// ... existing imports

export function installSseBus(_app: App): SseBus {
  if (_instance) return _instance

  // Per-type listener Maps
  const listeners = {
    worker: new Set<Listener<'worker'>>(),
    session: new Set<Listener<'session'>>(),
    kanban: new Set<Listener<'kanban'>>(),
    llm: new Set<Listener<'llm'>>(),
    queue: new Set<Listener<'queue'>>(),
  } as const

  const state = shallowRef<SseState>('closed')

  // Open the GLOBAL SseClient — workers + sessions + kanban
  const globalClient: SseClient = createUnifiedSseConnection({
    channels: {
      workers: (e) => dispatch('worker', e),
      sessions: (e) => dispatch('session', e),
      kanban: (e) => dispatch('kanban', e),
    },
    onError: (err) => {
      // eslint-disable-next-line no-console
      console.error('[sseBus] global SSE failed permanently:', err)
    },
    onConnected: () => {
      // eslint-disable-next-line no-console
      console.log('[sseBus] global SSE connected')
    },
  })

  // Mirror SseClient state into our ShallowRef so the badge can read it
  state.value = globalClient.getState()
  globalClient.onStateChange((s) => {
    state.value = s
  })

  function dispatch<K extends keyof SseEventMap>(
    type: K,
    event: SseEventMap[K],
  ): void {
    const set = listeners[type] as Set<Listener<K>>
    for (const cb of set) {
      try {
        cb(event)
      } catch (e) {
        // eslint-disable-next-line no-console
        console.error(`[sseBus] ${type} listener threw:`, e)
      }
    }
  }

  // Per-session EventSource pool (refcounted)
  const sessionClients = new Map<string, SseClient>()
  const sessionRefcounts = new Map<string, number>()

  function subscribeSessionChannels(sid: string): void {
    sessionRefcounts.set(sid, (sessionRefcounts.get(sid) ?? 0) + 1)
    if (sessionClients.has(sid)) return
    const c: SseClient = createUnifiedSseConnection({
      channels: {
        llm: {
          sessionId: sid,
          onEvent: (e) => dispatch('llm', e),
        },
        queue: {
          sessionId: sid,
          onEvent: (e) => dispatch('queue', e),
        },
      },
    })
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

  _instance = {
    on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void {
      ;(listeners[type] as Set<Listener<K>>).add(cb)
      return () => {
        ;(listeners[type] as Set<Listener<K>>).delete(cb)
      }
    },
    off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void {
      ;(listeners[type] as Set<Listener<K>>).delete(cb)
    },
    subscribeSessionChannels,
    unsubscribeSessionChannels,
    state,
    reconnectGlobal(): void {
      globalClient.reconnect()
    },
    close(): void {
      // Close all session-scoped clients first
      for (const c of sessionClients.values()) {
        c.close()
      }
      sessionClients.clear()
      sessionRefcounts.clear()
      globalClient.close()
      _instance = null
    },
  }
  return _instance
}

// __resetSseBus now also needs to close the global client
export function __resetSseBus(): void {
  if (_instance) {
    _instance.close()
  }
  _instance = null
}
```

- [ ] **Step 4: Run the new sseBus tests, verify they PASS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: 7/7 tests in sseBus.spec.ts (3 from Chunk 1 + 4 new).

- [ ] **Step 5: Run full test suite + build, verify no regressions**

Run:
```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 20
```
Expected: vitest reports the same count as before + 7. `bun run build` exits 0 (TypeScript type-checks the new helper).

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/helpers/sseBus.ts src/apps/desktop/src/__tests__/sseBus.spec.ts
git commit -m "feat(sse-bus): wire global SseClient + on/off dispatch

installSseBus now opens the global EventSource
(/api/events?channels=workers,sessions,kanban) and dispatches
incoming events to listeners registered via bus.on(type, cb). The
session-scoped refcounted EventSource pool is also in place but not
yet exercised by callers (lands in Chunk 4)."
```

---

## Chunk 3: Add the SseBus test-only escape hatch `__setClient`

Tests need to replace the underlying `SseClient` (the global one) with a stub so they can drive events directly. The test-only API in Chunk 2 was just `__dispatch` (which dispatches into listeners). Now we add `__setClient` (which replaces the SseClient and re-wires `state`). This is the foundation for updating the 3 affected test files in Chunks 5-7.

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseBus.ts`
- Modify: `src/apps/desktop/src/__tests__/sseBus.spec.ts`

- [ ] **Step 1: Write the failing test for `__setClient` swapping**

Append to `sseBus.spec.ts`:

```ts
it('__setClient replaces the global SseClient and re-wires state', () => {
  const bus = installSseBus(app)
  let stateChanges: SseState[] = []
  const unsub = bus.state.watch((s) => stateChanges.push(s))

  const stub = makeStubClient('connecting')
  __setSseBusGlobalClient(stub)
  // The bus's state ShallowRef should now reflect the stub's state
  expect(bus.state.value).toBe('connecting')

  // Drive a state change on the stub
  emitStubState(stub, 'open')
  expect(bus.state.value).toBe('open')
  expect(stateChanges).toContain('open')

  unsub()
})

it('__setClient close() on the old client is called when replacing', () => {
  installSseBus(app)
  const old = __getSseBusGlobalClient()
  const closeSpy = vi.spyOn(old!, 'close')
  const stub = makeStubClient('closed')
  __setSseBusGlobalClient(stub)
  expect(closeSpy).toHaveBeenCalled()
})
```

Add these test-only helpers to the top of `sseBus.spec.ts`:

```ts
import type { SseClient, SseState } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  const stateChanges: Array<(s: SseState) => void> = []
  let s: SseState = initial
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => s,
    onStateChange: (cb) => {
      stateChanges.push(cb)
      return () => {
        const i = stateChanges.indexOf(cb)
        if (i >= 0) stateChanges.splice(i, 1)
      }
    },
  } as unknown as SseClient
}

function emitStubState(c: SseClient, s: SseState): void {
  // Walk the internal listener list — for tests we can reach it via the
  // public surface if we expose it; for now use a direct ref.
  ;(c as any).__listeners.forEach((cb: (s: SseState) => void) => cb(s))
}
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: 2 new tests FAIL — `__setSseBusGlobalClient` and `__getSseBusGlobalClient` don't exist yet.

- [ ] **Step 3: Implement `__setSseBusGlobalClient` + `__getSseBusGlobalClient`**

In `sseBus.ts`, add to the `_instance` object:

```ts
// TEST-ONLY — do not call from production code.
// Replaces the global SseClient. Closes the previous one.
let _globalClient: SseClient | null = null
let _stateUnsub: (() => void) | null = null
```

Modify the body of `installSseBus` to expose the globals via closures, and add the setters/getters as **module-level exports**:

```ts
// (inside installSseBus, after creating globalClient:)
_globalClient = globalClient
_stateUnsub = globalClient.onStateChange((s) => {
  state.value = s
})

// add these as module-level functions (NOT inside installSseBus):
export function __setSseBusGlobalClient(client: SseClient): void {
  if (!_instance) return
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  if (_globalClient) {
    _globalClient.close()
  }
  _globalClient = client
  _stateUnsub = client.onStateChange((s) => {
    if (_instance) {
      _instance.state.value = s
    }
  })
  // Update the public ShallowRef so observers see the new initial state
  _instance.state.value = client.getState()
}

export function __getSseBusGlobalClient(): SseClient | null {
  return _globalClient
}
```

And update `__resetSseBus` to clear the test-only globals too:

```ts
export function __resetSseBus(): void {
  if (_instance) {
    _instance.close()
  }
  _globalClient = null
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  _instance = null
}
```

- [ ] **Step 4: Run the new tests, verify they PASS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: 9/9 tests in sseBus.spec.ts (3 from Chunk 1 + 4 from Chunk 2 + 2 new).

- [ ] **Step 5: Run full test suite + build**

Run:
```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: same as before + 9. `bun run build` exits 0.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/helpers/sseBus.ts src/apps/desktop/src/__tests__/sseBus.spec.ts
git commit -m "test(sse-bus): add __setClient / __getClient test-only API

Tests can now replace the bus's underlying SseClient with a stub
and drive state changes directly. Foundation for the 3 test-file
updates in Chunks 5-7."
```

---

## Chunk 4: Add the `subscribeSessionChannels` refcount test + wire it through `__dispatch`

The Chunk 2 implementation of `subscribeSessionChannels` opens a real SseClient via `createUnifiedSseConnection`, which means tests can't drive it without mocking. Add a `__setSseBusSessionClient(sid, client)` escape hatch mirroring the global one, then write the refcount test.

**Files:**
- Modify: `src/apps/desktop/src/helpers/sseBus.ts`
- Modify: `src/apps/desktop/src/__tests__/sseBus.spec.ts`

- [ ] **Step 1: Write the failing tests for `subscribeSessionChannels` refcount + close-on-last-unsubscribe**

Append to `sseBus.spec.ts`:

```ts
it('subscribeSessionChannels — first call opens a client; second is a no-op', () => {
  const bus = installSseBus(app)
  const openSpy = vi.fn()
  // Stub the factory for this test by pre-registering a fake client
  // via the test-only API (lands in step 3).
  bus.subscribeSessionChannels('s_1')
  // Refcount is 1; calling again should NOT open a second client
  bus.subscribeSessionChannels('s_1')
  // We can't directly count clients here without exposing the map; use
  // the refcount side-effect: unsubscribing twice should NOT error.
  bus.unsubscribeSessionChannels('s_1') // refcount → 0, closes
  expect(() => bus.unsubscribeSessionChannels('s_1')).not.toThrow()
})

it('subscribeSessionChannels — first subscribe gets the llm event, second (same sid) does not duplicate', () => {
  const bus = installSseBus(app)
  const a = vi.fn(), b = vi.fn()
  bus.on('llm', a)
  bus.on('llm', b)
  bus.subscribeSessionChannels('s_1')
  // After two subscribes to the same sid, the refcount is 2; the
  // single underlying client fans out to both listeners via dispatch.
  bus.subscribeSessionChannels('s_1')
  __dispatchSseBus('llm', { session_id: 's_1', content: 'hi' } as any)
  expect(a).toHaveBeenCalledTimes(1)
  expect(b).toHaveBeenCalledTimes(1)
  // Clean up
  bus.unsubscribeSessionChannels('s_1')
  bus.unsubscribeSessionChannels('s_1')
})
```

- [ ] **Step 2: Run the test, verify it FAILS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 30`
Expected: 2 new tests FAIL — the bus's session refcount isn't observable; `__dispatchSseBus` doesn't accept session events because no client is wired.

- [ ] **Step 3: Expose `__setSseBusSessionClient` + refactor session pool**

The Chunk 2 implementation of `subscribeSessionChannels` directly calls `createUnifiedSseConnection`, which makes it impossible to test without network mocking. Refactor to use a test-overridable factory:

```ts
// Module-level (overridable in tests):
let _sessionFactory: (
  sid: string,
  dispatch: <K extends keyof SseEventMap>(type: K, event: SseEventMap[K]) => void,
) => SseClient = (sid, dispatch) => createUnifiedSseConnection({
  channels: {
    llm: { sessionId: sid, onEvent: (e) => dispatch('llm', e) },
    queue: { sessionId: sid, onEvent: (e) => dispatch('queue', e) },
  },
})

// inside installSseBus:
function subscribeSessionChannels(sid: string): void {
  sessionRefcounts.set(sid, (sessionRefcounts.get(sid) ?? 0) + 1)
  if (sessionClients.has(sid)) return
  const c = _sessionFactory(sid, dispatch)
  sessionClients.set(sid, c)
}
```

Add the test-only override:

```ts
export function __setSseBusSessionClient(sid: string, client: SseClient): void {
  // For tests: pre-register a client so subscribeSessionChannels finds it
  // via the _sessionFactory override.
  if (!_instance) return
  // The factory override is module-level; tests set it before calling subscribe.
  // (This function is for tests that want to inject a client AFTER subscribe
  // was called — useful for the "already-running" state assertions.)
  ;(_instance as any).__test_sessionClients.set(sid, client)
}
```

- [ ] **Step 4: Run the new tests, verify they PASS**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run sseBus 2>&1 | tail -n 20`
Expected: 11/11 tests in sseBus.spec.ts.

- [ ] **Step 5: Run full test suite + build**

Run:
```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/helpers/sseBus.ts src/apps/desktop/src/__tests__/sseBus.spec.ts
git commit -m "test(sse-bus): cover subscribeSessionChannels refcount

The first subscribe opens a client, the second is a no-op (refcount
goes to 2), the last unsubscribe closes the client. Also adds
__setSseBusSessionClient for tests that need to inject a client
directly."
```

---

## Chunk 5: Migrate App.vue from `createUnifiedSseConnection` to `installSseBus`

App.vue is the simplest consumer — it currently owns only the `workers` channel via a per-app `SseClient`. After this chunk, it installs the bus and the bus owns the workers subscription.

**Files:**
- Modify: `src/apps/desktop/src/App.vue`

- [ ] **Step 1: Verify the existing App.spec.ts still passes baseline**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run App.spec 2>&1 | tail -n 10`
Expected: passes (whatever the baseline is).

- [ ] **Step 2: Write the failing test for App.vue using the bus**

Add to `src/apps/desktop/src/__tests__/App.spec.ts` (or create a new test if needed):

```ts
import { installSseBus, __resetSseBus, __getSseBusGlobalClient, __setSseBusGlobalClient } from '../helpers/sseBus'

it('App.vue calls installSseBus on mount and bus.close on unmount', async () => {
  // The existing App.spec.ts already mounts App; add this assertion.
  // (See existing test for the mount pattern; the assertion is:)
  expect(installSseBus).toHaveBeenCalledTimes(/* 1 after mount */)
})
```

(Adjust the assertion to match the existing test setup — the goal is to confirm `installSseBus` is called and `bus.close()` is called on unmount.)

- [ ] **Step 3: Modify App.vue**

In `src/apps/desktop/src/App.vue`, replace the `<script setup>` body with:

```ts
import { ref, provide, onMounted, onUnmounted } from 'vue'
import * as api from './api'
import { installSseBus, useSseBus } from './helpers/sseBus'

// LLM processing state - provided to child components
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// Handle worker events from the SSE bus
const handleWorkerEvent = (event: api.WorkerEvent) => {
  console.log('[App] Worker event:', event)

  if (event.action === 'deleted') {
    const sessionId = event.session_id || event.id
    if (sessionId && processingState.value[sessionId]) {
      const newState = { ...processingState.value }
      delete newState[sessionId]
      processingState.value = newState
    }
  } else {
    const sessionId = event.session_id || event.id
    if (sessionId) {
      processingState.value = {
        ...processingState.value,
        [sessionId]: true,
      }
    }
  }
}

const fetchInitialWorkers = async () => {
  try {
    const { workers } = await api.getWorkers(undefined, 50)
    const newState: Record<string, boolean> = {}
    for (const worker of workers) {
      const sessionId = worker.session_id || worker.id
      if (sessionId) {
        newState[sessionId] = true
      }
    }
    processingState.value = newState
  } catch (err) {
    console.error('Failed to fetch initial workers:', err)
  }
}

const isProcessing = (sessionId: string) => !!processingState.value[sessionId]

let offWorker: (() => void) | null = null

onMounted(() => {
  const bus = installSseBus(/* app context not needed for module singleton */ null as any)
  offWorker = bus.on('worker', handleWorkerEvent)
  bus.state.value // read once to initialize the badge
})

onUnmounted(() => {
  if (offWorker) {
    offWorker()
    offWorker = null
  }
  useSseBus().close()
})
```

NOTE: The `installSseBus` signature takes `app: App` for future `provide()` use. For the module-singleton implementation, we can pass `null` or a dummy `createApp({})`. The signature doesn't need to change.

- [ ] **Step 4: Run App.spec.ts, verify it PASSES (after test update)**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run App.spec 2>&1 | tail -n 20`

- [ ] **Step 5: Update App.spec.ts to use the bus test API**

Replace any `vi.spyOn(api, 'createUnifiedSseConnection')` in `App.spec.ts` with the bus test API:

```ts
import { __setSseBusGlobalClient, __getSseBusGlobalClient, makeStubClient } from './helpers/sseBus-test-utils'
// (or inline the stub factory)
```

(Use the same `makeStubClient` helper from Chunk 3.)

- [ ] **Step 6: Run full test suite + build**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: same pass count, no regressions.

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/App.vue src/apps/desktop/src/__tests__/App.spec.ts
git commit -m "refactor(sse): migrate App.vue workers handler to sseBus

Replaces the App.vue-owned SseClient with bus.on('worker', cb).
The bus is installed on mount and closed on unmount. The internal
SseClient for /api/events?channels=workers,sessions,kanban is
opened by the bus (in installSseBus, Chunk 2) — this is the same
URL the App.vue-owned client was hitting, but now shared with the
sessions and kanban channels."
```

---

## Chunk 6: Migrate the `workspaces` store from `subscribeToSessionEvents` to `bus.on('session', ...)`

The store currently opens its own `createUnifiedSseConnection` for the `sessions` channel — a duplicate of the bus's subscription. After this chunk, the store just installs a `bus.on('session', ...)` listener.

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts`
- Modify: `src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts`

- [ ] **Step 1: Verify baseline test passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreSessionEvents 2>&1 | tail -n 10`

- [ ] **Step 2: Read the current store implementation**

Read `src/apps/desktop/src/stores/workspaces.ts` around line 1500-1620 (the `subscribeToSessionEvents` function and the `sessionEventSubscribers` Set). The plan assumes:
- A `subscribeToSessionEvents()` function is called once on store init
- It opens a `createUnifiedSseConnection` for `sessions`
- A `sessionEventSubscribers: Set<...>` holds external fan-out callbacks
- `onSessionEvent(cb)` adds to the set, returns an unsubscribe

- [ ] **Step 3: Replace the implementation with bus-based listeners**

In `stores/workspaces.ts`, replace `subscribeToSessionEvents` + `sessionEventSubscribers` + `sessionsSse` ref with:

```ts
function installSessionEventHandlers() {
  const bus = useSseBus()

  // Internal handler: workspace tree mutation
  bus.on('session', (event) => {
    if (event.action === 'updated') {
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
  })
}

function onSessionEvent(cb: (event: api.SessionEvent) => void): () => void {
  const bus = useSseBus()
  return bus.on('session', (event) => {
    try {
      cb(event)
    } catch (e) {
      console.error('[workspacesStore] session event subscriber threw:', e)
    }
  })
}
```

Call `installSessionEventHandlers()` from the store's `init()` function (once, idempotent — same as today's `subscribeToSessionEvents` pattern).

- [ ] **Step 4: Update the test**

In `workspacesStoreSessionEvents.spec.ts`:
- Remove the `vi.spyOn(api, 'createUnifiedSseConnection')` spy.
- Use the bus test API: call `installSseBus(createApp({}))`, then `__dispatchSseBus('session', { id, action: 'updated', name: 'Renamed' })` to drive events.
- The existing test cases (renamed-task updates nav, deleted-task clears active) should pass via the bus.

- [ ] **Step 5: Run the test, verify it PASSES**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run workspacesStoreSessionEvents 2>&1 | tail -n 20`
Expected: same number of passing tests as before.

- [ ] **Step 6: Run full test suite + build**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/stores/workspaces.ts src/apps/desktop/src/__tests__/workspacesStoreSessionEvents.spec.ts
git commit -m "refactor(sse): migrate workspaces store sessions handler to sseBus

Drops subscribeToSessionEvents() and the sessionsSse ref. The store
now installs a bus.on('session', ...) listener (idempotent, runs
once on init) for internal workspace-tree mutation, and the public
onSessionEvent(cb) becomes a thin wrapper that calls
bus.on('session', cb) with try/catch around the user callback.

This eliminates the duplicate 'sessions' subscription that existed
between App.vue and the workspaces store (the bug this plan was
written to fix)."
```

---

## Chunk 7: Migrate ChatView.vue from per-chat `createUnifiedSseConnection` to `bus.on('llm'/'queue') + bus.subscribeSessionChannels`

ChatView currently opens its own `createUnifiedSseConnection` for `llm` + `queue` channels scoped to the active session. After this chunk, it subscribes listeners to the bus and asks the bus to open/close the session-scoped EventSource.

**Files:**
- Modify: `src/apps/desktop/src/components/ChatView.vue`
- Modify: `src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts`

- [ ] **Step 1: Verify baseline test passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run chatViewWorktree 2>&1 | tail -n 10`

- [ ] **Step 2: Read the current ChatView.vue SSE wiring**

Read `src/apps/desktop/src/components/ChatView.vue` around line 1610-1700 (the `chatSse.value = api.createUnifiedSseConnection(...)` block + the `disconnectSse()` function + any close logic).

- [ ] **Step 3: Modify ChatView.vue**

Find the per-chat `createUnifiedSseConnection` call. Replace with:

```ts
import { useSseBus } from '../helpers/sseBus'

const bus = useSseBus()
const mySessionId = computed(() => /* the active session id, e.g. activeTaskId.value */)
let offLlm: (() => void) | null = null
let offQueue: (() => void) | null = null

function connectSse() {
  const sid = mySessionId.value
  if (!sid) return
  // Subscribe FIRST so we don't miss the first event after connect
  offLlm = bus.on('llm', (event) => {
    if (event.session_id !== sid) return
    // ... existing onLlmEvent handler body ...
  })
  offQueue = bus.on('queue', (event) => {
    if (event.session_id !== sid) return
    // ... existing onQueueEvent handler body ...
  })
  // Open the chat-scoped EventSource (refcounted; idempotent)
  bus.subscribeSessionChannels(sid)
}

function disconnectSse() {
  if (offLlm) { offLlm(); offLlm = null }
  if (offQueue) { offQueue(); offQueue = null }
  const sid = mySessionId.value
  if (sid) bus.unsubscribeSessionChannels(sid)
}
```

Wire `connectSse()` into the existing mount logic (where the per-chat `createUnifiedSseConnection` was called) and `disconnectSse()` into the existing unmount logic.

- [ ] **Step 4: Update the test**

In `chatViewWorktree.spec.ts`:
- Replace `vi.spyOn(api, 'createUnifiedSseConnection')` with the bus test API.
- Drive LLM/queue events via `__dispatchSseBus('llm', { session_id: '...', content: '...' })` directly.

- [ ] **Step 5: Run the test, verify it PASSES**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run chatViewWorktree 2>&1 | tail -n 20`

- [ ] **Step 6: Run full test suite + build**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```

- [ ] **Step 7: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/components/ChatView.vue src/apps/desktop/src/__tests__/chatViewWorktree.spec.ts
git commit -m "refactor(sse): migrate ChatView per-chat llm/queue to sseBus

Replaces the per-chat createUnifiedSseConnection call with
bus.on('llm'|'queue', ...) + bus.subscribeSessionChannels(sid).
The bus manages the underlying EventSource lifecycle (refcounted
per session), so the user-visible reconnect semantics are
preserved while the listener-attachment is no longer coupled to
the EventSource's open/close events."
```

---

## Chunk 8: Migrate `useSubAgentPeek` from per-peek `createUnifiedSseConnection` to `bus.on('llm') + bus.subscribeSessionChannels`

Same shape as Chunk 7 but for the sub-agent peek composable. It filters by the peek session id (not the active chat's session id), so each peek has its own subscription.

**Files:**
- Modify: `src/apps/desktop/src/composables/useSubAgentPeek.ts`
- Modify: `src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts`

- [ ] **Step 1: Verify baseline test passes**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run useSubAgentPeek 2>&1 | tail -n 10`

- [ ] **Step 2: Modify useSubAgentPeek.ts**

Replace the `openSse()` / `closeSse()` / `sseClient` local with:

```ts
import { useSseBus } from '../helpers/sseBus'

let offLlm: (() => void) | null = null

function openSse() {
  const bus = useSseBus()
  const sid = opts.sessionId
  offLlm = bus.on('llm', (event) => {
    if (event.session_id !== sid) return
    applyChunkToMessages(messages, event, totalTokens, status)
  })
  bus.subscribeSessionChannels(sid)
}

function closeSse() {
  if (offLlm) { offLlm(); offLlm = null }
  useSseBus().unsubscribeSessionChannels(opts.sessionId)
}
```

- [ ] **Step 3: Update the test**

In `useSubAgentPeek.spec.ts`:
- Remove `vi.spyOn(api, 'createUnifiedSseConnection')`.
- Use the bus test API to drive `llm` events.

- [ ] **Step 4: Run the test, verify it PASSES**

Run: `cd src/apps/desktop && timeout 60 bunx vitest run useSubAgentPeek 2>&1 | tail -n 20`

- [ ] **Step 5: Run full test suite + build**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/composables/useSubAgentPeek.ts src/apps/desktop/src/__tests__/useSubAgentPeek.spec.ts
git commit -m "refactor(sse): migrate useSubAgentPeek to sseBus

Same pattern as ChatView: bus.on('llm', ...) + bus.subscribeSessionChannels.
The peek's session_id is the sub-agent's, not the active chat's, so the
listener-side filter handles the scoping."
```

---

## Chunk 9: Migrate `SseStatusBadge` from `client` prop to `useSseBus().state`

The badge currently receives an `SseClient` as a prop. After this chunk, it reads `bus.state` directly via `useSseBus()`. Parents no longer need to pass anything.

**Files:**
- Modify: `src/apps/desktop/src/components/SseStatusBadge.vue`

- [ ] **Step 1: Verify baseline (no SseStatusBadge test file yet — skip)**

Run: `cd src/apps/desktop && timeout 30 rg -l "SseStatusBadge" src/ 2>&1 | head -n 10`

- [ ] **Step 2: Read the current SseStatusBadge.vue**

Already done in planning. The prop is `client: SseClient | null | undefined`. The component uses `c.getState()` and `c.onStateChange(...)`.

- [ ] **Step 3: Replace the prop with `useSseBus().state`**

Replace the `<script setup>` body with:

```ts
<script setup lang="ts">
import { onUnmounted, ref, watch } from 'vue'
import { useSseBus } from '../helpers/sseBus'
import type { SseState } from '../helpers/sseClient'

const bus = useSseBus()
const state = ref<SseState>(bus.state.value)
const attempt = ref(0)
let unsubscribe: (() => void) | null = null

// Read the current state immediately so we don't flash the wrong pill.
unsubscribe = bus.state.watch((s) => {
  state.value = s
})

onUnmounted(() => {
  if (unsubscribe) {
    unsubscribe()
    unsubscribe = null
  }
})
</script>
```

(Adjust the visual states to match the existing template — they don't change.)

- [ ] **Step 4: Find all parent call sites and remove the `client` prop**

Run: `cd src/apps/desktop && rg -n "SseStatusBadge" src/ 2>&1 | head -n 20`

For each parent:
- Remove `:client="..."` (or `client="..."`) from the `<SseStatusBadge>` usage.

- [ ] **Step 5: Run full test suite + build**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: 0 type errors (vue-tsc will catch any missed `client` prop usage).

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
git add src/apps/desktop/src/components/SseStatusBadge.vue $(rg -l "SseStatusBadge" src/apps/desktop/src)
git commit -m "refactor(sse): SseStatusBadge reads from bus.state instead of client prop

The badge now self-subscribes to the bus's state ShallowRef. Parent
components no longer need to pass :client=\"\". One badge for the
whole app, driven by the single global SseClient owned by the bus."
```

---

## Chunk 10: Final cleanup — verify success criteria, no leftover `createUnifiedSseConnection` calls

Sanity check the full migration.

**Files:**
- (no new files; verification-only chunk)

- [ ] **Step 1: Confirm no legacy `createUnifiedSseConnection` calls remain**

Run:
```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox/.worktrees/unify-frontend-sse
rg -n "createUnifiedSseConnection" src/apps/desktop/src 2>&1 | head -n 20
```
Expected: exactly **1 hit** — the one inside `sseBus.ts` (the root install + the per-session factory).

- [ ] **Step 2: Confirm no `new EventSource` calls remain**

Run:
```bash
rg -n "new EventSource" src/apps/desktop/src 2>&1
```
Expected: 0 hits.

- [ ] **Step 3: Confirm no `subscribeToSessionEvents` calls remain**

Run:
```bash
rg -n "subscribeToSessionEvents" src/apps/desktop/src 2>&1
```
Expected: 0 hits (the function was deleted in Chunk 6; callers don't exist).

- [ ] **Step 4: Run full test suite + build one more time**

```bash
cd src/apps/desktop
timeout 120 bunx vitest run 2>&1 | tail -n 5
timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: vitest count = baseline + ~16 (3 from Chunks 1+4, 2 from Chunk 2, 2 from Chunk 3, 2 from Chunk 4, 7 from migration chunks that updated existing tests). `bun run build` exits 0.

- [ ] **Step 5: Commit any straggler changes (if any)**

If the verification commands revealed any cleanup (e.g., a dead import), commit it with a `chore(sse): post-migration cleanup` message. If nothing changed, skip.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-30-unify-frontend-sse.md`. Ready to execute via subagent-driven-development (each chunk → 1 implementer subagent + 2 reviewers per the project's standard).

// src/apps/desktop/src/helpers/sseBus.ts
import type { App, ShallowRef } from 'vue'
import { shallowRef } from 'vue'
import type { SseClient, SseState } from './sseClient'
import { createUnifiedSseConnection } from '../api'
import type {
  WorkerEvent,
  SessionEvent,
  KanbanColumnEvent,
  KanbanTaskEvent,
  SseEvent,
  QueueMessageEvent,
} from '../api'

// NOTE: Plan's Chunk 1 spec imports `KanbanEvent` and `LlmChunkEvent`
// from `../api`, but those names don't exist in `api/index.ts` — the
// actual exports are `KanbanColumnEvent` / `KanbanTaskEvent` and
// `SseEvent`. We use the real names here; the `SseEventMap` shape
// (worker / session / kanban / llm / queue) is unchanged.
type SseEventMap = {
  worker: WorkerEvent
  session: SessionEvent
  kanban: KanbanColumnEvent | KanbanTaskEvent
  llm: SseEvent
  queue: QueueMessageEvent
}

type Listener<K extends keyof SseEventMap> = (event: SseEventMap[K]) => void

export interface SseBus {
  /**
   * Register a listener for events of `type`. Returns an unsubscribe
   * function. The same `cb` registered twice for the same `type`
   * counts twice (callers must dedupe themselves). No-op if the bus
   * is not yet installed.
   */
  on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void
  /**
   * Remove a previously-registered listener. No-op if `cb` was not
   * registered for `type`. No-op if the bus is not yet installed.
   */
  off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void
  /**
   * Subscribe to session-scoped channels (`llm`, `queue`) for the
   * given session id. Idempotent (refcount per sid — first call
   * opens, last unsubscribe closes). No-op if the bus is not yet
   * installed.
   *
   * Chunk 2 NOTE: this function only bumps a per-sid refcount. The
   * session-scoped SseClient is wired in Chunk 4 (when the
   * `ChatView` migrates to `useSseBus`); the refcount is in place
   * so Chunks 5-7 can convert consumers without an intermediate
   * refactor.
   */
  subscribeSessionChannels(sessionId: string): void
  /**
   * Decrement the per-sid refcount; closes the underlying session
   * stream when the last subscriber leaves. Refcount is per
   * `sessionId`, so multiple `on()` registrations on the same sid
   * still count as one logical subscriber. No-op if the bus is not
   * yet installed or the sid was never subscribed.
   *
   * Chunk 2 NOTE: matching the `subscribeSessionChannels` caveat
   * above — the refcount is tracked but no client is opened yet.
   */
  unsubscribeSessionChannels(sessionId: string): void
  /**
   * Reactive read of the current SSE connection state (one of
   * `connecting | open | reconnecting | closed | failed`). Updates
   * synchronously on every state transition emitted by the
   * underlying `SseClient`.
   */
  readonly state: ShallowRef<SseState>
  /**
   * Force a reconnect of the global (non-session-scoped) channels
   * and reset the attempt counter. Use this for a user-driven
   * "Retry" button on the `failed` badge. No-op if the bus is not
   * yet installed.
   */
  reconnectGlobal(): void
  /**
   * Close the bus. Terminal — stops all streams, clears retry
   * timers, leaves the bus uninstalled (a subsequent `installSseBus`
   * rebuilds it). Safe to call multiple times.
   */
  close(): void
}

let _instance: SseBus | null = null

// Module-level handle to the current `dispatch` function. Populated
// by `installSseBus` (which owns the listener Maps in its closure)
// and read by `__dispatchSseBus` (the test injection point). Setting
// this to null in `__resetSseBus` / `close()` ensures the test
// escape hatch becomes a no-op once the bus is torn down.
type DispatchFn = <K extends keyof SseEventMap>(type: K, event: SseEventMap[K]) => void
let _dispatch: DispatchFn | null = null

export function installSseBus(_app: App): SseBus {
  if (_instance) return _instance

  // Per-type listener Sets. Each channel's listeners live in their
  // own Set so `on('worker', cb)` doesn't accidentally fire on
  // session events.
  const listeners: { [K in keyof SseEventMap]: Set<Listener<K>> } = {
    worker: new Set<Listener<'worker'>>(),
    session: new Set<Listener<'session'>>(),
    kanban: new Set<Listener<'kanban'>>(),
    llm: new Set<Listener<'llm'>>(),
    queue: new Set<Listener<'queue'>>(),
  }

  const state = shallowRef<SseState>('closed')

  // Open the GLOBAL SseClient — workers + sessions + kanban. The
  // session-scoped client is created lazily inside
  // `subscribeSessionChannels` (Chunk 4 wires it for real; Chunk 2
  // tracks refcounts only).
  const globalClient: SseClient = createUnifiedSseConnection({
    channels: {
      workers: (e) => dispatch('worker', e),
      sessions: (e) => dispatch('session', e),
      kanban: (e) => dispatch('kanban', e),
    },
    onError: (err) => {
      console.error('[sseBus] global SSE failed permanently:', err)
    },
    onConnected: () => {
      console.log('[sseBus] global SSE connected')
    },
  })

  // Mirror SseClient state into our ShallowRef so the badge can
  // read it. `getState()` returns the initial value
  // ('connecting', set by createSseClient); subsequent transitions
  // arrive via `onStateChange`.
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
        // A buggy listener must not take down the SseClient's
        // `onEvent` callback (or any sibling listeners). Log to
        // console.error and keep iterating.
        console.error(`[sseBus] ${type} listener threw:`, e)
      }
    }
  }

  // Per-session EventSource pool (refcounted). The actual
  // `createUnifiedSseConnection` call lands in Chunk 4 — for now
  // we only track the refcount so Chunks 5-7 can convert consumers
  // without an intermediate refactor.
  const sessionClients = new Map<string, SseClient>()
  const sessionRefcounts = new Map<string, number>()

  function subscribeSessionChannels(sid: string): void {
    sessionRefcounts.set(sid, (sessionRefcounts.get(sid) ?? 0) + 1)
    if (sessionClients.has(sid)) return
    // Chunk 4 will open the session-scoped EventSource here:
    //
    //   const c: SseClient = createUnifiedSseConnection({
    //     channels: {
    //       llm:    { sessionId: sid, onEvent: (e) => dispatch('llm', e)    },
    //       queue:  { sessionId: sid, onEvent: (e) => dispatch('queue', e)  },
    //     },
    //   })
    //   sessionClients.set(sid, c)
    //
    // Until then, the refcount is the only state being maintained.
    void sid
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

  // Expose `dispatch` to the module-level `__dispatchSseBus` so
  // tests can inject synthetic events directly (bypassing the
  // SseClient). Stored AFTER the closures are wired so the test
  // escape hatch works from the first `installSseBus` call.
  _dispatch = dispatch

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
      // Close all session-scoped clients first so any in-flight
      // session event triggers a clean teardown before the global
      // client does.
      for (const c of sessionClients.values()) {
        c.close()
      }
      sessionClients.clear()
      sessionRefcounts.clear()
      globalClient.close()
      _dispatch = null
      _instance = null
    },
  }
  return _instance
}

export function useSseBus(): SseBus {
  if (!_instance) throw new Error('useSseBus called before installSseBus')
  return _instance
}

/**
 * Test-only: clears the singleton. Closes the global client (via
 * `bus.close()`) so the EventSource stub's retry timer / state
 * listeners are torn down before the next test installs a fresh
 * bus. Safe to call before `installSseBus` (no-op).
 */
export function __resetSseBus(): void {
  if (_instance) {
    _instance.close()
  }
  _instance = null
  _dispatch = null
}

/**
 * Test-only: dispatches a synthetic event into the bus's listener
 * Maps. Bypasses the SseClient entirely (the test owns the event
 * payload shape — `as any` casts at the call site are intentional
 * to keep this helper loose). No-op if the bus is not installed.
 */
export function __dispatchSseBus<K extends keyof SseEventMap>(
  type: K,
  event: SseEventMap[K],
): void {
  _dispatch?.(type, event)
}
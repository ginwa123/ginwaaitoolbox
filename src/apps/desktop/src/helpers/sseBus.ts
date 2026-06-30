// src/apps/desktop/src/helpers/sseBus.ts
import type { App, ShallowRef } from 'vue'
import { shallowRef } from 'vue'
import type { SseClient, SseState, SseStateInfo } from './sseClient'
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

// Module-level handle to the currently-installed global SseClient.
// Populated by `installSseBus` (and by `__setSseBusGlobalClient` when
// tests swap the client). Read by `__getSseBusGlobalClient` so tests
// can assert which client is wired in. Cleared in `close()` and
// `__resetSseBus` so a fresh test starts with `null`.
let _globalClient: SseClient | null = null

// Module-level unsubscribe for the `onStateChange` listener that
// mirrors the global SseClient's state into the bus's public
// `state` ShallowRef. Stashed here so `__setSseBusGlobalClient`
// can detach the OLD client's listener before swapping — without
// this handle, replacing the client would leak the old listener
// (each `onStateChange` call adds to the array without bound).
let _stateUnsub: (() => void) | null = null

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

export function installSseBus(_app?: App): SseBus {
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
  // `subscribeSessionChannels` (Chunk 4 wires the per-session
  // factory for real; the lazy lifecycle lets callers subscribe
  // AFTER on() registrations without an extra "open early" step).
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
  // arrive via `onStateChange`. The unsub is stashed in a
  // module-level handle so `__setSseBusGlobalClient` can detach
  // it before swapping the client (otherwise the OLD client's
  // listener would keep firing into the NEW client's ShallowRef).
  state.value = globalClient.getState()
  _stateUnsub = globalClient.onStateChange((s, _info: SseStateInfo) => {
    state.value = s
  })
  _globalClient = globalClient

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
      // Read through the module-level `_globalClient` handle at call
      // time (not the closure-scoped `globalClient` from install time)
      // so a swap via `__setSseBusGlobalClient` takes effect here.
      // The optional chain is defensive — `_globalClient` could be
      // null after a `close()` followed by `reconnectGlobal()` on a
      // torn-down bus (which `SseBus.close()` already protects
      // against by nulling `_instance`, but tests sometimes poke this).
      _globalClient?.reconnect()
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
      // Read through the module-level `_globalClient` handle at call
      // time (not the closure-scoped `globalClient` from install time)
      // so a swap via `__setSseBusGlobalClient` takes effect here.
      // The `_globalClient ?? globalClient` fallback is defensive —
      // in production the two point to the same object, but a test
      // that nulled `_globalClient` via `__resetSseBus` between
      // install and close still gets the original closed.
      const gc = _globalClient ?? globalClient
      gc.close()
      // Detach the state-mirror listener and clear the test-only
      // handles so a subsequent `installSseBus` starts clean (and
      // `__getSseBusGlobalClient()` returns null after close).
      if (_stateUnsub) {
        _stateUnsub()
        _stateUnsub = null
      }
      _globalClient = null
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
  // `close()` already nulls `_stateUnsub` + `_globalClient` +
  // `_dispatch`, but be defensive in case `__resetSseBus` is called
  // before `installSseBus` (when `_instance` is null) AND a previous
  // test leaked module-level state via a partial swap.
  _globalClient = null
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  _instance = null
  _dispatch = null
  // Reset the session factory back to the production default — a
  // test that called `__setSseBusSessionFactory` should NOT leak
  // the stub into the next test.
  _sessionFactory = DEFAULT_SESSION_FACTORY
}

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

/**
 * Test-only: replaces the global SseClient and re-wires the state
 * mirror. Closes the previous global client (if any) and detaches
 * the old `onStateChange` listener before subscribing the new
 * client's listener. Updates the bus's public `state` ShallowRef
 * to the new client's initial state so observers see the swap
 * immediately. No-op if the bus is not installed.
 *
 * Used by the migration test files (Chunks 5-7) to drive the
 * SSE state badge behavior — the production code paths under test
 * react to `bus.state.value` transitions, not to the underlying
 * `EventSource` lifecycle.
 */
export function __setSseBusGlobalClient(client: SseClient): void {
  if (!_instance) return
  // Detach the OLD client's state listener first so it doesn't keep
  // firing into the bus's ShallowRef after we swap.
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  // Close the old client (terminal — no further state transitions).
  // Only when it's a different instance — the same object passed in
  // twice would close-then-resubscribe-onto-the-same-thing, which is
  // fine but wasteful.
  if (_globalClient && _globalClient !== client) {
    _globalClient.close()
  }
  _globalClient = client
  _stateUnsub = client.onStateChange((s, _info: SseStateInfo) => {
    // Defensive: `_instance` could theoretically be nulled out
    // by a concurrent `close()` between the check above and this
    // callback firing.
    if (_instance) {
      _instance.state.value = s
    }
  })
  // Update the public ShallowRef so observers see the new initial
  // state synchronously — they shouldn't have to wait for the new
  // client to emit its first transition.
  _instance.state.value = client.getState()
}

/**
 * Test-only: returns the currently-installed global SseClient, or
 * null if the bus is not yet installed (or has been closed).
 * Useful for asserting that `__setSseBusGlobalClient` swapped the
 * right client, and for spying on `.close()` to verify cleanup.
 */
export function __getSseBusGlobalClient(): SseClient | null {
  return _globalClient
}
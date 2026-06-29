// src/apps/desktop/src/helpers/sseBus.ts
import type { App, ShallowRef } from 'vue'
import { shallowRef } from 'vue'
import type { SseState } from './sseClient'
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

/**
 * Test-only: clears the singleton. Listeners added in Chunk 2 must
 * also be cleared here — extending this function is part of Chunk 2's
 * work.
 */
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
  void type
}

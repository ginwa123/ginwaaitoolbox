// src/apps/desktop/src/helpers/sseBus.ts
import type { App, ShallowRef } from 'vue'
import { shallowRef } from 'vue'
import type { SseClient, SseState } from './sseClient'
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
  void type
}

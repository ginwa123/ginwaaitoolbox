/**
 * useSubAgentPeek — composable for the sub-agent peek panel.
 *
 * Owns the lifecycle of a "peek" into a sub-agent session:
 *   1. Fetch the sub-agent's initial message history via
 *      `GET /llm/session/{sid}/messages`.
 *   2. Open a dedicated `?channels=llm:{sid}` SSE connection for live
 *      streaming updates.
 *   3. Accumulate incoming chunks into a `messages` ref that the
 *      panel component can render.
 *   4. Detect completion via `finish_reason` and stop the SSE.
 *   5. Clean up the SSE on unmount.
 *
 * The composable is a thin wrapper around two existing primitives
 * (`apiFetch` for the history, `createUnifiedSseConnection` for the
 * live stream). The panel component (`SubAgentPeekPanel.vue`) is
 * presentational — it only renders props.
 */
import { onMounted, onUnmounted, ref, type Ref } from 'vue'
import { apiFetch, createUnifiedSseConnection, type SseClient, type SseEvent, type Message } from '../api'

/** Inputs the composable needs to open a peek. */
export interface UseSubAgentPeekOptions {
  sessionId: string
  agentName: string
  instruction: string
}

/** Current lifecycle state of the peek. */
export type PeekStatus = 'idle' | 'loading' | 'streaming' | 'complete' | 'error'

/** Public surface of the composable (the panel reads these). */
export interface UseSubAgentPeekReturn {
  messages: Ref<Message[]>
  status: Ref<PeekStatus>
  errorMessage: Ref<string | null>
  totalTokens: Ref<number>
  /** Force a manual reload (wired to the "Retry" button in the error banner). */
  reload: () => Promise<void>
}

/**
 * Internal — wraps a single chunk's payload and applies it to the
 * messages ref. Implemented in Chunk 2 (currently a no-op so the
 * skeleton compiles and the initial-fetch test passes).
 */
function applyChunkToMessages(
  _messages: Ref<Message[]>,
  _ev: SseEvent,
  _totalTokens: Ref<number>,
  _status: Ref<PeekStatus>,
): void {
  // TODO Chunk 2: find-or-append the message matching ev.id; if
  // tool_call_id is set, append a new tool result message; flip
  // status to 'complete' on finish_reason.
}

export function useSubAgentPeek(opts: UseSubAgentPeekOptions): UseSubAgentPeekReturn {
  const messages = ref<Message[]>([]) as Ref<Message[]>
  const status = ref<PeekStatus>('idle') as Ref<PeekStatus>
  const errorMessage = ref<string | null>(null) as Ref<string | null>
  const totalTokens = ref(0) as Ref<number>

  let sseClient: SseClient | null = null

  async function fetchInitial(): Promise<void> {
    status.value = 'loading'
    errorMessage.value = null
    try {
      // We fetch in ASC order so messages render in chronological
      // order. Limit 100 covers typical sub-agent runs (a single
      // tool-using loop rarely exceeds 50 messages).
      const data = await apiFetch<{
        messages: Message[]
        has_more: boolean
        next_cursor: string | null
      }>(`/llm/session/${opts.sessionId}/messages?sort_by=created_at&direction=asc&limit=100`, {
        silent: true,
      })
      messages.value = Array.isArray(data.messages) ? data.messages : []

      // If the most recent message has a finish_reason, the
      // sub-agent already finished before we opened the panel.
      // Otherwise we need the SSE for live updates.
      const last = messages.value[messages.value.length - 1]
      if (last && last.finish_reason) {
        status.value = 'complete'
        closeSse()
      } else {
        status.value = 'streaming'
        openSse()
      }
    } catch (err) {
      errorMessage.value = err instanceof Error ? err.message : String(err)
      status.value = 'error'
    }
  }

  function openSse(): void {
    sseClient = createUnifiedSseConnection({
      channels: {
        llm: {
          sessionId: opts.sessionId,
          onEvent: (ev: SseEvent) => {
            applyChunkToMessages(messages, ev, totalTokens, status)
          },
        },
      },
    })
  }

  function closeSse(): void {
    if (sseClient) {
      sseClient.close()
      sseClient = null
    }
  }

  onMounted(() => {
    void fetchInitial()
  })

  onUnmounted(() => {
    closeSse()
  })

  return {
    messages,
    status,
    errorMessage,
    totalTokens,
    reload: fetchInitial,
  }
}
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
 * Internal — wraps a single SSE chunk and applies it to the messages
 * ref. The chunk shapes we care about:
 *
 *   1. role='assistant' with id=X, content='partial'
 *      → find the message with id=X (or append a new one) and APPEND
 *        content to it; if finish_reason is set, mark status=complete.
 *   2. role='assistant' with tool_calls attached to id=X
 *      → attach the tool_calls payload to the assistant message with
 *        id=X (so the panel can render the tool-cards inline).
 *   3. role='tool' with tool_call_id='call_xyz', content='result'
 *      → append a NEW tool-result message; paired by tool_call_id to
 *        the assistant's tool_calls entry.
 *
 * The function is intentionally permissive (tolerant of nullable
 * fields) because the SSE can race with the initial REST fetch —
 * the server may emit a chunk for a message that's already in
 * `messages`. The find-by-id path uses immutable splice so Vue
 * picks up the change reliably.
 *
 * Note: `ev.tool_calls` (SSE wire field) is renamed to
 * `tool_calls_json` (Message interface field) on the wire boundary.
 */
function applyChunkToMessages(
  messages: Ref<Message[]>,
  ev: SseEvent,
  totalTokens: Ref<number>,
  status: Ref<PeekStatus>,
): void {
  // Token-usage accounting — applied regardless of role.
  if (typeof ev.total_tokens === 'number' && !Number.isNaN(ev.total_tokens)) {
    totalTokens.value = ev.total_tokens
  }

  // Tool-result chunks — always create a NEW message keyed by
  // tool_call_id (the panel groups them with the assistant call).
  if (ev.role === 'tool' && ev.tool_call_id) {
    // Cast role='tool' through unknown — the public Message interface
    // doesn't list 'tool' as a role (only user/assistant/system), but
    // tool-result messages do arrive on the wire in practice.
    const newMsg = {
      id: ev.id ?? `tool-${ev.tool_call_id}`,
      role: 'tool',
      content: ev.content ?? '',
      created_at: ev.created_at ?? Math.floor(Date.now() / 1000),
      tool_call_id: ev.tool_call_id,
      tool_name: ev.tool_name,
      finish_reason: ev.finish_reason ?? undefined,
    } as unknown as Message
    messages.value = [...messages.value, newMsg]
  } else {
    // Assistant / user chunks — find-or-create by ev.id.
    const chunkId = ev.id
    const existingIdx = chunkId
      ? messages.value.findIndex((m) => m.id === chunkId)
      : -1

    if (existingIdx >= 0) {
      // Append / update the existing message in place (immutable splice).
      const existing = messages.value[existingIdx]!
      const updated: Message = {
        ...existing,
        content: (existing.content ?? '') + (ev.content ?? ''),
        finish_reason: ev.finish_reason ?? existing.finish_reason,
        // tool_calls_json / tool_name arrive on the assistant turn that
        // emits a tool call; preserve them across subsequent content chunks.
        tool_calls_json: (ev as { tool_calls?: unknown }).tool_calls ?? existing.tool_calls_json,
        tool_name: ev.tool_name ?? existing.tool_name,
      }
      const arr = messages.value.slice()
      arr[existingIdx] = updated
      messages.value = arr
    } else {
      // No matching id — append a new message.
      if (ev.content || (ev as { tool_calls?: unknown }).tool_calls || ev.role) {
        const newMsg = {
          id: ev.id ?? `sse-${Math.floor(Date.now() / 1000)}-${Math.random().toString(36).slice(2, 8)}`,
          role: (ev.role as Message['role']) ?? 'assistant',
          content: ev.content ?? '',
          created_at: ev.created_at ?? Math.floor(Date.now() / 1000),
          tool_name: ev.tool_name,
          tool_calls_json: (ev as { tool_calls?: unknown }).tool_calls,
          finish_reason: ev.finish_reason ?? undefined,
        } as Message
        messages.value = [...messages.value, newMsg]
      }
    }
  }

  // Completion detection — applied to any chunk that carries a
  // finish_reason. Note: a `finish_reason: 'tool_calls'` means
  // "assistant stopped to await a tool result", which we count as
  // complete for the panel UI (the sub-agent will either come back
  // with the tool result SSE or fail). A `finish_reason: 'stop'` is
  // the terminal state.
  if (
    ev.finish_reason === 'stop' ||
    ev.finish_reason === 'length' ||
    ev.finish_reason === 'tool_calls' ||
    ev.finish_reason === 'content_filter'
  ) {
    status.value = 'complete'
  }
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
/**
 * Tests for the useSubAgentPeek composable (skeleton — Chunk 1).
 *
 * Mocks global.fetch to assert the initial history call shape and
 * the messages ref updates. The SSE/chunk-accumulation behavior is
 * covered by Chunk 2 tests.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { defineComponent, h, nextTick } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'
import { useSubAgentPeek } from '../composables/useSubAgentPeek'
import { createUnifiedSseConnection } from '../api'
import type { Message, SseClient } from '../api'

// Spy on the SSE factory so we can assert it's called (or not) and
// grab the close() fn without spinning up a real EventSource. We
// only stub the function, not the whole module — the composable
// still calls apiFetch via real fetch.
vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    createUnifiedSseConnection: vi.fn(
      (): SseClient => ({
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open',
        onStateChange: () => () => {},
      }),
    ),
  }
})

const mockedCreateUnified = vi.mocked(createUnifiedSseConnection)

describe('useSubAgentPeek (skeleton)', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    fetchMock.mockReset()
    mockedCreateUnified.mockClear()
    global.fetch = fetchMock as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.clearAllMocks()
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  // Build a Message[] with permissive typing — the backend sends
  // `finish_reason: null` for in-progress messages even though the
  // TypeScript interface declares it as `string | undefined`. We
  // build the realistic shape here and cast at the boundary.
  function msgs(rows: Array<Partial<Message> & { id: string; role: Message['role']; content: string; created_at: number }>): Message[] {
    return rows as unknown as Message[]
  }

  function mountWith(options: Parameters<typeof useSubAgentPeek>[0]) {
    let peek: ReturnType<typeof useSubAgentPeek> | null = null
    const Comp = defineComponent({
      setup() {
        peek = useSubAgentPeek(options)
        return () => h('div')
      },
    })
    const wrapper = mount(Comp)
    return { wrapper, get peek() { return peek! } }
  }

  it('fetches the initial history from /llm/session/{sid}/messages', async () => {
    const messages = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
      {
        id: 'm2',
        role: 'assistant',
        content: 'OK, starting…',
        created_at: 1001,
        finish_reason: null as unknown as string, // backend sends null for in-progress
      },
    ])
    mockFetchOnce(200, { messages, has_more: false, next_cursor: null })

    const { peek } = mountWith({
      sessionId: 'subagent_1_foo',
      agentName: 'foo',
      instruction: 'do X',
    })

    expect(peek.status.value).toBe('loading')
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url] = fetchMock.mock.calls[0] as [string]
    expect(url).toContain('/llm/session/subagent_1_foo/messages')
    expect(url).toContain('sort_by=created_at')
    expect(url).toContain('direction=asc')
    expect(peek.messages.value).toHaveLength(2)
    expect(peek.messages.value[0]?.id).toBe('m1')
    // Last message has no finish_reason → SSE should open
    expect(peek.status.value).toBe('streaming')
    expect(mockedCreateUnified).toHaveBeenCalledTimes(1)
  })

  it('marks status=complete when the latest message already has finish_reason', async () => {
    const messages = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
      {
        id: 'm2',
        role: 'assistant',
        content: 'all done',
        created_at: 1001,
        finish_reason: 'stop',
      },
    ])
    mockFetchOnce(200, { messages, has_more: false, next_cursor: null })

    const { peek } = mountWith({
      sessionId: 'subagent_2_bar',
      agentName: 'bar',
      instruction: 'do X',
    })
    await flushPromises()

    expect(peek.status.value).toBe('complete')
    // No SSE for an already-completed sub-agent
    expect(mockedCreateUnified).not.toHaveBeenCalled()
  })

  it('marks status=error when the initial fetch throws', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network down'))
    // The apiFetch wrapper turns a rejected fetch into an ApiError
    // via the !response.ok branch — emulate that with a non-ok
    // response.
    fetchMock.mockReset()
    fetchMock.mockResolvedValueOnce({
      ok: false,
      status: 500,
      statusText: 'Internal Server Error',
      text: () => Promise.resolve('boom'),
      json: () => Promise.reject(new Error('not json')),
    } as Response)

    const { peek } = mountWith({
      sessionId: 'subagent_3_baz',
      agentName: 'baz',
      instruction: 'do X',
    })
    await flushPromises()

    expect(peek.status.value).toBe('error')
    expect(peek.errorMessage.value).toContain('500')
    expect(mockedCreateUnified).not.toHaveBeenCalled()
  })

  it('reloads via the public reload() action', async () => {
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })
    mockFetchOnce(200, { messages: [], has_more: false, next_cursor: null })

    const { peek } = mountWith({
      sessionId: 'subagent_4_qux',
      agentName: 'qux',
      instruction: 'do X',
    })
    await flushPromises()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    await peek.reload()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('closes the SSE connection on unmount', async () => {
    const messages = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
    ])
    mockFetchOnce(200, { messages, has_more: false, next_cursor: null })

    const { wrapper, peek } = mountWith({
      sessionId: 'subagent_5_quux',
      agentName: 'quux',
      instruction: 'do X',
    })
    await flushPromises()
    expect(peek.status.value).toBe('streaming')

    const sseInstance = mockedCreateUnified.mock.results[0]?.value as SseClient | undefined
    expect(sseInstance).toBeTruthy()
    const closeSpy = sseInstance!.close as ReturnType<typeof vi.fn>

    wrapper.unmount()
    // After unmount the composable's onUnmounted handler should have
    // called close() on the SSE.
    expect(closeSpy).toHaveBeenCalled()
  })

  it('exposes a reactive totalTokens ref that defaults to 0', () => {
    const { peek } = mountWith({
      sessionId: 'subagent_6_corge',
      agentName: 'corge',
      instruction: 'do X',
    })
    expect(peek.totalTokens.value).toBe(0)
  })

  // ── Chunk 2 — chunk accumulation tests ──────────────────────────────────
  // Use the wired SSE onEvent callback to simulate streaming chunks
  // arriving for an open sub-agent.

  /**
   * Drive streaming chunks via the registered SSE callback. Returns
   * the composable's peek so callers can assert on the final state.
   */
  async function runChunkScenario(
    initialMessages: Message[],
    chunks: Array<{
      id?: string
      role?: 'user' | 'assistant' | 'system' | 'tool'
      content?: string
      tool_calls_json?: unknown
      tool_call_id?: string
      tool_name?: string
      finish_reason?: string
      total_tokens?: number
    }>,
  ) {
    mockFetchOnce(200, { messages: initialMessages, has_more: false, next_cursor: null })
    const { peek } = mountWith({
      sessionId: 'subagent_chunk_test',
      agentName: 'chunk-test',
      instruction: 'do X',
    })
    await flushPromises()

    const sseCall = mockedCreateUnified.mock.calls[0]?.[0]
    expect(sseCall).toBeTruthy()
    const onEvent = (
      sseCall as { channels: { llm: { onEvent: (ev: unknown) => void } } }
    ).channels.llm.onEvent

    for (const chunk of chunks) {
      onEvent(chunk as unknown as Parameters<typeof onEvent>[0])
      await nextTick()
    }
    return peek
  }

  it('appends a content chunk to an in-progress assistant message (find-or-create by id)', async () => {
    const initial = msgs([
      { id: 'm1', role: 'user', content: 'do X', created_at: 1000 },
    ])
    const peek = await runChunkScenario(initial, [
      // First SSE chunk for assistant message id=a1 — creates it
      { id: 'a1', role: 'assistant', content: 'Hello' },
      // Second chunk — appends to the existing a1
      { id: 'a1', role: 'assistant', content: ' world' },
      // Third chunk with finish_reason — closes the bubble
      { id: 'a1', role: 'assistant', content: '!', finish_reason: 'stop' },
    ])

    expect(peek.messages.value).toHaveLength(2)
    const last = peek.messages.value[peek.messages.value.length - 1]!
    expect(last.id).toBe('a1')
    expect(last.content).toBe('Hello world!')
    expect(last.finish_reason).toBe('stop')
    expect(peek.status.value).toBe('complete')
  })

  it('creates a new message when SSE chunk has no matching id', async () => {
    // No initial fetch — patch fetchMock to return empty
    fetchMock.mockReset()
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ messages: [], has_more: false, next_cursor: null }),
      text: () => Promise.resolve('{"messages":[]}'),
    } as Response)

    const { peek } = mountWith({
      sessionId: 'subagent_new_msg',
      agentName: 'new-msg',
      instruction: 'do X',
    })
    await flushPromises()

    const sseCall = mockedCreateUnified.mock.calls[0]?.[0] as {
      channels: { llm: { onEvent: (ev: unknown) => void } }
    }
    sseCall.channels.llm.onEvent({ id: 'x1', role: 'tool', content: 'r', tool_call_id: 'call_1' })
    await nextTick()

    expect(peek.messages.value).toHaveLength(1)
    expect(peek.messages.value[0]?.role).toBe('tool')
    expect(peek.messages.value[0]?.tool_call_id).toBe('call_1')
  })

  it('tracks total_tokens from SSE chunks', async () => {
    const initial = msgs([
      { id: 'a1', role: 'assistant', content: '', created_at: 1000 },
    ])
    const peek = await runChunkScenario(initial, [
      { id: 'a1', role: 'assistant', content: 'partial', total_tokens: 4217 },
      { id: 'a1', role: 'assistant', content: 'more', total_tokens: 5102, finish_reason: 'stop' },
    ])

    expect(peek.totalTokens.value).toBe(5102)
  })

  it('keeps status=streaming while chunks arrive without finish_reason', async () => {
    const initial = msgs([{ id: 'a1', role: 'assistant', content: '', created_at: 1000 }])
    const peek = await runChunkScenario(initial, [
      { id: 'a1', role: 'assistant', content: 'chunk 1' },
      { id: 'a1', role: 'assistant', content: 'chunk 2' },
    ])
    expect(peek.status.value).toBe('streaming')
  })

  it('marks complete on tool_calls finish_reason (sub-agent waits for tool result next)', async () => {
    const initial = msgs([
      { id: 'a1', role: 'assistant', content: '', created_at: 1000 },
    ])
    const peek = await runChunkScenario(initial, [
      {
        id: 'a1',
        role: 'assistant',
        content: 'calling tool',
        finish_reason: 'tool_calls',
      },
    ])
    expect(peek.status.value).toBe('complete')
  })
})
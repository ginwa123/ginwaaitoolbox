import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import * as api from '../api'
import LlmHistorySettings from '../components/llm/LlmHistorySettings.vue'

vi.mock('../api', () => ({
  getChats: vi.fn(),
  getLlmHistory: vi.fn(),
}))

const mockGetChats = api.getChats as unknown as ReturnType<typeof vi.fn>
const mockGetLlmHistory = api.getLlmHistory as unknown as ReturnType<typeof vi.fn>

const makeSessions = () => ({
  sessions: [
    { session_id: 'sess_2', session_name: 'Second Chat' },
    { session_id: 'sess_1', session_name: 'First Chat' },
  ],
  has_more: false,
  next_cursor: null,
  total: 2,
})

const makeHistoryResponse = (overrides: Partial<ReturnType<typeof api.getLlmHistory> extends Promise<infer T> ? T : never> = {}) => ({
  session_id: 'sess_2',
  model: 'gpt-4o',
  url_style: 'openai',
  chain: [
    { role: 'system' as const, content: 'You are helpful', id: null },
    { role: 'user' as const, content: 'hello', id: 'h1', created_at: '2026-09-01 10:00:00' },
    { role: 'assistant' as const, content: 'hi there', id: 'a1', reasoning_content: 'thinking...', tool_calls: [{ name: 'bash', arguments: '{}' }] },
    { role: 'tool' as const, content: 'tool output', id: 't1', tool_call_id: 'call_123', tool_name: 'bash' },
  ],
  curl: {
    anthropic: "curl -X POST 'https://api.anthropic.com/v1/messages' -H 'Authorization: Bearer sk-...****' -d '{\"model\":\"gpt-4o\"}'",
    openai: "curl -X POST 'https://api.openai.com/v1/chat/completions' -H 'Authorization: Bearer sk-...****' -d '{\"model\":\"gpt-4o\"}'",
    openai_response: "curl -X POST 'https://api.openai.com/v1/responses' -H 'Authorization: Bearer sk-...****' -d '{\"model\":\"gpt-4o\"}'",
  },
  bodies: {
    anthropic: { model: 'gpt-4o', messages: [] },
    openai: { model: 'gpt-4o', messages: [] },
    openai_response: { model: 'gpt-4o', input: [] },
  },
  ...overrides,
})

describe('LlmHistorySettings', () => {
  let clipboardWriteText: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockGetChats.mockReset()
    mockGetLlmHistory.mockReset()
    clipboardWriteText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: clipboardWriteText },
      writable: true,
      configurable: true,
    })
  })

  it('fetches sessions on mount and defaults to most-recent', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    expect(mockGetChats).toHaveBeenCalledTimes(1)
    // Most-recent is first in list (sess_2)
    expect(mockGetLlmHistory).toHaveBeenCalledWith('sess_2')
    expect(wrapper.text()).toContain('Second Chat')
  })

  it('shows session picker with name + id', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    // Open dropdown
    await wrapper.find('[data-testid="session-picker-trigger"]').trigger('click')
    await flushPromises()

    const options = wrapper.findAll('[data-testid="session-picker-option"]')
    expect(options).toHaveLength(2)
    expect(options[0]!.text()).toContain('Second Chat')
    expect(options[0]!.text()).toContain('sess_2')
    expect(options[1]!.text()).toContain('First Chat')
  })

  it('filters sessions via search input', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    await wrapper.find('[data-testid="session-picker-trigger"]').trigger('click')
    await flushPromises()

    const search = wrapper.find('[data-testid="session-picker-search"]')
    await search.setValue('First')
    await flushPromises()

    const options = wrapper.findAll('[data-testid="session-picker-option"]')
    expect(options).toHaveLength(1)
    expect(options[0]!.text()).toContain('First Chat')
  })

  it('switching session fetches new history', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())
    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    // Second history response for sess_1
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse({ session_id: 'sess_1', chain: [{ role: 'user', content: 'other' }] }))

    await wrapper.find('[data-testid="session-picker-trigger"]').trigger('click')
    await flushPromises()
    const options = wrapper.findAll('[data-testid="session-picker-option"]')
    // Click second option (sess_1)
    await options[1]!.trigger('click')
    await flushPromises()

    expect(mockGetLlmHistory).toHaveBeenCalledWith('sess_1')
  })

  it('renders chain cards with role badges', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    const cards = wrapper.findAll('[data-testid="chain-card"]')
    expect(cards).toHaveLength(4)
    expect(cards[0]!.attributes('data-role')).toBe('system')
    expect(cards[1]!.attributes('data-role')).toBe('user')
    expect(cards[2]!.attributes('data-role')).toBe('assistant')
    expect(cards[3]!.attributes('data-role')).toBe('tool')
  })

  it('system message is expanded by default, others collapsed', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    // System (idx 0) expanded — content visible
    expect(wrapper.find('[data-testid="chain-card-content-0"]').exists()).toBe(true)
    // User (idx 1) collapsed — content not visible
    expect(wrapper.find('[data-testid="chain-card-content-1"]').exists()).toBe(false)
  })

  it('toggles card expansion on header click', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    // User card collapsed initially
    expect(wrapper.find('[data-testid="chain-card-content-1"]').exists()).toBe(false)
    await wrapper.find('[data-testid="chain-card-header-1"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="chain-card-content-1"]').exists()).toBe(true)
  })

  it('shows reasoning_content in amber block for assistant', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    // Assistant card (idx 2) is collapsed initially — expand it
    await wrapper.find('[data-testid="chain-card-header-2"]').trigger('click')
    await flushPromises()

    const reasoning = wrapper.find('[data-testid="chain-card-reasoning-2"]')
    expect(reasoning.exists()).toBe(true)
    expect(reasoning.text()).toContain('thinking...')
  })

  it('shows tool_calls JSON for assistant', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    await wrapper.find('[data-testid="chain-card-header-2"]').trigger('click')
    await flushPromises()

    const toolCalls = wrapper.find('[data-testid="chain-card-tool-calls-2"]')
    expect(toolCalls.exists()).toBe(true)
    expect(toolCalls.text()).toContain('bash')
  })

  it('shows tool_call_id and tool_name for tool role', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    await wrapper.find('[data-testid="chain-card-header-3"]').trigger('click')
    await flushPromises()

    expect(wrapper.find('[data-testid="chain-card-tool-call-id-3"]').text()).toContain('call_123')
    expect(wrapper.find('[data-testid="chain-card-tool-name-3"]').text()).toContain('bash')
  })

  it('renders 3 curl tabs and switches between them', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    expect(wrapper.find('[data-testid="curl-tab-anthropic"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="curl-tab-openai"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="curl-tab-openai_response"]').exists()).toBe(true)

    // Default is anthropic
    expect(wrapper.find('[data-testid="curl-pre"]').text()).toContain('/v1/messages')

    await wrapper.find('[data-testid="curl-tab-openai"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="curl-pre"]').text()).toContain('/v1/chat/completions')

    await wrapper.find('[data-testid="curl-tab-openai_response"]').trigger('click')
    await flushPromises()
    expect(wrapper.find('[data-testid="curl-pre"]').text()).toContain('/v1/responses')
  })

  it('copy curl button writes to clipboard and shows Copied!', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    const btn = wrapper.find('[data-testid="copy-curl-btn"]')
    expect(btn.text()).toBe('Copy curl')
    await btn.trigger('click')
    await flushPromises()

    expect(clipboardWriteText).toHaveBeenCalledWith(expect.stringContaining('/v1/messages'))
    expect(wrapper.find('[data-testid="copy-curl-btn"]').text()).toBe('Copied!')
  })

  it('copy JSON button writes pretty JSON to clipboard', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse())

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    const btn = wrapper.find('[data-testid="copy-json-btn"]')
    await btn.trigger('click')
    await flushPromises()

    expect(clipboardWriteText).toHaveBeenCalledWith(expect.stringContaining('"model"'))
    expect(wrapper.find('[data-testid="copy-json-btn"]').text()).toBe('Copied!')
  })

  it('shows loading spinner while fetching history', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    // Never resolve history — keep loading
    let resolveHistory!: (v: unknown) => void
    mockGetLlmHistory.mockReturnValueOnce(new Promise(r => { resolveHistory = r }))

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    // After sessions loaded, history fetch is pending
    expect(wrapper.find('[data-testid="history-loading"]').exists()).toBe(true)

    resolveHistory(makeHistoryResponse())
    await flushPromises()
    expect(wrapper.find('[data-testid="history-loading"]').exists()).toBe(false)
  })

  it('shows empty state when chain is empty', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockResolvedValueOnce(makeHistoryResponse({ chain: [] }))

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    expect(wrapper.find('[data-testid="history-empty"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="history-empty"]').text()).toContain('No messages yet')
  })

  it('shows error banner on fetch failure', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    mockGetLlmHistory.mockRejectedValueOnce(new Error('session not found'))

    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    const errBanner = wrapper.find('[data-testid="history-error"]')
    expect(errBanner.exists()).toBe(true)
    expect(errBanner.text()).toContain('session not found')
  })

  it('redacted api_key does not leak real key in curl', async () => {
    mockGetChats.mockResolvedValueOnce(makeSessions())
    const resp = makeHistoryResponse()
    // Ensure curl strings contain redacted placeholder, not a real key
    expect(resp.curl.anthropic).toContain('sk-...****')
    expect(resp.curl.anthropic).not.toContain('sk-proj-')

    mockGetLlmHistory.mockResolvedValueOnce(resp)
    const wrapper = mount(LlmHistorySettings)
    await flushPromises()

    expect(wrapper.find('[data-testid="curl-pre"]').text()).toContain('sk-...****')
  })
})

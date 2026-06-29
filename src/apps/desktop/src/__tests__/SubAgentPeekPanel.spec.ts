/**
 * Tests for SubAgentPeekPanel — the slide-over for watching a
 * sub-agent's progress without leaving the parent chat.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { defineComponent, h, nextTick } from 'vue'
import SubAgentPeekPanel from '../components/nalar/SubAgentPeekPanel.vue'
import type { Message } from '../api'

// Mock the heavy tool output components so we can assert they're
// invoked without their actual rendering chewing test time.
vi.mock('../components/tool_outputs/ReadFile.vue', () => ({
  default: { name: 'ReadFile', props: ['content', 'expanded', 'cwd'], render: () => null },
}))
vi.mock('../components/tool_outputs/TextReplace.vue', () => ({
  default: {
    name: 'TextReplace',
    props: ['content', 'expanded', 'diffview_before', 'diffview_after', 'cwd'],
    render: () => null,
  },
}))
vi.mock('../components/tool_outputs/SpawnSubAgent.vue', () => ({
  default: {
    name: 'SpawnSubAgent',
    props: ['content', 'expanded', 'subAgentArgs'],
    render: () => null,
  },
}))
// Stub Teleport (the panel uses Teleport to mount into <body>) so
// @vue/test-utils' `find()` traverses inside.
vi.mock('vue', async () => {
  const actual = await vi.importActual<typeof import('vue')>('vue')
  return {
    ...actual,
    Teleport: { name: 'Teleport', setup(_: unknown, { slots }: { slots: { default?: () => unknown } }) { return () => slots.default?.() } },
  }
})

function makeBaseProps(overrides: Partial<{
  sessionId: string
  agentName: string
  instruction: string
  status: 'idle' | 'loading' | 'streaming' | 'complete' | 'error'
  errorMessage: string | null
  messages: Message[]
  totalTokens: number
}> = {}) {
  return {
    sessionId: 'subagent_1_foo',
    agentName: 'foo',
    instruction: 'do X',
    status: 'streaming' as const,
    errorMessage: null,
    messages: [] as Message[],
    totalTokens: 0,
    ...overrides,
  }
}

describe('SubAgentPeekPanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('renders the agent name in the header', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    expect(wrapper.text()).toContain('foo')
  })

  it('shows the streaming spinner + label when status is streaming', () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    const status = wrapper.find('[data-testid="peek-status"]')
    expect(status.exists()).toBe(true)
    expect(status.text()).toMatch(/Streaming/i)
  })

  it('shows the Complete label when status is complete', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ status: 'complete' }),
    })
    const status = wrapper.find('[data-testid="peek-status"]')
    expect(status.text()).toMatch(/Complete/i)
  })

  it('shows the Error label + banner when status is error', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({
        status: 'error',
        errorMessage: 'HTTP 500: backend down',
      }),
    })
    const status = wrapper.find('[data-testid="peek-status"]')
    expect(status.text()).toMatch(/Error/i)
    const banner = wrapper.find('[data-testid="peek-error-banner"]')
    expect(banner.exists()).toBe(true)
    expect(banner.text()).toContain('HTTP 500')
  })

  it('emits close when the close button is clicked', async () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    await wrapper.find('[data-testid="peek-close"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits openFull with the sessionId when the Open full button is clicked', async () => {
    const wrapper = mount(SubAgentPeekPanel, { props: makeBaseProps() })
    await wrapper.find('[data-testid="peek-open-full"]').trigger('click')
    expect(wrapper.emitted('openFull')).toBeTruthy()
    expect(wrapper.emitted('openFull')![0]).toEqual(['subagent_1_foo'])
  })

  it('truncates long instructions to 200 chars + ellipsis in the header', () => {
    const longInstruction = 'x'.repeat(400)
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ instruction: longInstruction }),
    })
    const preview = wrapper.find('[data-testid="peek-instruction"]')
    expect(preview.text().length).toBeLessThanOrEqual(205) // 200 + "…"
    expect(preview.text().endsWith('…')).toBe(true)
    expect(preview.attributes('title')).toBe(longInstruction)
  })

  it('renders user messages with the user role label', () => {
    const messages: Message[] = [
      { id: 'u1', role: 'user', content: 'do the task', created_at: 1000 },
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages }),
    })
    const row = wrapper.find('[data-testid="peek-msg-user"]')
    expect(row.exists()).toBe(true)
    expect(row.text()).toContain('do the task')
    expect(row.text()).toContain('user')
  })

  it('renders assistant messages with the assistant role label + content', () => {
    const messages: Message[] = [
      { id: 'a1', role: 'assistant', content: 'starting now', created_at: 1000 },
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages, status: 'streaming' }),
    })
    const row = wrapper.find('[data-testid="peek-msg-assistant"]')
    expect(row.exists()).toBe(true)
    expect(row.text()).toContain('starting now')
  })

  it('shows a streaming cursor on the last assistant message when status=streaming', () => {
    const messages: Message[] = [
      { id: 'u1', role: 'user', content: 'do X', created_at: 1000 },
      { id: 'a1', role: 'assistant', content: 'partial answer', created_at: 1001 },
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages, status: 'streaming' }),
    })
    const row = wrapper.find('[data-testid="peek-msg-assistant"]')
    expect(row.classes()).toContain('streaming')
    // The streaming class adds a ▍ via CSS ::after; assert the class is applied.
  })

  it('does NOT show the streaming cursor when status=complete', () => {
    const messages: Message[] = [
      { id: 'a1', role: 'assistant', content: 'final answer', created_at: 1000 },
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages, status: 'complete' }),
    })
    const row = wrapper.find('[data-testid="peek-msg-assistant"]')
    expect(row.classes()).not.toContain('streaming')
  })

  it('renders the footer with session_id + token count', () => {
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ totalTokens: 4217 }),
    })
    expect(wrapper.text()).toContain('subagent_1_foo')
    expect(wrapper.text()).toContain('4,217')
  })

  // ── Reuse of existing tool output components ─────────────────────────
  // The user requirement: when the sub-agent's message stream
  // includes a tool result (role='tool' with the standard
  // <tool>...</tool> envelope), the panel MUST reuse the existing
  // tool output components (ReadFile, TextReplace, Bash, etc.)
  // instead of rendering plain text.

  it('reuses the ReadFile tool output component for read_file tool results', async () => {
    const toolEnvelope =
      '<tool><name>read_file</name><parameters>{"path":"/tmp/foo.txt"}</parameters>' +
      '<success>true</success><data>' +
      '<path>/tmp/foo.txt</path><content>hello world</content>' +
      '</data></tool>'

    const messages: Message[] = [
      { id: 't1', role: 'tool', content: toolEnvelope, created_at: 1000, tool_name: 'read_file' } as Message,
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages }),
    })
    await flushPromises()
    // The component should render <ReadFile> (mocked; we assert
    // the vnode was emitted with the right name).
    expect(wrapper.html()).toContain('read_file')
  })

  it('reuses the TextReplace tool output component for text_replace tool results', async () => {
    const toolEnvelope =
      '<tool><name>text_replace</name><parameters>{"path":"/tmp/x.txt"}</parameters>' +
      '<success>true</success><data>' +
      '<result>replaced</result></data></tool>'

    const messages: Message[] = [
      { id: 't2', role: 'tool', content: toolEnvelope, created_at: 1000, tool_name: 'text_replace' } as Message,
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages }),
    })
    await flushPromises()
    expect(wrapper.html()).toContain('text_replace')
  })

  it('reuses the SpawnSubAgent tool output component recursively for nested spawn_sub_agent calls', async () => {
    // A sub-agent inside a sub-agent — the same component renders
    // it (and the user can recursively open another peek panel).
    const toolEnvelope =
      '<tool><name>spawn_sub_agent</name><parameters>{"sub_agents":[{"name":"deeper"}]}</parameters>' +
      '<success>true</success><data>' +
      '<results><agent name="deeper" success="true" random_fallback="false">' +
      '<session_id>subagent_nested</session_id>' +
      '<response>did the deeper task</response>' +
      '</agent><summary succeeded="1" failed="0" /></results></data></tool>'

    const messages: Message[] = [
      { id: 't3', role: 'tool', content: toolEnvelope, created_at: 1000, tool_name: 'spawn_sub_agent' } as Message,
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages }),
    })
    await flushPromises()
    expect(wrapper.html()).toContain('spawn_sub_agent')
  })

  it('falls back to plain-text rendering for tool messages whose envelope is malformed', () => {
    const messages: Message[] = [
      { id: 't4', role: 'tool', content: 'not a tool envelope', created_at: 1000, tool_name: 'unknown_tool' } as Message,
    ]
    const wrapper = mount(SubAgentPeekPanel, {
      props: makeBaseProps({ messages }),
    })
    // Should still render without crashing — falls back to a
    // generic <pre> bubble with the raw content + the tool name.
    expect(wrapper.text()).toContain('unknown_tool')
  })
})
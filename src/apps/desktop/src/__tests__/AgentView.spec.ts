// Behavioural tests for AgentView. Mounts the component with stub
// props and asserts the wired emits + conditional rendering.

import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentView from '../components/views/AgentView.vue'
import * as api from '../api'
import { useAgentToolsStore } from '../stores/agentTools'

const baseItem = { id: 'item_1', name: 'My Agent', path: '/tmp' }
const baseProps = () => ({
  item: baseItem,
  workspaceId: 'ws_1',
  itemId: 'item_1',
  knowledge: [] as api.AgentKnowledgeRow[],
  tools: [] as string[],
})

describe('AgentView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue({
      tools: [
        { name: 'bash', description: 'Run shell commands' },
        { name: 'read_file', description: 'Read a file' },
      ],
    })
  })

  it('renders Knowledge panel with empty state when no entries', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    expect(wrapper.find('[data-testid="agent-knowledge-panel"]').exists()).toBe(true)
    expect(wrapper.text()).toContain('No knowledge files yet')
  })

  it('emits addKnowledge when + Add is clicked', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    await wrapper.find('[data-testid="agent-add-knowledge"]').trigger('click')
    expect(wrapper.emitted('addKnowledge')).toBeTruthy()
  })

  it('renders knowledge items with remove button', async () => {
    const wrapper = mount(AgentView, {
      props: {
        ...baseProps(),
        knowledge: [
          {
            id: 'k_1',
            agent_id: 'item_1',
            file_path: '/home/me/spec.md',
            label: 'Spec',
            position: 0,
            created_at: '',
            updated_at: '',
          },
        ],
      },
    })
    await nextTick()
    const items = wrapper.findAll('[data-testid="agent-knowledge-item"]')
    expect(items.length).toBe(1)
    await wrapper.find('[data-testid="agent-remove-knowledge"]').trigger('click')
    expect(wrapper.emitted('removeKnowledge')![0]).toEqual(['k_1'])
  })

  it('renders Tools panel with registry checkboxes', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    // Wait for the registry fetch to settle.
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const tools = wrapper.findAll('[data-testid="agent-tool-item"]')
    expect(tools.length).toBe(2)
    expect(wrapper.text()).toContain('bash')
    expect(wrapper.text()).toContain('read_file')
  })

  it('emits toggleTool with (name, enabled) on checkbox change', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const bashCheckbox = wrapper.find('[data-testid="agent-tool-checkbox-bash"]')
    expect(bashCheckbox.exists()).toBe(true)
    await bashCheckbox.setValue(true)
    expect(wrapper.emitted('toggleTool')![0]).toEqual(['bash', true])
  })

  it('emits newChat when New Chat button clicked', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    await wrapper.find('[data-testid="agent-new-chat"]').trigger('click')
    expect(wrapper.emitted('newChat')).toBeTruthy()
  })
})
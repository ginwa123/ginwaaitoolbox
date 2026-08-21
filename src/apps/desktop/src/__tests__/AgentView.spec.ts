// Behavioural tests for AgentView. Mounts the component with stub
// props and asserts the wired emits + conditional rendering.

import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'
import AgentView from '../components/views/AgentView.vue'
import * as api from '../api'

const baseItem = { id: 'item_1', name: 'My Agent', path: '/tmp', item_type: 'agent' }
const baseProps = () => ({
  item: baseItem,
  workspaceId: 'ws_1',
  itemId: 'item_1',
  knowledge: [] as api.AgentKnowledgeRow[],
  tools: [] as string[],
})

const mockRegistry = {
  tools: [
    { name: 'bash', description: 'Run shell commands' },
    { name: 'read_file', description: 'Read a file from disk' },
    { name: 'write_file', description: 'Write content to disk' },
    { name: 'kanban_list', description: 'List kanban columns and tasks' },
  ],
}

describe('AgentView', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue(mockRegistry)
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

  it('renders knowledge count chip with the entry count', async () => {
    const wrapper = mount(AgentView, {
      props: {
        ...baseProps(),
        knowledge: [
          {
            id: 'k_1',
            agent_id: 'item_1',
            file_path: '/home/me/spec.md',
            label: 'Spec',
            content: '',
            position: 0,
            created_at: '',
            updated_at: '',
          },
        ],
      },
    })
    await nextTick()
    const chip = wrapper.find('[data-testid="agent-knowledge-count"]')
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toBe('1')
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
            content: '',
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

  it('renders an Inline text badge for content rows instead of a file path', async () => {
    const wrapper = mount(AgentView, {
      props: {
        ...baseProps(),
        knowledge: [
          {
            id: 'k_inline',
            agent_id: 'item_1',
            file_path: '',
            label: 'Notes',
            content: 'Manual knowledge body for the agent to read.',
            position: 0,
            created_at: '',
            updated_at: '',
          },
        ],
      },
    })
    await nextTick()
    const item = wrapper.find('[data-testid="agent-knowledge-item"]')
    expect(item.exists()).toBe(true)
    // Label shown as the title.
    expect(item.text()).toContain('Notes')
    // "Inline text" badge present.
    expect(item.text()).toContain('Inline text')
    // No absolute path rendered.
    expect(item.text()).not.toContain('/')
  })

  it('renders Tools panel with registry checkboxes', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    // Wait for the registry fetch to settle.
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const tools = wrapper.findAll('[data-testid="agent-tool-item"]')
    expect(tools.length).toBe(4)
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

  it('shows the enabled tools count chip as `N / total`', async () => {
    const wrapper = mount(AgentView, {
      props: { ...baseProps(), tools: ['bash', 'read_file'] },
    })
    await nextTick()
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const chip = wrapper.find('[data-testid="agent-tools-count"]')
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toBe('2 / 4')
  })

  it('renders an ON chip for enabled tools', async () => {
    const wrapper = mount(AgentView, {
      props: { ...baseProps(), tools: ['bash'] },
    })
    await nextTick()
    await new Promise((r) => setTimeout(r, 50))
    await nextTick()
    const enabledChips = wrapper.findAll('[data-testid="agent-tool-enabled-chip"]')
    expect(enabledChips.length).toBe(1)
  })

  describe('search filter', () => {
    it('filters the tools list by name (case-insensitive)', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('BASH')
      await nextTick()
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(1)
      expect(visible[0]!.text()).toContain('bash')
    })

    it('filters the tools list by description', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('kanban')
      await nextTick()
      const visible = wrapper.findAll('[data-testid="agent-tool-item"]')
      expect(visible.length).toBe(1)
      expect(visible[0]!.text()).toContain('kanban_list')
    })

    it('shows the empty-search state when no tools match', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('zzzzz')
      await nextTick()
      const empty = wrapper.find('[data-testid="agent-tools-empty-search"]')
      expect(empty.exists()).toBe(true)
      expect(wrapper.findAll('[data-testid="agent-tool-item"]').length).toBe(0)
    })

    it('updates the filter-status text to reflect matches', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('file')
      await nextTick()
      const status = wrapper.find('[data-testid="agent-tools-filter-status"]')
      expect(status.text()).toContain('2')
    })
  })

  describe('bulk ops', () => {
    it('Select all emits toggleToolsBulk with all un-enabled tools', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-select-all"]')
      expect((btn.element as HTMLButtonElement).hasAttribute('disabled')).toBe(false)
      await btn.trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')
      expect(events).toBeTruthy()
      const [names, enabled] = events![0] as [string[], boolean]
      expect(enabled).toBe(true)
      expect(names.sort()).toEqual(['kanban_list', 'read_file', 'write_file'].sort())
    })

    it('Select all is disabled when every visible tool is already enabled', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash', 'read_file', 'write_file', 'kanban_list'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-select-all"]')
      expect((btn.element as HTMLButtonElement).hasAttribute('disabled')).toBe(true)
    })

    it('Clear emits toggleToolsBulk with all enabled tools', async () => {
      const wrapper = mount(AgentView, {
        props: { ...baseProps(), tools: ['bash', 'read_file'] },
      })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-clear-all"]')
      await btn.trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')
      expect(events).toBeTruthy()
      const [names, enabled] = events![0] as [string[], boolean]
      expect(enabled).toBe(false)
      expect(names.sort()).toEqual(['bash', 'read_file'].sort())
    })

    it('Clear is disabled when no visible tools are enabled', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-clear-all"]')
      expect((btn.element as HTMLButtonElement).hasAttribute('disabled')).toBe(true)
    })

    it('Select all only includes the filtered (visible) tools', async () => {
      const wrapper = mount(AgentView, { props: baseProps() })
      await nextTick()
      await new Promise((r) => setTimeout(r, 50))
      await nextTick()
      const search = wrapper.find('[data-testid="agent-tools-search"]')
      await search.setValue('file')
      await nextTick()
      const btn = wrapper.find('[data-testid="agent-tools-select-all"]')
      await btn.trigger('click')
      const events = wrapper.emitted('toggleToolsBulk')!
      const [names, enabled] = events[0] as [string[], boolean]
      expect(enabled).toBe(true)
      expect(names.sort()).toEqual(['read_file', 'write_file'].sort())
    })
  })

  it('emits newChat when New Chat button clicked', async () => {
    const wrapper = mount(AgentView, { props: baseProps() })
    await nextTick()
    await wrapper.find('[data-testid="agent-new-chat"]').trigger('click')
    expect(wrapper.emitted('newChat')).toBeTruthy()
  })
})
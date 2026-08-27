// Behavioural tests for KanbanToolsPanel — the per-board tool
// allowlist panel (extracted from KanbanAgentPanel in iteration 2 of
// the kanban-agent-as-tab plan: 2026-08-27). Mounted as the
// ?tab=tools tab body inside KanbanSettingsView. Hosts ONLY the tools
// checkbox grid; knowledge + system prompts live in KanbanKnowledgePanel.

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanToolsPanel from '@/components/views/KanbanToolsPanel.vue'
import * as api from '@/api'
import type { AgentKanban, AgentRegistryEntry } from '@/api'

const kanbanItem = { id: 'wi_kanban', name: 'Sprint 12' }
const baseProps = () => ({ item: kanbanItem, workspaceId: 'ws_1' })

const mockRegistry: { tools: AgentRegistryEntry[] } = {
  tools: [
    { name: 'bash', description: 'Run shell commands' },
    { name: 'read_file', description: 'Read a file from disk' },
    { name: 'write_file', description: 'Write content to disk' },
  ],
}

const configuredBundle = {
  agent_kanban: {
    id: 'wi_kanban',
    workspace_item_id: 'wi_kanban',
    description: '',
    created_at: '2026-08-27T10:00:00Z',
    updated_at: '2026-08-27T10:00:00Z',
  } satisfies AgentKanban,
  knowledges: [],
  tools: ['bash'] as string[],
  system_prompts: [],
}

let wrapper: VueWrapper | null = null

function mountPanel(props = baseProps()) {
  wrapper = mount(KanbanToolsPanel, { props, attachTo: document.body })
  return wrapper
}

function maybeQ<T extends Element = HTMLElement>(testid: string): T | null {
  return document.querySelector<T>(`[data-testid="${testid}"]`)
}

function q<T extends Element = HTMLElement>(testid: string): T {
  const el = maybeQ<T>(testid)
  if (!el) throw new Error(`missing [data-testid="${testid}"]`)
  return el
}

afterEach(() => {
  wrapper?.unmount()
  wrapper = null
})

describe('KanbanToolsPanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue(mockRegistry)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(configuredBundle)
  })

  it('renders the tools checkbox grid once data loads', async () => {
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-agent-tools-panel')).not.toBeNull()
  })

  it('renders one checkbox per registry tool, marked checked when in the enabled list', async () => {
    mountPanel()
    await flushPromises()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    expect(bashCheckbox.checked).toBe(true)
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    expect(readFileCheckbox.checked).toBe(false)
  })

  it('calls enableAgentKanbanTool when a disabled checkbox is toggled on', async () => {
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)
    mountPanel()
    await flushPromises()
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    readFileCheckbox.checked = true
    readFileCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    expect(enableSpy).toHaveBeenCalledWith('wi_kanban', 'read_file')
  })

  it('calls disableAgentKanbanTool when an enabled checkbox is toggled off', async () => {
    const disableSpy = vi
      .spyOn(api, 'disableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.disableAgentKanbanTool>>)
    mountPanel()
    await flushPromises()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    bashCheckbox.checked = false
    bashCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    expect(disableSpy).toHaveBeenCalledWith('wi_kanban', 'bash')
  })

  it('shows the unconfigured empty state with a tools picker when no agent_kanban row exists', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(null)
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-tools-unconfigured')).not.toBeNull()
    const tools = document.querySelectorAll('[data-testid^="kanban-agent-tool-"]')
    expect(tools.length).toBeGreaterThanOrEqual(mockRegistry.tools.length)
  })

  it('does NOT render knowledge or system-prompt sections (those moved to KanbanKnowledgePanel)', async () => {
    mountPanel()
    await flushPromises()
    expect(maybeQ('kanban-agent-knowledge-panel')).toBeNull()
    expect(maybeQ('kanban-agent-system-prompt-panel')).toBeNull()
  })
})

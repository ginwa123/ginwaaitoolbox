// Behavioural tests for KanbanAgentPanel — the body content of the
// per-board agent config (Knowledge / System Prompt / Tools) that
// lives as a tab inside the KanbanSettingsView page. Extracted from
// KanbanAgentSettings.vue (the centered modal that used to host
// these sections); the chrome (Teleport + backdrop + close button)
// is gone, the body is byte-identical.
//
// Pattern (mirrors AgentKnowledgeDetailDialog.spec.ts): sub-dialogs
// (AgentKnowledgeDialog / AgentKnowledgeDetailDialog /
// AgentSystemPromptDialog) Teleport to body, so we mount the panel
// with attachTo: document.body and assert teleported DOM via
// document.querySelector. The panel body itself is inline, so
// wrapper.find works for the 3 sections.
//
// Plan: docs/superpowers/plans/2026-08-27-kanban-agent-as-tab.md

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { flushPromises } from '@vue/test-utils'
import { nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'

import KanbanAgentPanel from '@/components/views/KanbanAgentPanel.vue'
import * as api from '@/api'
import type {
  AgentKanban,
  AgentKanbanKnowledgeRow,
  AgentKanbanSystemPromptRow,
  AgentRegistryEntry,
} from '@/api'

const kanbanItem = { id: 'wi_kanban', name: 'Sprint 12' }

const baseProps = () => ({
  item: kanbanItem,
  workspaceId: 'ws_1',
})

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
  knowledges: [] as AgentKanbanKnowledgeRow[],
  tools: ['bash'] as string[],
  system_prompts: [] as AgentKanbanSystemPromptRow[],
}

let wrapper: VueWrapper | null = null

function mountPanel(props = baseProps()) {
  wrapper = mount(KanbanAgentPanel, {
    props,
    attachTo: document.body,
  })
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

/** Teleported sub-dialog cleanup — sub-dialogs Teleport to body and
 * survive parent unmount, so explicitly remove them between tests. */
function removeTeleportedSubdialogs() {
  document
    .querySelectorAll(
      '[data-testid="agent-knowledge-dialog"], [data-testid="agent-knowledge-detail-dialog"], [data-testid="agent-system-prompt-dialog"]',
    )
    .forEach((el) => el.remove())
}

afterEach(() => {
  wrapper?.unmount()
  wrapper = null
  removeTeleportedSubdialogs()
})

describe('KanbanAgentPanel', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue(mockRegistry)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(configuredBundle)
  })

  it('renders the 3 sections (Knowledge / System Prompt / Tools) once data loads', async () => {
    mountPanel()
    await flushPromises()
    await nextTick()
    expect(maybeQ('kanban-agent-knowledge-panel')).not.toBeNull()
    expect(maybeQ('kanban-agent-system-prompt-panel')).not.toBeNull()
    expect(maybeQ('kanban-agent-tools-panel')).not.toBeNull()
  })

  it('shows the loading indicator while the bundle is in-flight', async () => {
    // Defer the bundle resolution so we can observe the loading state.
    let resolveBundle!: (b: typeof configuredBundle) => void
    vi.spyOn(api, 'getAgentKanban').mockReturnValue(
      new Promise((res) => {
        resolveBundle = res
      }) as unknown as ReturnType<typeof api.getAgentKanban>,
    )
    mountPanel()
    await nextTick()
    expect(maybeQ('kanban-agent-settings-loading')).not.toBeNull()
    resolveBundle(configuredBundle)
    await flushPromises()
    await nextTick()
    expect(maybeQ('kanban-agent-settings-loading')).toBeNull()
    expect(maybeQ('kanban-agent-knowledge-panel')).not.toBeNull()
  })

  it('shows the unconfigured empty state (tools picker) when no agent_kanban row exists', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue(null)
    mountPanel()
    await flushPromises()
    await nextTick()
    expect(maybeQ('kanban-agent-settings-unconfigured')).not.toBeNull()
    // Tools picker still renders inside the unconfigured state.
    const tools = document.querySelectorAll('[data-testid^="kanban-agent-tool-"]')
    expect(tools.length).toBeGreaterThanOrEqual(mockRegistry.tools.length)
  })

  it('renders tool checkboxes for the registry, marked checked when in the enabled list', async () => {
    mountPanel()
    await flushPromises()
    await nextTick()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    expect(bashCheckbox.checked).toBe(true)
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    expect(readFileCheckbox.checked).toBe(false)
  })

  it('calls enableAgentKanbanTool when a disabled checkbox is toggled on, and the checkbox stays checked', async () => {
    const enableSpy = vi
      .spyOn(api, 'enableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.enableAgentKanbanTool>>)
    mountPanel()
    await flushPromises()
    await nextTick()
    const readFileCheckbox = q<HTMLInputElement>(
      'kanban-agent-tool-check-read_file',
    ) as HTMLInputElement
    expect(readFileCheckbox.checked).toBe(false)
    readFileCheckbox.checked = true
    readFileCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    await nextTick()
    expect(enableSpy).toHaveBeenCalledWith('wi_kanban', 'read_file')
    // After enable, the bundle re-renders with read_file in the enabled list.
    expect(q<HTMLInputElement>('kanban-agent-tool-check-read_file').checked).toBe(true)
  })

  it('calls disableAgentKanbanTool when an enabled checkbox is toggled off', async () => {
    const disableSpy = vi
      .spyOn(api, 'disableAgentKanbanTool')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.disableAgentKanbanTool>>)
    mountPanel()
    await flushPromises()
    await nextTick()
    const bashCheckbox = q<HTMLInputElement>('kanban-agent-tool-check-bash') as HTMLInputElement
    expect(bashCheckbox.checked).toBe(true)
    bashCheckbox.checked = false
    bashCheckbox.dispatchEvent(new Event('change'))
    await flushPromises()
    await nextTick()
    expect(disableSpy).toHaveBeenCalledWith('wi_kanban', 'bash')
    expect(q<HTMLInputElement>('kanban-agent-tool-check-bash').checked).toBe(false)
  })

  it('renders existing knowledge rows with label and edit/remove buttons', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      knowledges: [
        {
          id: 'k_1',
          kanban_id: 'wi_kanban',
          file_path: '/home/me/spec.md',
          label: 'Spec',
          content: '',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    await nextTick()
    const row = q('kanban-agent-knowledge-row-k_1')
    expect(row.textContent).toContain('Spec')
    expect(maybeQ('kanban-agent-knowledge-edit-k_1')).not.toBeNull()
    expect(maybeQ('kanban-agent-knowledge-remove-k_1')).not.toBeNull()
  })

  it('calls deleteAgentKanbanKnowledge when the remove button is clicked and removes the row', async () => {
    const deleteSpy = vi
      .spyOn(api, 'deleteAgentKanbanKnowledge')
      .mockResolvedValue({ ok: true } as Awaited<ReturnType<typeof api.deleteAgentKanbanKnowledge>>)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      knowledges: [
        {
          id: 'k_1',
          kanban_id: 'wi_kanban',
          file_path: '/home/me/spec.md',
          label: 'Spec',
          content: '',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    await nextTick()
    const removeBtn = q<HTMLButtonElement>('kanban-agent-knowledge-remove-k_1')
    removeBtn.click()
    await flushPromises()
    await nextTick()
    expect(deleteSpy).toHaveBeenCalledWith('wi_kanban', 'k_1')
    expect(maybeQ('kanban-agent-knowledge-row-k_1')).toBeNull()
  })

  it('renders existing system-prompt rows with title and edit/remove buttons', async () => {
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      system_prompts: [
        {
          id: 'p_1',
          kanban_id: 'wi_kanban',
          title: 'Persona',
          content: 'You are a senior engineer.',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    await nextTick()
    const row = q('kanban-agent-system-prompt-row-p_1')
    expect(row.textContent).toContain('Persona')
    expect(maybeQ('kanban-agent-system-prompt-edit-p_1')).not.toBeNull()
    expect(maybeQ('kanban-agent-system-prompt-remove-p_1')).not.toBeNull()
  })

  it('calls deleteAgentKanbanSystemPrompt when the remove button is clicked and removes the row', async () => {
    const deleteSpy = vi
      .spyOn(api, 'deleteAgentKanbanSystemPrompt')
      .mockResolvedValue({} as Awaited<ReturnType<typeof api.deleteAgentKanbanSystemPrompt>>)
    vi.spyOn(api, 'getAgentKanban').mockResolvedValue({
      ...configuredBundle,
      system_prompts: [
        {
          id: 'p_1',
          kanban_id: 'wi_kanban',
          title: 'Persona',
          content: 'You are a senior engineer.',
          position: 0,
          created_at: '',
          updated_at: '',
        },
      ],
    })
    mountPanel()
    await flushPromises()
    await nextTick()
    const removeBtn = q<HTMLButtonElement>('kanban-agent-system-prompt-remove-p_1')
    removeBtn.click()
    await flushPromises()
    await nextTick()
    expect(deleteSpy).toHaveBeenCalledWith('wi_kanban', 'p_1')
    expect(maybeQ('kanban-agent-system-prompt-row-p_1')).toBeNull()
  })

  it('opens the knowledge-add sub-dialog when the + Add button is clicked', async () => {
    mountPanel()
    await flushPromises()
    await nextTick()
    const addBtn = q<HTMLButtonElement>('kanban-agent-knowledge-add')
    addBtn.click()
    await nextTick()
    expect(maybeQ('agent-knowledge-dialog')).not.toBeNull()
  })

  it('opens the system-prompt-add sub-dialog when the + Add button is clicked', async () => {
    mountPanel()
    await flushPromises()
    await nextTick()
    const addBtn = q<HTMLButtonElement>('kanban-agent-system-prompt-add')
    addBtn.click()
    await nextTick()
    expect(maybeQ('agent-system-prompt-dialog')).not.toBeNull()
  })
})

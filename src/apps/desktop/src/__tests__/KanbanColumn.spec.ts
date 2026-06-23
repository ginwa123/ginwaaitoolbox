/**
 * Tests for KanbanColumn — a single column with header (inline rename
 * + count badge + ⋮ menu), cards list, footer "+ Add" button, and
 * drop zone.
 *
 * Mounts with provide: { processingState } (KanbanCard → WorkspaceItemTask
 * injects it). The dragstart/drop handlers are exercised in KanbanView
 * tests; here we focus on the column-level UX: header rendering,
 * inline rename, menu open/close, footer add, card filtering.
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 6 / Task 6.4
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import KanbanColumn from '../components/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnType, Task } from '../stores/workspaces'

const COL_TODO = 'col_todo'
const COL_DONE = 'col_done'

const makeColumn = (overrides: Partial<KanbanColumnType> = {}): KanbanColumnType => ({
  id: COL_TODO,
  workspace_item_id: 'item_1',
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'My Task',
  ...overrides,
})

function mountColumn(
  column: KanbanColumnType,
  tasks: Task[] = [],
  workspaceId = 'ws_1',
  itemId = 'item_1',
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanColumn, {
    props: { column, tasks, workspaceId, itemId },
    global: {
      provide: { processingState },
    },
  })
}

describe('KanbanColumn — header rendering', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('shows the column name', () => {
    wrapper = mountColumn(makeColumn())
    const nameBtn = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-name"]`)
    expect(nameBtn.exists()).toBe(true)
    expect(nameBtn.text()).toBe('todo')
  })

  it('shows the card count badge', () => {
    wrapper = mountColumn(makeColumn(), [
      makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
      makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 1 }),
      makeTask({ id: 't3', kanban_column_id: COL_DONE, kanban_position: 0 }),
    ])
    const countBadge = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-count"]`)
    expect(countBadge.text()).toBe('2')
  })

  it('renders cards filtered by kanban_column_id', () => {
    wrapper = mountColumn(makeColumn(), [
      makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 0 }),
      makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 1 }),
      makeTask({ id: 't3', kanban_column_id: COL_DONE, kanban_position: 0 }),
    ])
    // Two cards in this column (t1, t2); t3 is in another column and
    // should NOT be rendered here.
    const cards = wrapper.findAll(`[data-kanban-card]`)
    expect(cards).toHaveLength(2)
    expect(cards[0]!.attributes('data-kanban-card')).toBe('t1')
    expect(cards[1]!.attributes('data-kanban-card')).toBe('t2')
  })

  it('renders cards sorted by kanban_position', () => {
    wrapper = mountColumn(makeColumn(), [
      makeTask({ id: 't1', kanban_column_id: COL_TODO, kanban_position: 2 }),
      makeTask({ id: 't2', kanban_column_id: COL_TODO, kanban_position: 0 }),
      makeTask({ id: 't3', kanban_column_id: COL_TODO, kanban_position: 1 }),
    ])
    const cards = wrapper.findAll(`[data-kanban-card]`)
    expect(cards.map((c) => c.attributes('data-kanban-card'))).toEqual([
      't2',
      't3',
      't1',
    ])
  })

  it('renders the "No tasks yet" placeholder when the column is empty', () => {
    wrapper = mountColumn(makeColumn(), [])
    const empty = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-empty"]`)
    expect(empty.exists()).toBe(true)
    expect(empty.text()).toContain('No tasks yet')
  })
})

describe('KanbanColumn — inline rename', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking the name starts an inline rename (shows input)', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-name"]`).trigger('click')
    await nextTick()
    const input = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-rename-input"]`)
    expect(input.exists()).toBe(true)
    // Pre-filled with the current column name
    expect((input.element as HTMLInputElement).value).toBe('todo')
  })

  it('Enter saves the new name and emits rename-column', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-name"]`).trigger('click')
    await nextTick()
    const input = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-rename-input"]`)
    await input.setValue('Backlog')
    await input.trigger('keyup', { key: 'Enter' })
    expect(wrapper.emitted('renameColumn')?.[0]).toEqual([
      { columnId: COL_TODO, name: 'Backlog' },
    ])
  })

  it('Escape cancels the rename and does NOT emit', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-name"]`).trigger('click')
    await nextTick()
    const input = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-rename-input"]`)
    await input.setValue('Discarded')
    await input.trigger('keyup', { key: 'Escape' })
    expect(wrapper.emitted('renameColumn')).toBeUndefined()
  })

  it('whitespace-only rename does not emit', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-name"]`).trigger('click')
    await nextTick()
    const input = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-rename-input"]`)
    await input.setValue('   ')
    await input.trigger('keyup', { key: 'Enter' })
    expect(wrapper.emitted('renameColumn')).toBeUndefined()
  })

  it('unchanged rename does not emit (no-op)', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-name"]`).trigger('click')
    await nextTick()
    const input = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-rename-input"]`)
    // Don't change the value
    await input.trigger('keyup', { key: 'Enter' })
    expect(wrapper.emitted('renameColumn')).toBeUndefined()
  })
})

describe('KanbanColumn — ⋮ menu', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking the trigger opens the menu', async () => {
    wrapper = mountColumn(makeColumn())
    expect(
      wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu"]`).exists(),
    ).toBe(false)
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    expect(
      wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu"]`).exists(),
    ).toBe(true)
  })

  it('clicking Rename emits request-rename-column', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-rename"]`).trigger('click')
    expect(wrapper.emitted('requestRenameColumn')?.[0]).toEqual([COL_TODO])
  })

  it('clicking Delete emits request-delete-column', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-delete"]`).trigger('click')
    expect(wrapper.emitted('requestDeleteColumn')?.[0]).toEqual([COL_TODO])
  })
})

describe('KanbanColumn — footer add', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking "+ Add" emits add-task with the column id', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-add-task"]`).trigger('click')
    expect(wrapper.emitted('addTask')?.[0]).toEqual([COL_TODO])
  })
})
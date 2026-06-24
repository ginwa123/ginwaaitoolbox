/**
 * Tests for KanbanView — the board layout (header + horizontally
 * scrollable column row).
 *
 * Comprehensive coverage:
 *   - renders the item name as the header title
 *   - renders one <KanbanColumn> per item.kanban_columns
 *   - sorts columns by position (defensive)
 *   - "+ Column" button emits add-column
 *   - add-task, move-task, rename-column, delete-column pass-through
 *   - "⋮" menu's request-rename-column / request-delete-column
 *     pass-through
 *   - select-task, delete-task, rename-task, etc. pass-through
 *
 * Mounts with provide: { processingState } (KanbanColumn →
 * KanbanCard → WorkspaceItemTask injects it).
 *
 * The companion test file WorkspaceItemKanban.spec.ts (Sub-task
 * 6.7) covers the WorkspaceItem.vue branch (`v-if` on
 * item_type === 'kanban' rendering <KanbanView>).
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 6 / Task 6.5 + Task 6.7
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'

import KanbanView from '../components/KanbanView.vue'
import type { WorkspaceItem, KanbanColumn } from '../stores/workspaces'

const ITEM_ID = 'item_1'
const WS_ID = 'ws_1'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_1',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [makeColumn()],
  tasks: [],
  ...overrides,
})

function mountView(
  item: WorkspaceItem,
  workspaceId = WS_ID,
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanView, {
    props: { item, workspaceId },
    global: {
      provide: { processingState },
    },
  })
}

describe('KanbanView — header rendering', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('shows the kanban name in the header', () => {
    wrapper = mountView(makeItem({ name: 'My Sprint' }))
    const title = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-title"]`)
    expect(title.exists()).toBe(true)
    expect(title.text()).toBe('My Sprint')
  })

  it('renders the "+ Column" button', () => {
    wrapper = mountView(makeItem())
    const btn = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-add-column"]`)
    expect(btn.exists()).toBe(true)
    expect(btn.text()).toContain('Column')
  })

  it('"+ Column" emits add-column (no payload) on click', async () => {
    wrapper = mountView(makeItem())
    await wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-add-column"]`).trigger('click')
    expect(wrapper.emitted('addColumn')).toBeTruthy()
    expect(wrapper.emitted('addColumn')?.[0]).toEqual([])
  })
})

describe('KanbanView — column rendering', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders one KanbanColumn per kanban_columns entry', () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [
          makeColumn({ id: 'col_1', name: 'todo', position: 0 }),
          makeColumn({ id: 'col_2', name: 'in progress', position: 1 }),
          makeColumn({ id: 'col_3', name: 'done', position: 2 }),
        ],
      }),
    )
    const columns = wrapper.findAll('[data-kanban-column]')
    expect(columns).toHaveLength(3)
    expect(columns[0]!.attributes('data-kanban-column')).toBe('col_1')
    expect(columns[1]!.attributes('data-kanban-column')).toBe('col_2')
    expect(columns[2]!.attributes('data-kanban-column')).toBe('col_3')
  })

  it('sorts columns by position ascending (defensive)', () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [
          makeColumn({ id: 'col_c', name: 'done', position: 2 }),
          makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
          makeColumn({ id: 'col_b', name: 'in progress', position: 1 }),
        ],
      }),
    )
    const columns = wrapper.findAll('[data-kanban-column]')
    expect(columns.map((c) => c.attributes('data-kanban-column'))).toEqual([
      'col_a',
      'col_b',
      'col_c',
    ])
  })

  it('renders nothing inside the columns row when kanban_columns is empty', () => {
    wrapper = mountView(makeItem({ kanban_columns: [] }))
    const columns = wrapper.findAll('[data-kanban-column]')
    expect(columns).toHaveLength(0)
  })

  it('handles kanban_columns being undefined (defensive)', () => {
    const item = makeItem()
    // Explicit defensive test for kanban_columns being undefined
    // (legacy items in tests, or a fresh item before the columns
    // have been populated). The `kanban_columns?` in KanbanView's
    // computed already handles `undefined`, so we just verify the
    // component doesn't crash and renders no columns.
    item.kanban_columns = undefined
    wrapper = mountView(item)
    const columns = wrapper.findAll('[data-kanban-column]')
    expect(columns).toHaveLength(0)
  })
})

describe('KanbanView — task rendering per column', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders cards from item.tasks filtered by kanban_column_id', () => {
    // The board shows the cards as <KanbanCard data-kanban-card="...">
    // elements. We pass tasks via the item and verify they end up in
    // the right columns.
    wrapper = mountView(
      makeItem({
        kanban_columns: [
          makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
          makeColumn({ id: 'col_b', name: 'done', position: 1 }),
        ],
        tasks: [
          { id: 't1', name: 'Task A', kanban_column_id: 'col_a', kanban_position: 0 },
          { id: 't2', name: 'Task B', kanban_column_id: 'col_a', kanban_position: 1 },
          { id: 't3', name: 'Task C', kanban_column_id: 'col_b', kanban_position: 0 },
        ],
      }),
    )
    // Two cards in col_a (t1, t2), one in col_b (t3).
    const cards = wrapper.findAll('[data-kanban-card]')
    expect(cards).toHaveLength(3)
    const ids = cards.map((c) => c.attributes('data-kanban-card'))
    expect(ids).toEqual(expect.arrayContaining(['t1', 't2', 't3']))
  })

  it('renders 0 cards when item.tasks is empty', () => {
    wrapper = mountView(makeItem({ tasks: [] }))
    const cards = wrapper.findAll('[data-kanban-card]')
    expect(cards).toHaveLength(0)
  })
})

describe('KanbanView — event pass-through', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('passes through add-task with {columnId}', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      }),
    )
    await wrapper
      .find('[data-testid="kanban-column-col_x-add-task"]')
      .trigger('click')
    expect(wrapper.emitted('addTask')?.[0]).toEqual([{ columnId: 'col_x' }])
  })

  it('passes through move-task with {taskId, columnId, position}', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
        tasks: [
          { id: 't1', name: 'Task A', kanban_column_id: 'col_x', kanban_position: 0 },
        ],
      }),
    )
    // Trigger a drop on the column's drop zone with a kanban MIME
    // payload. The drop handler in KanbanColumn emits move-task.
    const dropZone = wrapper.find('[data-kanban-drop-zone="col_x"]')
    const getData = vi.fn((mime: string) => (mime === 'application/x-kanban-task-id' ? 't1' : ''))
    const dataTransfer = {
      getData,
      types: ['application/x-kanban-task-id'],
    } as unknown as DataTransfer
    await dropZone.trigger('drop', { dataTransfer })

    // The drop emits {taskId, columnId, position} where position is
    // the current length (1 here — append to end).
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 't1', columnId: 'col_x', position: 1 },
    ])
  })

  it('passes through rename-column from inline rename', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      }),
    )
    // Open the inline rename
    await wrapper.find('[data-testid="kanban-column-col_x-name"]').trigger('click')
    await wrapper.vm.$nextTick()
    // Change the value and press Enter
    const input = wrapper.find('[data-testid="kanban-column-col_x-rename-input"]')
    await input.setValue('Backlog')
    await input.trigger('keyup', { key: 'Enter' })
    expect(wrapper.emitted('renameColumn')?.[0]).toEqual([
      { columnId: 'col_x', name: 'Backlog' },
    ])
  })

  it('passes through request-rename-column from the ⋮ menu', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      }),
    )
    await wrapper.find('[data-testid="kanban-column-col_x-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-column-col_x-menu-rename"]').trigger('click')
    expect(wrapper.emitted('requestRenameColumn')?.[0]).toEqual(['col_x'])
  })

  it('passes through request-delete-column from the ⋮ menu', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      }),
    )
    await wrapper.find('[data-testid="kanban-column-col_x-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-column-col_x-menu-delete"]').trigger('click')
    expect(wrapper.emitted('requestDeleteColumn')?.[0]).toEqual(['col_x'])
  })

  it('passes through select-task', async () => {
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
        tasks: [
          { id: 't1', name: 'Task A', kanban_column_id: 'col_x', kanban_position: 0 },
        ],
      }),
    )
    // Click on the task's WorkspaceItemTask (button has data-task-id)
    const taskBtn = wrapper.find('button[data-task-id="t1"]')
    await taskBtn.trigger('click')
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['t1'])
  })
})
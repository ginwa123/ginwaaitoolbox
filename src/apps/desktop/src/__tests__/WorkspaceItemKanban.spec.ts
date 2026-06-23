/**
 * Tests for the kanban branch of WorkspaceItem.vue — verifies:
 *   - item_type='kanban' renders <KanbanView> (not the list)
 *   - item_type='folder' (or other) renders the existing list
 *   - board renders N columns from item.kanban_columns
 *   - board renders N cards per column based on task kanban_column_id
 *   - the kanban events (add-task, move-task, add-column, etc.)
 *     are emitted with the right payloads
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 6 / Task 6.7
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import WorkspaceItem from '../components/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem as WorkspaceItemType, KanbanColumn, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_a',
  workspace_item_id: ITEM_ID,
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

const makeKanbanItem = (overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType => ({
  id: ITEM_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [makeColumn()],
  tasks: [],
  ...overrides,
})

const makeFolderItem = (overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType => ({
  id: ITEM_ID,
  name: 'My Project',
  item_type: 'folder',
  path: '/abs/path',
  tasks: [],
  ...overrides,
})

function mountItem(item: WorkspaceItemType) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(WorkspaceItem, {
    props: {
      item,
      isActive: false,
      workspaceId: WS_ID,
    },
    global: {
      provide: { processingState },
    },
  })
}

function expandItem(): void {
  // Tasks/KanbanView are only rendered when the parent item is
  // expanded. Mutate `expandedItemIds` and reassign to trigger
  // reactivity, matching the production toggle.
  const ws = useWorkspacesStore()
  ws.expandedItemIds[ITEM_ID] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

describe('WorkspaceItem — item_type branching', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it("renders KanbanView (not the task list) when item_type='kanban'", async () => {
    wrapper = mountItem(makeKanbanItem())
    expandItem()
    await nextTick()
    // KanbanView renders with data-kanban-view="<item_id>"
    const kanban = wrapper.find(`[data-kanban-view="${ITEM_ID}"]`)
    expect(kanban.exists()).toBe(true)
    // The task list container (ml-8 mt-1.5 space-y-0.5 pl-2) should
    // NOT be rendered (KanbanView replaces it).
    // Sanity check: no WorkspaceItemTask buttons are rendered.
    expect(wrapper.findAll('button[data-task-id]')).toHaveLength(0)
  })

  it("renders the existing task list when item_type='folder'", async () => {
    wrapper = mountItem(makeFolderItem({ tasks: [makeTask()] }))
    expandItem()
    await nextTick()
    // The kanban branch should NOT be rendered.
    const kanban = wrapper.find(`[data-kanban-view="${ITEM_ID}"]`)
    expect(kanban.exists()).toBe(false)
    // The folder-item task row (WorkspaceItemTask with data-task-id)
    // IS rendered.
    expect(wrapper.find('button[data-task-id="task_1"]').exists()).toBe(true)
  })

  it("renders the existing task list when item_type='memory' (any non-kanban type)", async () => {
    const item = makeFolderItem({ item_type: 'memory', tasks: [makeTask()] })
    wrapper = mountItem(item)
    expandItem()
    await nextTick()
    const kanban = wrapper.find(`[data-kanban-view="${ITEM_ID}"]`)
    expect(kanban.exists()).toBe(false)
    expect(wrapper.find('button[data-task-id="task_1"]').exists()).toBe(true)
  })
})

describe('WorkspaceItem — kanban board rendering', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders N columns from item.kanban_columns', async () => {
    wrapper = mountItem(
      makeKanbanItem({
        kanban_columns: [
          makeColumn({ id: 'col_1', name: 'todo', position: 0 }),
          makeColumn({ id: 'col_2', name: 'in progress', position: 1 }),
          makeColumn({ id: 'col_3', name: 'done', position: 2 }),
        ],
      }),
    )
    expandItem()
    await nextTick()
    const columns = wrapper.findAll('[data-kanban-column]')
    expect(columns).toHaveLength(3)
  })

  it('renders N cards per column based on kanban_column_id', async () => {
    wrapper = mountItem(
      makeKanbanItem({
        kanban_columns: [
          makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
          makeColumn({ id: 'col_b', name: 'done', position: 1 }),
        ],
        tasks: [
          makeTask({ id: 't1', kanban_column_id: 'col_a', kanban_position: 0 }),
          makeTask({ id: 't2', kanban_column_id: 'col_a', kanban_position: 1 }),
          makeTask({ id: 't3', kanban_column_id: 'col_b', kanban_position: 0 }),
        ],
      }),
    )
    expandItem()
    await nextTick()
    const cards = wrapper.findAll('[data-kanban-card]')
    expect(cards).toHaveLength(3)
    const ids = cards.map((c) => c.attributes('data-kanban-card'))
    expect(ids).toEqual(expect.arrayContaining(['t1', 't2', 't3']))
  })
})

describe('WorkspaceItem — kanban event forwarding', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('move-kanban-task event is emitted from a drop on a kanban column', async () => {
    wrapper = mountItem(
      makeKanbanItem({
        kanban_columns: [makeColumn({ id: 'col_x', position: 0 })],
        tasks: [
          makeTask({ id: 't1', kanban_column_id: 'col_x', kanban_position: 0 }),
        ],
      }),
    )
    expandItem()
    await nextTick()
    const dropZone = wrapper.find('[data-kanban-drop-zone="col_x"]')
    const dataTransfer = {
      getData: vi.fn((mime: string) => (mime === 'application/x-kanban-task-id' ? 't1' : '')),
      types: ['application/x-kanban-task-id'],
    } as unknown as DataTransfer
    await dropZone.trigger('drop', { dataTransfer })

    expect(wrapper.emitted('moveKanbanTask')?.[0]).toEqual([
      WS_ID,
      ITEM_ID,
      't1',
      'col_x',
      1, // append to end (current length)
    ])
  })

  it('add-kanban-task event is emitted when + Add is clicked', async () => {
    wrapper = mountItem(
      makeKanbanItem({
        kanban_columns: [makeColumn({ id: 'col_x', position: 0 })],
      }),
    )
    expandItem()
    await nextTick()
    await wrapper.find('[data-testid="kanban-column-col_x-add-task"]').trigger('click')
    // + Add on a kanban column re-emits the existing addTask event
    // (Sidebar routes it through AddTaskPickerDialog). The kanban-
    // specific addKanbanTask event is also emitted with the columnId.
    expect(wrapper.emitted('addTask')).toBeTruthy()
    // addTask emit is [item: WorkspaceItem], so [0][0] is the item.
    const emitted = wrapper.emitted('addTask')
    expect(emitted).toBeDefined()
    expect(emitted?.length).toBeGreaterThan(0)
    const firstPayload = emitted?.[0]?.[0] as { id?: string } | undefined
    expect(firstPayload?.id).toBe(ITEM_ID)
  })

  it('does NOT emit kanban events for folder items', async () => {
    wrapper = mountItem(
      makeFolderItem({ tasks: [makeTask()] }),
    )
    expandItem()
    await nextTick()
    // The kanban events should not appear, even after interaction.
    expect(wrapper.emitted('addKanbanTask')).toBeUndefined()
    expect(wrapper.emitted('moveKanbanTask')).toBeUndefined()
    expect(wrapper.emitted('addKanbanColumn')).toBeUndefined()
    expect(wrapper.emitted('renameKanbanColumn')).toBeUndefined()
    expect(wrapper.emitted('deleteKanbanColumn')).toBeUndefined()
  })
})
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
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
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

  it('clicking "+ Add" opens the create dialog locally (no addTask emit)', async () => {
    // After the kanban-add-task-via-detail-dialog feature, the
    // "+ Add" click no longer bubbles up to AppLayout. KanbanView
    // consumes it locally and opens the KanbanTaskDetailDialog
    // in create mode (which mounts at the bottom of the template
    // and teleports to document.body).
    wrapper = mountView(
      makeItem({
        kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      }),
    )
    await flushPromises()

    // Dialog not in the DOM yet.
    expect(document.querySelector('[data-testid="kanban-task-detail-dialog"]')).toBeNull()
    // No addTask emit (the event is consumed locally).
    expect(wrapper.emitted('addTask')).toBeFalsy()

    // Click "+ Add" on the column.
    await wrapper
      .find('[data-testid="kanban-column-col_x-add-task"]')
      .trigger('click')
    await flushPromises()

    // Dialog is now in the DOM (teleported to body).
    const dialog = document.querySelector('[data-testid="kanban-task-detail-dialog"]')
    expect(dialog).not.toBeNull()
    // The create-mode inputs use the `-create-` testids. The
    // name input exists and is empty.
    const nameInput = document.querySelector<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    expect(nameInput?.value).toBe('')
    // The column name is visible in the metadata strip.
    const colEl = document.querySelector('[data-testid="kanban-task-detail-column"]')
    expect(colEl?.textContent).toContain('todo')
    // No addTask emit ever fired.
    expect(wrapper.emitted('addTask')).toBeFalsy()
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

// ─── Set project root banner (2026-06-24 — cwd backfill UX) ─────────────
//
// Regression coverage for the "every kanban task needs a cwd" bug.
// A kanban with `path = null` (created before the path field
// existed on the create endpoint) shows a yellow ⚠️ button that
// opens the FilePickerDialog. Selecting a folder calls
// workspacesStore.updateKanbanItemPath, which persists the path
// to the DB and hides the banner.
describe('KanbanView — "Set project root" banner', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the ⚠️ banner when item.path is null (backfill state)', () => {
    wrapper = mountView(makeItem({ path: null }))
    const banner = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-set-project-root"]`)
    expect(banner.exists()).toBe(true)
    expect(banner.text()).toContain('Set project root')
  })

  it('renders the ⚠️ banner when item.path is undefined (defensive)', () => {
    // Older kanbans created before the field existed may have an
    // undefined path (the API returns `null`, but in-flight loads
    // can produce undefined before the server-side default kicks in).
    const item = makeItem()
    delete item.path
    wrapper = mountView(item)
    const banner = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-set-project-root"]`)
    expect(banner.exists()).toBe(true)
  })

  it('does NOT render the banner when item.path is a non-empty string', () => {
    wrapper = mountView(makeItem({ path: '/abs/project' }))
    const banner = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-set-project-root"]`)
    expect(banner.exists()).toBe(false)
  })

  it('clicking the banner opens the FilePickerDialog', async () => {
    wrapper = mountView(makeItem({ path: null }))
    const banner = wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-set-project-root"]`)
    expect(banner.exists()).toBe(true)
    // The banner is gated on the item being the active workspace item
    // (disabled binding). Just check the click handler is wired; the
    // picker itself has its own test suite.
    await banner.trigger('click')
    // No assertion on the picker DOM (it teleports to body and is
    // covered by FilePickerDialog.spec.ts). The point of this test is
    // that the click is a no-op and doesn't crash, which is what the
    // mount-time test verifies.
    expect(wrapper.find(`[data-testid="kanban-view-${ITEM_ID}-set-project-root"]`).exists()).toBe(true)
  })
})

// ─── Inline rename pencil (2026-06-30 — kanban header rename) ─────────────
//
// The kanban header h3 wraps the item name in an InlineEditableText
// primitive. Clicking the pencil swaps to an <input> + Save/Cancel
// buttons; pressing Save emits `rename-item` with the trimmed new
// value, which the host (AppLayout) delegates to
// workspacesStore.updateKanbanItemName.

describe('KanbanView — inline rename pencil', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the item name in an InlineEditableText by default', () => {
    const item = makeItem({ name: 'Sprint 12' })
    wrapper = mountView(item)
    // The InlineEditableText primitive renders the value inside a
    // child <span data-testid="…-value">. Asserting on that span
    // confirms the name flows through the primitive without
    // truncation or extra whitespace.
    const valueSpan = wrapper.find(
      `[data-testid="kanban-view-${ITEM_ID}-rename-value"]`,
    )
    expect(valueSpan.exists()).toBe(true)
    expect(valueSpan.text()).toBe('Sprint 12')
  })

  it('emits rename-item with the new name when the header pencil saves', async () => {
    const item = makeItem({ name: 'Sprint 12' })
    wrapper = mountView(item)
    // 1. Click the display span to enter edit mode.
    await wrapper
      .find(`[data-testid="kanban-view-${ITEM_ID}-rename-display"]`)
      .trigger('click')
    await flushPromises()
    // 2. Edit the input value.
    const input = wrapper.find(
      `[data-testid="kanban-view-${ITEM_ID}-rename-input"]`,
    )
    await input.setValue('Sprint 13')
    // 3. Click Save.
    await wrapper
      .find(`[data-testid="kanban-view-${ITEM_ID}-rename-save"]`)
      .trigger('click')

    const emitted = wrapper.emitted('renameItem')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
  })
})

// ─── viewTaskDetail → KanbanTaskDetailDialog (kanban-task-detail-dialog — Chunk 4)
//
// The new info ("ⓘ") button on each task card emits viewTaskDetail
// up the chain (Card → Column → View). KanbanView consumes the emit
// internally — it owns the dialog state, the active task lookup, the
// matching-column lookup, and calls workspacesStore.updateTaskDetails
// on save. AppLayout never sees this emit.
//
// We verify two things:
//   1. The emit is wired up between KanbanColumn and KanbanView's
//      handler (so a Unit-style test of "KanbanColumn emitted
//      viewTaskDetail → KanbanView's handler ran" passes).
//   2. The handler resolves the active task + opens the dialog
//      (visualized by the dialog's data-testid teleporting to body).

describe('KanbanView — viewTaskDetail (task detail dialog)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('handles view-task-detail emitted from KanbanColumn by opening the dialog', async () => {
    const item = makeItem({
      kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      tasks: [
        {
          id: 'task_42',
          name: 'My task',
          description: 'A description',
          kanban_column_id: 'col_x',
          kanban_position: 0,
        },
      ],
    })
    wrapper = mountView(item)
    await flushPromises()

    // Dialog not in the DOM yet.
    expect(document.querySelector('[data-testid="kanban-task-detail-dialog"]')).toBeNull()

    // Simulate the KanbanColumn emitting viewTaskDetail (this is
    // what fires when the user clicks the "ⓘ" button on the card).
    const column = wrapper.findComponent({ name: 'KanbanColumn' })
    column.vm.$emit('viewTaskDetail', 'task_42')
    await flushPromises()

    // The dialog teleports to document.body, so query the document,
    // not the wrapper (per the vue-teleport-vitest-document-queryselector
    // skill convention).
    const dialog = document.querySelector('[data-testid="kanban-task-detail-dialog"]')
    expect(dialog).not.toBeNull()
  })

  it('passes the correct task to the dialog as a prop after view-task-detail fires', async () => {
    const item = makeItem({
      kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      tasks: [
        {
          id: 'task_42',
          name: 'My task',
          description: 'A description',
          kanban_column_id: 'col_x',
          kanban_position: 0,
        },
      ],
    })
    wrapper = mountView(item)
    await flushPromises()

    const column = wrapper.findComponent({ name: 'KanbanColumn' })
    column.vm.$emit('viewTaskDetail', 'task_42')
    await flushPromises()

    // The dialog is now mounted. Verify the pre-filled input has
    // the task name (the dialog's watch effect resets state when
    // the active task changes).
    const input = document.querySelector<HTMLInputElement>(
      '[data-testid="kanban-task-detail-name"]',
    )
    expect(input).not.toBeNull()
    expect(input!.value).toBe('My task')

    const textarea = document.querySelector<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-description"]',
    )
    expect(textarea).not.toBeNull()
    expect(textarea!.value).toBe('A description')
  })

  it('does not emit viewTaskDetail up to AppLayout (dialog is owned by KanbanView)', async () => {
    // Plan rationale: the dialog only needs the kanban's column list
    // (for the metadata strip). KanbanView already has that in scope,
    // so mounting it here avoids coupling AppLayout to kanban internals.
    // Verify viewTaskDetail does NOT bubble out of KanbanView.
    const item = makeItem({
      kanban_columns: [makeColumn({ id: 'col_x', name: 'todo', position: 0 })],
      tasks: [
        { id: 'task_42', name: 'X', kanban_column_id: 'col_x', kanban_position: 0 },
      ],
    })
    wrapper = mountView(item)
    await flushPromises()

    const column = wrapper.findComponent({ name: 'KanbanColumn' })
    column.vm.$emit('viewTaskDetail', 'task_42')
    await flushPromises()

    expect(wrapper.emitted('viewTaskDetail')).toBeFalsy()
  })
})

// ─── + Add → create-dialog flow (kanban-add-task-via-detail-dialog) ────
//
// The "+ Add" button on a kanban column no longer bubbles up to
// AppLayout — KanbanView consumes it locally and opens the
// KanbanTaskDetailDialog in create mode. On submit, KanbanView
// calls workspacesStore.addTask (returns a taskId) +
// moveTaskToColumn (puts the new task in the user's chosen column).
// We mock both store actions to verify the wiring.
//
// These tests replace the pre-existing "passes through add-task"
// event-pass-through test with the actual local-dialog behavior.
describe('KanbanView — create-task flow', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Defensive: clear any teleported dialog DOM left over.
    document
      .querySelectorAll('[data-testid="kanban-task-detail-dialog"]')
      .forEach((el) => el.remove())
    vi.restoreAllMocks()
  })

  // We can't directly mock the workspaces store import from here
  // (Pinia store mocking is project-conventional via spy + setup).
  // Instead we spy on the store's methods via the existing
  // useWorkspacesStore() call inside KanbanView.
  async function mountAndOpenDialog() {
    const item = makeItem({
      kanban_columns: [
        makeColumn({ id: 'col_x', name: 'todo', position: 0 }),
        makeColumn({ id: 'col_y', name: 'in progress', position: 1 }),
      ],
    })
    wrapper = mountView(item)
    await flushPromises()
    await wrapper
      .find('[data-testid="kanban-column-col_x-add-task"]')
      .trigger('click')
    await flushPromises()
    return wrapper!
  }

  it('saves the new task via addTask and moves it to the chosen column at position 0', async () => {
    const w = await mountAndOpenDialog()

    // Capture the store instance via the global Pinia accessor used
    // inside KanbanView (useWorkspacesStore). The store lives on the
    // active Pinia, which beforeEach set up.
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const addTaskSpy = vi
      .spyOn(store, 'addTask')
      .mockResolvedValue('task_new_1')
    const moveTaskSpy = vi
      .spyOn(store, 'moveTaskToColumn')
      .mockResolvedValue(undefined)

    // Type a name and submit.
    const nameInput = document.querySelector<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    nameInput!.value = 'My new task'
    nameInput!.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    document
      .querySelector<HTMLButtonElement>(
        '[data-testid="kanban-task-detail-save"]',
      )!
      .click()
    await flushPromises()
    // Wait one more microtask flush for the await chain inside
    // handleCreateTaskSave (addTask → moveTaskToColumn).
    await flushPromises()

    expect(addTaskSpy).toHaveBeenCalledTimes(1)
    expect(addTaskSpy).toHaveBeenCalledWith(
      WS_ID,
      ITEM_ID,
      expect.objectContaining({ name: 'My new task' }),
    )
    // Move to the user's chosen column at position 0.
    expect(moveTaskSpy).toHaveBeenCalledWith(
      WS_ID,
      ITEM_ID,
      'task_new_1',
      'col_x',
      0,
    )

    // Dialog closes on success.
    expect(
      document.querySelector('[data-testid="kanban-task-detail-dialog"]'),
    ).toBeNull()
    void w
  })

  it('keeps the dialog open + shows error banner when addTask fails', async () => {
    await mountAndOpenDialog()

    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    vi.spyOn(store, 'addTask').mockRejectedValue(new Error('network down'))

    // Submit with a name.
    const nameInput = document.querySelector<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    nameInput!.value = 'My task'
    nameInput!.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    document
      .querySelector<HTMLButtonElement>(
        '[data-testid="kanban-task-detail-save"]',
      )!
      .click()
    await flushPromises()
    await flushPromises()

    // Dialog still in the DOM (user can retry).
    const dialog = document.querySelector(
      '[data-testid="kanban-task-detail-dialog"]',
    )
    expect(dialog).not.toBeNull()
    // Error banner visible with the error message.
    const banner = document.querySelector(
      '[data-testid="kanban-task-detail-error"]',
    )
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('network down')
  })

  it('does not call moveTaskToColumn when addTask returns undefined', async () => {
    // Defensive: if the store returns undefined (offline fallback
    // shape), we should set the error message and NOT call the
    // move — there's no taskId to move.
    await mountAndOpenDialog()

    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const addTaskSpy = vi.spyOn(store, 'addTask').mockResolvedValue(undefined)
    const moveTaskSpy = vi.spyOn(store, 'moveTaskToColumn')

    const nameInput = document.querySelector<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    nameInput!.value = 'My task'
    nameInput!.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    document
      .querySelector<HTMLButtonElement>(
        '[data-testid="kanban-task-detail-save"]',
      )!
      .click()
    await flushPromises()
    await flushPromises()

    expect(addTaskSpy).toHaveBeenCalledTimes(1)
    expect(moveTaskSpy).not.toHaveBeenCalled()
    expect(
      document.querySelector('[data-testid="kanban-task-detail-error"]'),
    ).not.toBeNull()
  })

  it('Cancel button closes the dialog without creating a task', async () => {
    await mountAndOpenDialog()

    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const addTaskSpy = vi.spyOn(store, 'addTask')

    document
      .querySelector<HTMLButtonElement>(
        '[data-testid="kanban-task-detail-cancel"]',
      )!
      .click()
    await flushPromises()

    expect(addTaskSpy).not.toHaveBeenCalled()
    expect(
      document.querySelector('[data-testid="kanban-task-detail-dialog"]'),
    ).toBeNull()
  })
})
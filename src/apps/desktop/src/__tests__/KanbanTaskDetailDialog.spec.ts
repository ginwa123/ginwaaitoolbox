/**
 * Tests for KanbanTaskDetailDialog — focused, edit-in-place task
 * detail view. Used by the kanban tree to edit a task's name +
 * description with optional metadata (column, type, pinned).
 *
 * Mount pattern: same as KanbanSettingsDialog.spec.ts. The dialog
 * uses <Teleport to="body">, so the rendered DOM lives outside
 * wrapper.element. We use `attachTo: document.body` and query the
 * teleported content via `document.querySelector` (NOT `wrapper.find`).
 * `wrapper.emitted` still works because it tracks the vm, not the DOM
 * tree. We use native `el.click()` and `dispatchEvent('input')` for
 * interactions so v-model updates synchronously.
 *
 * Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md
 *   Chunk 3 / Task 3.2
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task, KanbanColumn } from '@/stores/workspaces'

const TASK: Task = {
  id: 'task_test_1',
  name: 'Original name',
  description: 'Original description',
  task_type: 'standard',
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function setInputValue(selector: string, value: string) {
  const el = findInDom<HTMLInputElement | HTMLTextAreaElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

describe('KanbanTaskDetailDialog — render', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Force-remove any leftover teleported DOM from previous test.
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(task: Task | null = TASK, show = true) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show, task },
    })
    return wrapper
  }

  it('does not render the dialog when show=false', async () => {
    mountDialog(TASK, false)
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-dialog"]')).toBeNull()
  })

  it('renders the dialog when show=true and task is provided', async () => {
    mountDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-dialog"]')).not.toBeNull()
  })

  it('pre-fills the name input with the task name', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-name"]',
    )
    expect(input?.value).toBe('Original name')
  })

  it('pre-fills the description textarea with the task description', async () => {
    mountDialog()
    await flushPromises()
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-description"]',
    )
    expect(textarea?.value).toBe('Original description')
  })

  it('pre-fills description with empty string when task has no description', async () => {
    mountDialog({ ...TASK, description: undefined })
    await flushPromises()
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-description"]',
    )
    expect(textarea?.value).toBe('')
  })
})

describe('KanbanTaskDetailDialog — save / cancel', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(task: Task | null = TASK) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task },
    })
    return wrapper
  }

  it('emits save with the trimmed name + raw description', async () => {
    const w = mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-name"]', '  New name  ')
    setInputValue(
      '[data-testid="kanban-task-detail-description"]',
      'New description',
    )
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w!.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      { mode: 'edit', name: 'New name', description: 'New description', tags: [] },
    ])
  })

  it('emits save with description = "" when the textarea is cleared', async () => {
    const w = mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-description"]', '')
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w!.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      { mode: 'edit', name: 'Original name', description: '', tags: [] },
    ])
  })

  it('emits close (not save) when the cancel button is clicked', async () => {
    const w = mountDialog()
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-cancel"]')
    expect(w!.emitted('close')).toBeTruthy()
    expect(w!.emitted('save')).toBeFalsy()
  })

  it('emits update:show=false on close (for v-model:show wiring)', async () => {
    // Regression: KanbanView binds `v-model:show` which requires
    // `update:show` events, not the legacy `close` event. Without
    // this emit, the X / Cancel / backdrop / Escape handlers
    // cannot close the dialog.
    const w = mountDialog()
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-close"]')
    const updates = w!.emitted('update:show')
    expect(updates).toBeTruthy()
    expect(updates![updates!.length - 1]).toEqual([false])
  })

  it('emits update:show=false when the backdrop is clicked', async () => {
    // The backdrop click handler closes the dialog via the same
    // `handleClose` path as the X button — regression net for the
    // @click.self="handleClose" binding on the outer wrapper.
    const w = mountDialog()
    await flushPromises()
    const backdrop = findInDom<HTMLDivElement>(
      '[data-testid="kanban-task-detail-dialog"] > .backdrop-blur-md',
    )
    expect(backdrop).not.toBeNull()
    backdrop!.click()
    const updates = w!.emitted('update:show')
    expect(updates).toBeTruthy()
    expect(updates![updates!.length - 1]).toEqual([false])
  })

  it('disables save when name is empty (after trim)', async () => {
    mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-name"]', '   ') // whitespace only
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('disables save when nothing changed (clean form)', async () => {
    mountDialog()
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('enables save when the name OR description changed', async () => {
    mountDialog()
    await flushPromises()
    setInputValue(
      '[data-testid="kanban-task-detail-description"]',
      'Modified description',
    )
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(false)
  })
})

describe('KanbanTaskDetailDialog — metadata strip', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(
    task: Task,
    column?: KanbanColumn | null,
  ): VueWrapper {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task, column },
    })
    return wrapper
  }

  it('renders the column name when a column prop is provided', async () => {
    mountDialog(TASK, {
      id: 'col_1',
      workspace_item_id: 'item_1',
      name: 'In progress',
      position: 1,
      created_at: '2026-07-16T10:00:00Z',
    })
    await flushPromises()
    const colEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column"]',
    )
    expect(colEl?.textContent).toContain('In progress')
  })

  it('renders the routine type label when task_type is routine', async () => {
    mountDialog({ ...TASK, task_type: 'routine' })
    await flushPromises()
    const typeEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-type"]',
    )
    expect(typeEl).not.toBeNull()
    expect(typeEl?.textContent).toContain('Routine')
  })

  it('renders the pinned indicator when is_pinned is true', async () => {
    mountDialog({ ...TASK, is_pinned: true })
    await flushPromises()
    const pinnedEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-pinned"]',
    )
    expect(pinnedEl).not.toBeNull()
    expect(pinnedEl?.textContent).toContain('Pinned')
  })

  it('hides the metadata strip when no metadata is available', async () => {
    mountDialog({ ...TASK, is_pinned: false })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-metadata"]')).toBeNull()
  })
})

// ─── Create-mode tests (kanban-add-task-via-detail-dialog) ───────────────
//
// The unattended-mode toggle lives inside the edit-mode dialog
// (rendered only when `mode !== 'create'`). It's an iOS-style
// immediate-flip switch — NOT gated on the Save button click —
// because unattended is a runtime behavior setting, not a
// save-button-commit. The dialog emits `update-unattended` with
// `{ value, previous }` so the host can call
// `api.updateSession(task.id, { isAutoRetryUntilStop: value })`
// and roll back on PUT failure if needed.
describe('KanbanTaskDetailDialog — unattended mode toggle', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountEditDialogWithTask(task: Task) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task },
    })
    return wrapper
  }

  it('renders the unattended toggle in edit mode', async () => {
    mountEditDialogWithTask(TASK)
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle).not.toBeNull()
  })

  it('renders the toggle unchecked when task.is_auto_retry_until_stop is missing or "0"', async () => {
    mountEditDialogWithTask({ ...TASK }) // no is_auto_retry_until_stop field
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle?.checked).toBe(false)
  })

  it('renders the toggle checked when task.is_auto_retry_until_stop === "1"', async () => {
    mountEditDialogWithTask({ ...TASK, is_auto_retry_until_stop: '1' })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle?.checked).toBe(true)
  })

  it('renders the toggle in create mode (Option A: atomic create-with-session)', async () => {
    // The toggle used to be hidden in create mode because no
    // session row existed yet. As of the unattended-mode Option A
    // fix, the create payload carries is_auto_retry_until_stop
    // and the backend atomically inserts a sessions row + sets
    // the flag in one transaction. So the toggle is now visible
    // from the create flow — flipping it persists at task
    // creation time.
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: null, column: null },
    })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle).not.toBeNull()
    // Default value is '0' (off) — user can opt in by flipping.
    expect(toggle?.checked).toBe(false)
  })

  it('flipping the toggle emits update-unattended with new value and previous', async () => {
    mountEditDialogWithTask({ ...TASK, is_auto_retry_until_stop: '0' })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    toggle!.checked = true
    toggle!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    const emitted = wrapper!.emitted('update-unattended')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([{ value: '1', previous: '0' }])
  })

  it('flipping the toggle does NOT mark the form dirty (Save stays disabled)', async () => {
    mountEditDialogWithTask({ ...TASK, is_auto_retry_until_stop: '0' })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    toggle!.checked = true
    toggle!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    // The toggle is its own immediate-save action; Save stays
    // disabled until name/description actually change.
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })
})

// The same KanbanTaskDetailDialog renders the "+ Add" flow in
// kanban mode. The host passes `mode="create"` and `task={null}`;
// the form starts empty and submit emits `create` (not `save`).
// These tests verify both the rendering differences and the
// emit shape so the contract is locked in.
describe('KanbanTaskDetailDialog — create mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountCreateDialog(
    column: KanbanColumn | null = null,
    errorMessage: string | null = null,
  ): VueWrapper {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: null, column, errorMessage },
    })
    return wrapper
  }

  it('renders the dialog with task=null (would be hidden in edit mode)', async () => {
    // The whole point of the create-mode change: the dialog must
    // render even when task is null, because in edit mode the
    // v-if="show && task" guard hides it. The new guard is
    // `show && (task || isCreateMode)`.
    mountCreateDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-dialog"]')).not.toBeNull()
  })

  it('starts the form empty even if a task is passed (caller contract: pass null)', async () => {
    // Defensive: in create mode the form MUST start blank regardless
    // of the task prop. The host's contract is `task=null`, but if
    // a future refactor accidentally passes a stale task, the
    // dialog should still present a blank form.
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: TASK },
    })
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    expect(input?.value).toBe('')
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-create-description"]',
    )
    expect(textarea?.value).toBe('')
  })

  it('renders the column name in the metadata strip when column is provided', async () => {
    mountCreateDialog({
      id: 'col_1',
      workspace_item_id: 'item_1',
      name: 'todo',
      position: 0,
      created_at: '2026-07-16T10:00:00Z',
    })
    await flushPromises()
    const colEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column"]',
    )
    expect(colEl?.textContent).toContain('todo')
  })

  it('hides the type + pinned badges in create mode (they only apply to existing tasks)', async () => {
    mountCreateDialog()
    await flushPromises()
    // Even if column is null, the metadata strip is hidden in
    // create mode when no column is provided. The type/pinned
    // badges are explicitly gated off for create mode in the
    // template (`v-if="!isCreateMode && ..."`).
    const strip = findInDom('[data-testid="kanban-task-detail-metadata"]')
    expect(strip).toBeNull()
  })

  it('Save button reads "Create task" and is disabled when name is empty', async () => {
    mountCreateDialog()
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.textContent?.trim()).toBe('Create task')
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('Save button enables when name is non-empty (no "dirty" gate in create mode)', async () => {
    // isDirty returns isValid in create mode (any non-empty name
    // is ready to submit). Without this, the Save button would
    // stay disabled and the user couldn't submit a fresh create.
    mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'My task')
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(false)
  })

  it('emits create (not save) with { mode: "create", name, description, is_auto_retry_until_stop, pendingFiles }', async () => {
    // The create payload now carries is_auto_retry_until_stop
    // (Option A: backend atomically inserts a sessions row when
    // this is '1'). Default value at dialog open is '0' — the
    // toggle hasn't been flipped yet.
    //
    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc): the create
    // emit also carries `pendingFiles: PreviewFile[]` (always an
    // array — empty when no images were staged) so the host's
    // create-then-upload orchestrator can upload attachments AFTER
    // the task exists.
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', '  New task  ')
    setInputValue(
      '[data-testid="kanban-task-detail-create-description"]',
      'Some description',
    )
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    expect(w!.emitted('save')).toBeFalsy()
    const emitted = w!.emitted('create')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      {
        mode: 'create',
        name: 'New task',
        description: 'Some description',
        is_auto_retry_until_stop: '0',
        tags: [],
        // NEW (plan: 2026-08-06-kanban-task-profile-selector)
        selectedProfile: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
      },
    ])
  })

  it('emits create with is_auto_retry_until_stop: "1" when the toggle is flipped on', async () => {
    // Flips the unattended toggle BEFORE clicking Create. The
    // emitted payload should carry the flipped value.
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'Overnight run')
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    toggle!.checked = true
    toggle!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w!.emitted('create')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      {
        mode: 'create',
        name: 'Overnight run',
        description: '',
        is_auto_retry_until_stop: '1',
        tags: [],
        // NEW (plan: 2026-08-06-kanban-task-profile-selector)
        selectedProfile: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
      },
    ])
  })

  it('header title reads "New task" in create mode (vs "Task details" in edit)', async () => {
    mountCreateDialog()
    await flushPromises()
    const title = findInDom<HTMLElement>(
      '#kanban-task-detail-create-title',
    )
    expect(title?.textContent).toContain('New task')
    expect(title?.textContent).not.toContain('Task details')
  })

  it('renders the error banner when errorMessage is set', async () => {
    mountCreateDialog(null, 'Failed to create task — please retry.')
    await flushPromises()
    const banner = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-error"]',
    )
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('Failed to create task')
  })

  it('does not render the error banner when errorMessage is null', async () => {
    mountCreateDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-error"]')).toBeNull()
  })
})

// ─── Column dropdown (create mode) — plan 2026-08-06-kanban-add-task-button-placement ───
//
// Replaces the read-only column label in create mode with an
// interactive dropdown. Mirrors the profile picker pattern
// (button trigger + ▾ dropdown + ✓ checkmark + click-outside close).
// Picking a column emits column-change so the host can update its
// activeCreateColumnId in real-time. Edit mode keeps the static
// strip — migrating an existing task to a new column is out of scope.
describe('KanbanTaskDetailDialog — column dropdown (create mode)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  // Helper: mount the dialog in create mode with the given columns
  // and an optional initial column (defaults to the first).
  function mountCreateWithColumns(
    columns: { id: string; name: string }[],
    initialColumnId: string | null = columns[0]?.id ?? null,
  ): VueWrapper {
    const fullColumns: KanbanColumn[] = columns.map((c) => ({
      id: c.id,
      name: c.name,
      workspace_item_id: 'item_1',
      position: 0,
      created_at: '2026-06-21 12:00:00',
    }))
    const initialColumn = initialColumnId
      ? fullColumns.find((c) => c.id === initialColumnId) ?? null
      : null
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: initialColumn,
        availableColumns: fullColumns,
        workspaceId: 'ws_1',
      },
    })
    return wrapper
  }

  it('create mode: column is rendered as a dropdown button (not a static text strip)', async () => {
    mountCreateWithColumns([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    // Dropdown trigger renders with the expected testid.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker"]'),
    ).not.toBeNull()
    // The static strip (legacy testid) does NOT render in create mode.
    expect(findInDom('[data-testid="kanban-task-detail-column"]')).toBeNull()
  })

  it('create mode: column dropdown defaults to the column prop', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    const trigger = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker"]',
    )
    expect(trigger?.textContent).toContain('todo')
  })

  it('create mode: opening the dropdown and picking a column emits column-change', async () => {
    const w = mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()

    // Open the dropdown.
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    // Pick the second column.
    clickInDom('[data-testid="kanban-task-detail-column-picker-item-col_y"]')
    await flushPromises()

    expect(w.emitted('column-change')).toBeTruthy()
    expect(w.emitted('column-change')?.[0]).toEqual(['col_y'])
  })

  it('create mode: single-column kanban — dropdown renders with the single item + checkmark', async () => {
    mountCreateWithColumns([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    const item = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-item-col_x"]',
    )
    expect(item).not.toBeNull()
    expect(item?.textContent).toContain('✓')
  })

  it('edit mode: column is rendered as a static text strip (no dropdown)', async () => {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'edit',
        task: {
          id: 'task_1',
          name: 'existing task',
          description: '',
          kanban_column_id: 'col_x',
        },
        column: {
          id: 'col_x',
          name: 'todo',
          workspace_item_id: 'item_1',
          position: 0,
          created_at: '2026-06-21 12:00:00',
        },
        availableColumns: [],  // edit mode ignores availableColumns
      },
    })
    await flushPromises()
    // Static strip renders (legacy testid).
    expect(findInDom('[data-testid="kanban-task-detail-column"]')).not.toBeNull()
    // Dropdown does NOT render.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker"]'),
    ).toBeNull()
  })

  it('create mode: clicking outside the dropdown closes it', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    // Dropdown is open.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker-dropdown"]'),
    ).not.toBeNull()
    // Dispatch a click on document.body (outside the picker).
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushPromises()
    // Dropdown is closed.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker-dropdown"]'),
    ).toBeNull()
  })

  // NEW (2026-08-06, dropdown width/style follow-up). The dropdown
  // sizes to its CONTENT (max-content) — as wide as the longest
  // item ("in_review_planning" + checkmark + padding), but no wider.
  // It is NOT the trigger width (long names would clip) and NOT the
  // full body width (looks disproportionate when items are short
  // like "drop" or "merged"). The wrapper is `relative` (sizes to
  // trigger button content); the dropdown is `absolute left-0 w-max`
  // anchored to the wrapper's left edge with width:max-content.
  // Items get no `border-top` separator (matches the profile picker
  // dropdown styling).
  it('create mode: dropdown sizes to its content (max-content width, anchored to trigger left edge)', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in_review_planning' },
    ])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()

    const trigger = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker"]',
    )
    const dropdown = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-dropdown"]',
    )
    expect(trigger).not.toBeNull()
    expect(dropdown).not.toBeNull()

    // Dropdown is positioned with `left-0` (anchored to wrapper's
    // left edge) + `w-max` (width: max-content — sized to the
    // widest item). NOT full body width (no `w-full`), NOT just
    // the trigger width (no `inset-x-0` with non-w-full wrapper).
    const dropdownClass = dropdown!.getAttribute('class') ?? ''
    expect(dropdownClass).toContain('left-0')
    expect(dropdownClass).toContain('w-max')
    expect(dropdownClass).not.toContain('inset-x-0')
    expect(dropdownClass).not.toMatch(/\bw-full\b/)
    // No fixed min-w override.
    expect(dropdownClass).not.toMatch(/\bmin-w-\[/)

    // Items have no border-top separator (matches profile picker style).
    const item = dropdown!.querySelector<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-item-col_y"]',
    )
    expect(item).not.toBeNull()
    const itemStyle = item!.getAttribute('style') ?? ''
    expect(itemStyle).not.toMatch(/border-top/i)
  })
})

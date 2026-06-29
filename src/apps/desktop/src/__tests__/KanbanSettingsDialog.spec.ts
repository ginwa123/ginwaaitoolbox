/**
 * Tests for KanbanSettingsDialog — the per-board settings modal
 * showing the kanban name, an "Add Column" inline form, and a
 * list of columns with per-row Edit / Delete actions.
 *
 * Mount pattern: same as KanbanColumnEditor.spec.ts / AddKanbanDialog.spec.ts.
 * The dialog uses <Teleport to="body">, so the rendered DOM lives
 * outside wrapper.element. We use `attachTo: document.body` and
 * query the teleported content via `document.querySelector` /
 * `document.querySelectorAll` (NOT `wrapper.find`). `wrapper.emitted`
 * still works because it tracks the vm, not the DOM tree.
 *
 * Plan: docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md
 *   Chunk 3 / Task 3.1
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanSettingsDialog from '@/components/KanbanSettingsDialog.vue'
import type { WorkspaceItem } from '@/stores/workspaces'

const baseItem: WorkspaceItem = {
  id: 'wi_test',
  name: 'Sprint 12',
  item_type: 'kanban',
  path: null,
  kanban_columns: [
    {
      id: 'col_a',
      workspace_item_id: 'wi_test',
      name: 'todo',
      description: 'Not started',
      position: 0,
      created_at: '2026-06-26T10:00:00Z',
    },
    {
      id: 'col_b',
      workspace_item_id: 'wi_test',
      name: 'done',
      description: '',
      position: 1,
      created_at: '2026-06-26T10:00:00Z',
    },
  ],
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

describe('KanbanSettingsDialog', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Force-remove any leftover teleported DOM from previous test
    // (mirrors the cleanup in EditRoutineDialog.spec.ts).
    findAllInDom('[data-testid="kanban-settings-dialog"]').forEach((el) =>
      el.remove(),
    )
    findAllInDom('[data-testid^="kanban-column-editor-"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(item: WorkspaceItem | null = baseItem) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanSettingsDialog, {
      attachTo: document.body,
      props: { show: true, item },
    })
    return wrapper
  }

  it('renders the kanban name in the header', async () => {
    mountDialog()
    await flushPromises()
    const dialog = findInDom<HTMLElement>('[data-testid="kanban-settings-dialog"]')
    expect(dialog).not.toBeNull()
    expect(dialog?.textContent).toContain('Sprint 12')
  })

  it('renders one row per column sorted by position', async () => {
    mountDialog()
    await flushPromises()
    const rows = findAllInDom<HTMLElement>(
      '[data-testid^="kanban-settings-column-row-"]',
    )
    expect(rows).toHaveLength(2)
    // Position 0 first, then position 1 — i.e. col_a (todo) before col_b (done).
    expect(rows[0]!.getAttribute('data-testid')).toBe('kanban-settings-column-row-col_a')
    expect(rows[1]!.getAttribute('data-testid')).toBe('kanban-settings-column-row-col_b')
    const firstName = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-column-name-col_a"]',
    )
    const secondName = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-column-name-col_b"]',
    )
    expect(firstName?.textContent).toContain('todo')
    expect(secondName?.textContent).toContain('done')
  })

  it('shows "No description" for columns with empty description', async () => {
    mountDialog()
    await flushPromises()
    const descEl = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-column-description-col_b"]',
    )
    expect(descEl).not.toBeNull()
    expect(descEl?.textContent?.trim()).toBe('No description')

    // The non-empty column should show the actual description text.
    const descA = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-column-description-col_a"]',
    )
    expect(descA?.textContent).toContain('Not started')
  })

  it('emits addColumn with name + description when Add is clicked', async () => {
    const w = mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-settings-add-name"]', 'Review')
    setInputValue(
      '[data-testid="kanban-settings-add-description"]',
      'Awaiting code review',
    )
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-add-submit"]')

    const emitted = w!.emitted('addColumn')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Review', 'Awaiting code review'])
  })

  it('emits close when the close button is clicked', async () => {
    const w = mountDialog()
    await flushPromises()
    clickInDom('[data-testid="kanban-settings-close"]')

    expect(w!.emitted('close')).toBeTruthy()
  })

  it('emits deleteColumn when Delete is clicked on a row (after confirming in KanbanColumnEditor)', async () => {
    const w = mountDialog()
    await flushPromises()
    // 1. Click the per-row Delete button on col_a.
    clickInDom('[data-testid="kanban-settings-delete-col_a"]')
    await flushPromises()

    // 2. The inner KanbanColumnEditor should now be visible in delete mode.
    const deleteDialog = findInDom<HTMLElement>(
      '[data-testid="kanban-column-editor-delete"]',
    )
    expect(deleteDialog).not.toBeNull()

    // 3. Click the editor's Delete button to confirm.
    clickInDom('[data-testid="kanban-column-editor-delete-submit"]')

    const emitted = w!.emitted('deleteColumn')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['col_a'])
  })

  it('emits editColumn when Edit is clicked and Save is confirmed', async () => {
    const w = mountDialog()
    await flushPromises()
    // 1. Click the per-row Edit button on col_a.
    clickInDom('[data-testid="kanban-settings-edit-col_a"]')
    await flushPromises()

    // 2. The inner KanbanColumnEditor should now be visible in rename mode.
    const renameDialog = findInDom<HTMLElement>(
      '[data-testid="kanban-column-editor-rename"]',
    )
    expect(renameDialog).not.toBeNull()

    // 3. Update the name and description, then click Save.
    setInputValue('[data-testid="kanban-column-editor-rename-name"]', 'backlog')
    setInputValue(
      '[data-testid="kanban-column-editor-rename-description"]',
      'Newly triaged',
    )
    await flushPromises()
    clickInDom('[data-testid="kanban-column-editor-rename-submit"]')

    const emitted = w!.emitted('editColumn')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      { columnId: 'col_a', name: 'backlog', description: 'Newly triaged' },
    ])
  })

  it('preserves the saved description in the column list after the parent updates the prop (regression for "No description shown after save")', async () => {
    // User-visible bug: after saving a column edit from the
    // settings dialog, the description row collapses to "No
    // description" until the page is refreshed. Root cause was the
    // store assigning the PATCH response (full board envelope) to
    // a single column slot, so col.description read as undefined
    // and the v-if fell through to the placeholder branch.
    //
    // This test simulates the parent re-feeding the dialog with
    // the post-PATCH workspace item (the same shape the store
    // produces after `updateKanbanColumn` runs) and asserts that
    // the dialog renders the new description, NOT the
    // "No description" placeholder.
    const w = mountDialog()
    await flushPromises()

    // Sanity: col_b starts with an empty description, so it shows
    // the placeholder. We're going to give it a real description
    // via the parent prop update and verify it renders the new
    // text.
    const beforeDescB = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-column-description-col_b"]',
    )
    expect(beforeDescB?.textContent?.trim()).toBe('No description')

    // Parent (AppLayout → workspacesStore.updateKanbanColumn)
    // receives the PATCH response and produces an updated item
    // with the new description. We mirror the post-fix store
    // behavior here: the entire kanban_columns array is replaced
    // with the backend's response, not a single-column slot
    // assignment.
    const updatedItem: WorkspaceItem = {
      ...baseItem,
      kanban_columns: [
        baseItem.kanban_columns![0]!,
        {
          ...baseItem.kanban_columns![1]!,
          description: 'Finished work awaiting review',
        },
      ],
    }
    await w.setProps({ item: updatedItem })
    await flushPromises()

    // The bug would fail here: col_b.description read as undefined
    // (because the slot held the {columns, count} envelope
    // instead of a KanbanColumn) and the dialog showed "No
    // description" forever — until a full page reload. After the
    // fix, the new description renders as a normal subtitle.
    const afterDescB = findInDom<HTMLElement>(
      '[data-testid="kanban-settings-column-description-col_b"]',
    )
    expect(afterDescB).not.toBeNull()
    expect(afterDescB?.textContent?.trim()).toBe(
      'Finished work awaiting review',
    )
    expect(afterDescB?.getAttribute('title')).toBe(
      'Finished work awaiting review',
    )
  })

  // ─── Inline rename pencil (2026-06-30 — header rename) ─────────────────
  //
  // The header inline-rename pencil (InlineEditableText primitive)
  // wraps the kanban name in the settings dialog title. Clicking
  // it swaps to edit mode; pressing Save emits `rename-item` with
  // the trimmed new value, which the host (AppLayout) delegates to
  // workspacesStore.updateKanbanItemName.

  it('emits renameItem with the new name when the header pencil saves', async () => {
    const w = mountDialog()
    await flushPromises()
    // 1. Click the display span to enter edit mode.
    clickInDom('[data-testid="kanban-settings-rename-display"]')
    await flushPromises()
    // 2. Edit the input value.
    setInputValue('[data-testid="kanban-settings-rename-input"]', 'Sprint 13')
    await flushPromises()
    // 3. Click Save.
    clickInDom('[data-testid="kanban-settings-rename-save"]')
    await flushPromises()

    const emitted = w!.emitted('renameItem')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Sprint 13'])
  })
})
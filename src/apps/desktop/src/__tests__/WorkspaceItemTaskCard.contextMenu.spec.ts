/**
 * <WorkspaceItemTaskCard> — right-click context menu.
 *
 * The card's hover action strip (pin / rename / details / delete) was
 * replaced by this menu. Every action the buttons performed must still
 * fire, with the SAME emitted payload, or the change silently removed
 * functionality.
 *
 * Plan: docs/superpowers/plans/2026-09-25-kanban-card-context-menu-move-to-column.md
 */
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import WorkspaceItemTaskCard from '../components/workspace/WorkspaceItemTaskCard.vue'
import type { KanbanColumn, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ITEM_ID = 'item_1'

// Typed factory rather than a bare literal: KanbanColumn carries
// workspace_item_id + created_at, and a plain object literal silently
// drifts from the interface the component actually receives. Same
// shape as makeColumn() in KanbanView.rowMode.spec.ts / KanbanRowView.spec.ts.
const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_todo',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const COLUMNS: KanbanColumn[] = [
  makeColumn(),
  makeColumn({ id: 'col_doing', name: 'in progress', position: 1 }),
  makeColumn({ id: 'col_done', name: 'merged', position: 2 }),
]

function mountCard(
  task: Task,
  opts: {
    processingState?: Ref<Record<string, boolean>>
    columns?: KanbanColumn[]
    currentColumnId?: string | null
  } = {},
) {
  const processingState: Ref<Record<string, boolean>> =
    opts.processingState ?? ref<Record<string, boolean>>({})
  const wrapper = mount(WorkspaceItemTaskCard, {
    attachTo: document.body,
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: ITEM_ID,
      columns: opts.columns ?? COLUMNS,
      currentColumnId: opts.currentColumnId ?? 'col_doing',
    },
    global: { provide: { processingState } },
  })
  return wrapper
}

const q = (testid: string) =>
  document.body.querySelector(`[data-testid="${testid}"]`) as HTMLElement | null

const clickItem = async (testid: string) => {
  const el = q(testid)
  if (!el) throw new Error(`menu item ${testid} not found`)
  expect(el).toBeTruthy()
  el!.click()
  await nextTick()
}

async function openMenu(wrapper: VueWrapper) {
  await wrapper.find('[data-task-card]').trigger('contextmenu', {
    clientX: 120,
    clientY: 200,
  })
  await nextTick()
}

describe('WorkspaceItemTaskCard — context menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('opens on right-click at the cursor, with the task name as a title', async () => {
    const wrapper = mountCard({ id: 't1', name: 'gitlab support' })
    await openMenu(wrapper)

    const menu = q('kanban-task-context-menu')
    expect(menu).toBeTruthy()
    expect(q('kanban-task-context-menu-title')?.textContent?.trim()).toBe('gitlab support')

    wrapper.unmount()
  })

  it('pin emits pinTask with the INVERTED value', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha', is_pinned: false })
    await openMenu(wrapper)
    expect(q('kanban-task-context-menu-pin')?.textContent).toContain('Pin task')

    await clickItem('kanban-task-context-menu-pin')
    expect(wrapper.emitted('pinTask')?.[0]).toEqual(['ws_1', 'item_1', 't1', true])

    wrapper.unmount()
  })

  it('pin on an already-pinned card emits false and relabels to Unpin', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha', is_pinned: true })
    await openMenu(wrapper)
    expect(q('kanban-task-context-menu-pin')?.textContent).toContain('Unpin task')

    await clickItem('kanban-task-context-menu-pin')
    expect(wrapper.emitted('pinTask')?.[0]).toEqual(['ws_1', 'item_1', 't1', false])

    wrapper.unmount()
  })

  it('rename emits renameTask with the CURRENT name', async () => {
    const wrapper = mountCard({ id: 't1', name: 'gitlab support' })
    await openMenu(wrapper)
    await clickItem('kanban-task-context-menu-rename')
    expect(wrapper.emitted('renameTask')?.[0]).toEqual(['ws_1', 'item_1', 't1', 'gitlab support'])

    wrapper.unmount()
  })

  it('view details emits viewTaskDetail and does NOT also open the chat', async () => {
    // The propagation trap: the old info button had to stopPropagation so
    // the card root's @click didn't fire too. The teleported menu can't
    // bubble to the card, so this asserts the behaviour survived the
    // rewrite rather than relying on the stopPropagation.
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenu(wrapper)
    await clickItem('kanban-task-context-menu-details')

    expect(wrapper.emitted('viewTaskDetail')?.[0]).toEqual(['t1'])
    expect(wrapper.emitted('selectTask')).toBeUndefined()

    wrapper.unmount()
  })

  it('delete opens a confirmation and only emits deleteTask on confirm', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenu(wrapper)
    await clickItem('kanban-task-context-menu-delete')

    // Picking Delete must NOT delete on its own.
    expect(wrapper.emitted('deleteTask')).toBeUndefined()
    const confirmBtn = Array.from(document.body.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'Delete',
    ) as HTMLButtonElement | undefined
    if (!confirmBtn) throw new Error('ConfirmDialog not shown')
    expect(confirmBtn).toBeTruthy()
    confirmBtn!.click()
    await nextTick()

    expect(wrapper.emitted('deleteTask')?.[0]).toEqual(['ws_1', 'item_1', 't1'])

    wrapper.unmount()
  })

  it('Stop agent shows only while a worker runs on the task', async () => {
    const idle = mountCard({ id: 't1', name: 'Alpha' })
    await openMenu(idle)
    expect(q('kanban-task-context-menu-stop')).toBeNull()
    idle.unmount()
    document.body.innerHTML = ''

    const running = mountCard({ id: 't2', name: 'Beta' }, { processingState: ref({ t2: true }) })
    await openMenu(running)
    expect(q('kanban-task-context-menu-stop')).toBeTruthy()

    running.unmount()
  })

  it('closes on Escape', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenu(wrapper)
    expect(q('kanban-task-context-menu')).toBeTruthy()

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    expect(q('kanban-task-context-menu')).toBeNull()

    wrapper.unmount()
  })

  it('opens from the ContextMenu key, anchored at the card', async () => {
    // Removing the hover buttons removed the only discoverable route to
    // rename/delete/move, so the keyboard path is a hard requirement —
    // without it the change is an accessibility regression.
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await wrapper.find('[data-task-card]').trigger('keydown', { key: 'ContextMenu' })
    await nextTick()

    expect(q('kanban-task-context-menu')).toBeTruthy()
    // Enter/Space must still open the chat, not the menu.
    expect(wrapper.emitted('selectTask')).toBeUndefined()

    wrapper.unmount()
  })

  it('arrow keys walk the rows and ArrowRight opens the submenu', async () => {
    // Removing the hover buttons removed the only discoverable route to
    // the menu, so the keyboard path has to work end to end.
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenu(wrapper)

    const root = q('kanban-task-context-menu')!
    // Nothing is focused yet; the first ArrowDown lands on row 0.
    root.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    await nextTick()
    expect(document.activeElement).toBe(q('kanban-task-context-menu-pin'))

    document.activeElement!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
    )
    await nextTick()
    expect(document.activeElement).toBe(q('kanban-task-context-menu-rename'))

    // Walk to "Move to column" and open the submenu with ArrowRight.
    for (let i = 0; i < 2; i++) {
      document.activeElement!.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }),
      )
      await nextTick()
    }
    expect(document.activeElement).toBe(q('kanban-task-context-menu-move'))

    document.activeElement!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await nextTick()
    expect(q('kanban-task-context-menu-sub')).toBeTruthy()

    // ArrowLeft closes the submenu and returns focus to its parent row.
    document.activeElement!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true }),
    )
    await nextTick()
    expect(q('kanban-task-context-menu-sub')).toBeNull()
    expect(document.activeElement).toBe(q('kanban-task-context-menu-move'))

    wrapper.unmount()
  })

  it('still opens the chat on Enter', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await wrapper.find('[data-task-card]').trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['t1'])

    wrapper.unmount()
  })
})

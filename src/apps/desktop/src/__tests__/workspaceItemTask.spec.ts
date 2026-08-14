/**
 * Component tests for the per-task row in the workspace-item panel.
 *
 * History:
 *   - 2026-06-10: <WorkspaceItemTask> was extracted from
 *     WorkspaceItem.vue to narrow re-render scope and isolate the
 *     per-task DOM (spinner, bullet, hover buttons, click handlers)
 *     from the parent item row.
 *   - 2026-07-02: <WorkspaceItemTask> split into two thin
 *     presentation components — <WorkspaceItemTaskRow> (sidebar list)
 *     and <WorkspaceItemTaskCard> (kanban). The shared logic moved
 *     to composables/useTaskActions.ts. These tests target the Row
 *     component (sidebar consumers' view of the per-task row).
 *
 * These tests mount <WorkspaceItemTaskRow> directly so they do NOT
 * depend on WorkspaceItem's expansion state, the item-row spinner, or
 * the parent-child event wiring. The integration of
 * <WorkspaceItemTaskRow> into <WorkspaceItem> is covered by the
 * existing workspaceItemTaskRename.spec.ts and
 * workspaceItemTaskSpinner.spec.ts files (which mount <WorkspaceItem>
 * and assert through the parent).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItemTaskRow from '../components/workspace/WorkspaceItemTaskRow.vue'
import { makeLocalStorageStub } from './helpers'

// Stub vue-router — WorkspaceItemTaskRow reads useRoute() via
// useCurrentMainView() to drive its active state. We mock useRoute
// to return a per-test controlled query so the row's active styling
// can be exercised against any URL. Mirrors the pattern at
// sidebarHandleSelectTaskUrl.spec.ts:57-77.
const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/app', fullPath: '/app' })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseTask = { id: 'task_alpha', name: 'Alpha task' }

function mountTask(
  overrides: {
    task?: typeof baseTask
    workspaceId?: string
    itemId?: string
    processing?: boolean
    active?: boolean
  } = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const task = overrides.task ?? baseTask
  const wrapper = mount(WorkspaceItemTaskRow, {
    props: {
      task,
      workspaceId: overrides.workspaceId ?? 'ws_1',
      itemId: overrides.itemId ?? 'item_1',
    },
    global: {
      provide: { processingState },
    },
  })
  if (overrides.processing) {
    processingState.value = { [task.id]: true }
  }
  return { wrapper, processingState }
}

describe('WorkspaceItemTaskRow per-task row', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    // Pinia is torn down by the next beforeEach.
  })

  it('renders the task name and a bullet by default (no spinner, no active styling)', async () => {
    const { wrapper } = mountTask()
    expect(wrapper.text()).toContain('Alpha task')
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
    // Lock in the row-variant contract (post-2026-07-02 split):
    // the Row component always carries data-task-row and never
    // data-task-card. A future refactor that re-introduces a
    // 'variant' prop or accidentally adds a data-task-card attribute
    // would break the consumer's selection logic in KanbanColumn /
    // drag-and-drop handlers.
    expect(wrapper.find('[data-task-row]').exists()).toBe(true)
    expect(wrapper.find('[data-task-card]').exists()).toBe(false)
    // Bullet is a span.w-1.5.h-1.5.rounded-full — at least one exists.
    expect(wrapper.findAll('span.w-1\\.5.h-1\\.5.rounded-full')).toHaveLength(1)
  })

  it('renders the spinner and hides the bullet when processingState[task.id] is true', async () => {
    const { wrapper } = mountTask({ processing: true })
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(1)
    // Bullet must NOT render while the spinner is shown (single
    // visual marker per row). The bullet selector is w-1.5.h-1.5; the
    // spinner uses w-4.h-4, so the w-1.5 selector catches only the
    // bullet.
    expect(wrapper.findAll('span.w-1\\.5.h-1\\.5.rounded-full')).toHaveLength(0)
  })

  it('hides the spinner and restores the bullet when processingState[task.id] flips back to false', async () => {
    const { wrapper, processingState } = mountTask({ processing: true })
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(1)
    processingState.value = {}
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
    expect(wrapper.findAll('span.w-1\\.5.h-1\\.5.rounded-full')).toHaveLength(1)
  })

  it('renders the bullet in the dim text color when not active and not processing', async () => {
    const { wrapper } = mountTask()
    const bullet = wrapper.find('span.w-1\\.5.h-1\\.5.rounded-full')
    expect(bullet.exists()).toBe(true)
    // activeTaskId is null in a fresh Pinia → bullet gets the dim
    // (semantic-text-dim) background.
    expect(bullet.attributes('style')).toContain('--semantic-text-dim')
  })

  it('applies active styling (aqua bullet + active background) when URL is ?view=workspace&itemId=Y/chat/task_X', async () => {
    // SIMPLIFY-URL-BROWSER (2026-08-15): the URL is now
    // ?view=workspace&itemId=Y/chat/task_X. useCurrentMainView
    // parses the /chat/ suffix and exposes chatTaskId on the
    // workspace view variant. The task row's active highlight
    // reads kind='workspace' + chatTaskId.
    const ITEM_ID = 'item_test'
    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: 'ws_test',
        itemId: `${ITEM_ID}/chat/${baseTask.id}`,
      },
      path: '/app',
      fullPath: `/app?view=workspace&workspaceId=ws_test&itemId=${ITEM_ID}/chat/${baseTask.id}`,
    } as any)
    const { wrapper } = mountTask()
    const rowButton = wrapper.find('button.group\\/task')
    expect(rowButton.exists()).toBe(true)
    expect(rowButton.attributes('style')).toContain('--semantic-active-bg')
    expect(rowButton.attributes('style')).toContain('--color-aqua')
    const bullet = wrapper.find('span.w-1\\.5.h-1\\.5.rounded-full')
    expect(bullet.attributes('style')).toContain('--color-aqua')
  })

  it('emits selectTask with task.id when the row is clicked', async () => {
    const { wrapper } = mountTask()
    const rowButton = wrapper.find('button.group\\/task')
    await rowButton.trigger('click')
    const emitted = wrapper.emitted('selectTask')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['task_alpha'])
  })

  it('emits renameTask with (workspaceId, itemId, taskId, currentName) when the pencil is clicked', async () => {
    const { wrapper } = mountTask({
      workspaceId: 'ws_xyz',
      itemId: 'item_xyz',
    })
    const renameBtn = wrapper.find('button[title="Rename Task"]')
    expect(renameBtn.exists()).toBe(true)
    await renameBtn.trigger('click')
    const emitted = wrapper.emitted('renameTask')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_xyz', 'item_xyz', 'task_alpha', 'Alpha task'])
  })

  it('emits deleteTask with (workspaceId, itemId, taskId) when the trash icon is clicked', async () => {
    const { wrapper } = mountTask({
      workspaceId: 'ws_xyz',
      itemId: 'item_xyz',
    })
    // The delete button has no title; select via the hover color class.
    const deleteBtn = wrapper.find('button.hover\\:text-red-400')
    expect(deleteBtn.exists()).toBe(true)
    await deleteBtn.trigger('click')
    const emitted = wrapper.emitted('deleteTask')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_xyz', 'item_xyz', 'task_alpha'])
  })

  it('does NOT emit selectTask when the rename button is clicked (stopPropagation guard)', async () => {
    const { wrapper } = mountTask()
    const renameBtn = wrapper.find('button[title="Rename Task"]')
    await renameBtn.trigger('click')
    // The pencil lives inside the row <button @click="...">. Without
    // event.stopPropagation in handleRenameTask, the click would
    // bubble and selectTask would fire as a side-effect — confusing UX.
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  it('does NOT emit selectTask when the delete button is clicked (stopPropagation guard)', async () => {
    const { wrapper } = mountTask()
    const deleteBtn = wrapper.find('button.hover\\:text-red-400')
    await deleteBtn.trigger('click')
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  it('hides the rename and delete buttons by default (opacity-0 class present initially)', async () => {
    const { wrapper } = mountTask()
    // Hover-reveal pattern: both buttons carry opacity-0 until the
    // parent .group/task is hovered. Assert the unhovered class is
    // present so a future refactor that removes the hidden state
    // fails this test.
    const renameBtn = wrapper.find('button[title="Rename Task"]')
    const deleteBtn = wrapper.find('button.hover\\:text-red-400')
    expect(renameBtn.classes()).toContain('opacity-0')
    expect(deleteBtn.classes()).toContain('opacity-0')
  })

  it('renders the row, the pin/rename/delete action buttons (4 buttons total)', async () => {
    // Regression guard: the pin + rename + delete buttons are nested
    // INSIDE the row's <button>. A future "fix" that moves them
    // outside (e.g. <div> row + absolute-positioned buttons) would
    // change the count. Preserve the original DOM structure.
    //
    // Updated for the pinned-tasks feature (plan:
    // docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md).
    // The pin/unpin toggle button slots in between the row and the
    // rename button.
    const { wrapper } = mountTask()
    const allButtons = wrapper.findAll('button')
    expect(allButtons.length).toBe(4)
  })

  it('emits the four renameTask args in the documented order', async () => {
    // Belt-and-braces check for the event payload shape, in case a
    // future refactor re-orders the arguments. We index into the
    // emitted tuple by position — the cast satisfies Vue's
    // `unknown[]` element type, and the `!` is required because
    // tsconfig has noUncheckedIndexedAccess turned on (Vue's
    // `emitted()` returns `unknown[][] | undefined`).
    const { wrapper } = mountTask({
      workspaceId: 'ws_order',
      itemId: 'item_order',
    })
    const renameBtn = wrapper.find('button[title="Rename Task"]')
    await renameBtn.trigger('click')
    const args = wrapper.emitted('renameTask')![0]! as [string, string, string, string]
    expect(args[0]).toBe('ws_order')          // workspaceId
    expect(args[1]).toBe('item_order')        // itemId
    expect(args[2]).toBe('task_alpha')        // taskId
    expect(args[3]).toBe('Alpha task')        // currentName
  })
})

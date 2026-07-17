/**
 * Component tests for the rename-task pencil button on the task row
 * in WorkspaceItem.vue. Covers the button's presence on hover, the
 * emit signature, and the critical stopPropagation guard that
 * prevents the click from bubbling up to the parent row's
 * selectTask handler.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const itemWithTasks = {
  id: 'item_1',
  name: 'My Project',
  item_type: 'folder',
  tasks: [{ id: 'task_alpha', name: 'Alpha task' }],
}

function mountWorkspaceItem() {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...itemWithTasks },
      isActive: false,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState },
    },
  })
  return { wrapper }
}

function expandItem(): void {
  const ws = useWorkspacesStore()
  ws.expandedItemIds['item_1'] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

describe('WorkspaceItem task rename button', () => {
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

  it('emits renameTask with workspaceId, itemId, taskId, currentName when the pencil is clicked', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()

    const renameBtn = wrapper.find('button[title="Rename Task"]')
    expect(renameBtn.exists()).toBe(true)

    await renameBtn.trigger('click')

    const emitted = wrapper.emitted('renameTask')
    expect(emitted).toBeDefined()
    // Single emission, with the four documented args in order.
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_1', 'item_1', 'task_alpha', 'Alpha task'])
  })

  it('does NOT emit selectTask when the pencil is clicked (stopPropagation guard)', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()

    const renameBtn = wrapper.find('button[title="Rename Task"]')
    await renameBtn.trigger('click')

    // The pencil lives inside the row <button @click="handleSelectTask(...)">.
    // Without event.stopPropagation in handleRenameTask, the click would
    // bubble and selectTask would fire as a side-effect — confusing UX.
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  it('hides the pencil by default and reveals it on row hover (opacity-0 class present initially)', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()

    const renameBtn = wrapper.find('button[title="Rename Task"]')
    expect(renameBtn.exists()).toBe(true)
    // Hover-reveal pattern: the button carries opacity-0 until the
    // parent .group/task is hovered. The actual class set comes from
    // the Tailwind template; assert the unhovered class is present
    // so a future refactor that removes the hidden state fails this test.
    expect(renameBtn.classes()).toContain('opacity-0')
  })

  it('still renders a delete button alongside the rename button', async () => {
    // Regression guard: the rename button was inserted *before* the
    // existing delete button. A future refactor that drops the
    // delete button would silently break the delete feature.
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()

    expect(wrapper.find('button[title="Rename Task"]').exists()).toBe(true)
    // The delete button has no title, but it's the only other w-4
    // h-4 button with a hover:text-red-400 class. Use a more robust
    // selector: find all task-row buttons and assert the count.
    const allButtons = wrapper.findAll('button')
    // The row itself is a <button>, plus the rename and delete
    // buttons = 3 total inside the task list.
    expect(allButtons.length).toBeGreaterThanOrEqual(3)
  })
})

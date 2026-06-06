/**
 * Regression tests for the "task row shows no spinner while worker is
 * processing" gap. WorkspaceItem must read from the same processingState
 * ref App.vue provides and show a yellow spinner on the matching row.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const itemWithTasks = {
  id: 'item_1',
  name: 'My Project',
  item_type: 'folder',
  tasks: [
    { id: 'task_alpha', name: 'Alpha task' },
    { id: 'task_beta', name: 'Beta task' },
  ],
}

function mountWorkspaceItem(
  tasks: Array<{ id: string; name: string }> = itemWithTasks.tasks,
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...itemWithTasks, tasks },
      isActive: false,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState },
    },
  })
  return { wrapper, processingState }
}

function expandItem(): void {
  // Tasks are only rendered when the parent item is expanded
  // (WorkspaceItem.vue:125). The store mutates `expandedItemIds` and
  // reassigns the ref to trigger reactivity, matching the production
  // toggle in stores/workspaces.ts:toggleExpandedItem.
  const ws = useWorkspacesStore()
  ws.expandedItemIds['item_1'] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

describe('WorkspaceItem task spinner', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    // Pinia is torn down by the next beforeEach's setActivePinia.
  })

  it('shows no spinner when no task is in processingState', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
  })

  it('shows a spinner on the matching task when processingState[task.id] is true', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    const spinners = wrapper.findAll('[data-testid="task-spinner"]')
    expect(spinners).toHaveLength(1)
    // The alpha row is the one with the spinner; the alpha name is still
    // rendered in the row (spinner sits before the name, not in place of it).
    expect(wrapper.text()).toContain('Alpha task')
  })

  it('shows spinners on multiple tasks when several are processing', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(2)
  })

  it('hides the spinner when the task is removed from processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(1)
    // Worker SSE emits a 'deleted' event → App.vue clears
    // processingState[task_alpha]. The spinner should disappear.
    processingState.value = {}
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
  })

  it('shows no spinner for tasks that are not in processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_beta: true }
    await nextTick()
    // Alpha is not in processingState → no spinner for it, even though
    // it sits in the list and would normally be visible.
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(1)
    expect(wrapper.text()).toContain('Alpha task')
    expect(wrapper.text()).toContain('Beta task')
  })
})

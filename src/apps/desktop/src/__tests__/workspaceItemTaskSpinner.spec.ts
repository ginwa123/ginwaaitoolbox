/**
 * Regression tests for the "task row shows no slider while worker is
 * processing" gap. WorkspaceItem must read from the same processingState
 * ref App.vue provides and show a visible SessionSlider on the matching
 * row.
 *
 * Updated 2026-08-29: the per-task yellow spinner circle was replaced
 * by a SessionSlider that only renders while the task is processing
 * (`aria-busy="true"` when present, no DOM element when idle). These
 * tests assert on the VISIBLE state — the hidden state renders
 * nothing, so tests count the visible ones.
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
  tasks: [
    { id: 'task_alpha', name: 'Alpha task' },
    { id: 'task_beta', name: 'Beta task' },
  ],
}

function mountWorkspaceItem(tasks: Array<{ id: string; name: string }> = itemWithTasks.tasks) {
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

// Filter helper: only count VISIBLE sliders (those with
// `aria-busy="true"`). The SessionSlider component renders the DOM
// element always but toggles aria-busy + opacity to show/hide.
const visibleSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="task-spinner"][aria-busy="true"]')

describe('WorkspaceItem task slider', () => {
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

  it('shows no slider when no task is in processingState', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(0)
  })

  it('shows a slider on the matching task when processingState[task.id] is true', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(1)
    // The alpha row is the one with the slider; the alpha name is
    // still rendered in the row (slider sits at the bottom of the
    // row, not in place of the name).
    expect(wrapper.text()).toContain('Alpha task')
  })

  it('shows sliders on multiple tasks when several are processing', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(2)
  })

  it('hides the slider when the task is removed from processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(1)
    // Worker SSE emits a 'deleted' event → App.vue clears
    // processingState[task_alpha]. The slider should become
    // invisible (aria-busy flips back to false).
    processingState.value = {}
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(0)
  })

  it('shows no slider for tasks that are not in processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    expandItem()
    processingState.value = { task_beta: true }
    await nextTick()
    // Alpha is not in processingState → no visible slider for it,
    // even though it sits in the list and would normally be visible.
    expect(visibleSpinners(wrapper)).toHaveLength(1)
    expect(wrapper.text()).toContain('Alpha task')
    expect(wrapper.text()).toContain('Beta task')
  })
})

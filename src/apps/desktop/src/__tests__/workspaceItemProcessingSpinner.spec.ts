/**
 * Regression tests for the "workspace item row shows no slider while one
 * of its tasks is processing" gap. The per-TASK row already has a slider
 * (see workspaceItemTaskSpinner.spec.ts), and the per-ITEM row (the
 * project row) must have one too — so a user who collapsed the task list
 * can still tell "this project is busy". WorkspaceItem reads the same
 * `processingState` ref App.vue provides and shows a SessionSlider on
 * the item row when ANY of its tasks is processing.
 *
 * Updated 2026-08-29: the yellow spinner circle was replaced by a
 * SessionSlider that always renders the DOM element but is hidden
 * (`opacity: 0`, `aria-busy="false"`) when no worker is running.
 * Tests below assert on the VISIBLE state — count sliders with
 * `aria-busy="true"`. The slider also moved to the BOTTOM of the row
 * (was the leftmost slot); the DOM-order test was updated accordingly.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
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
  isActive: boolean = false,
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...itemWithTasks, tasks },
      isActive,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState },
    },
  })
  return { wrapper, processingState }
}

// Count only VISIBLE sliders (aria-busy="true").
const visibleItemSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="item-processing-spinner"][aria-busy="true"]')

describe('WorkspaceItem item-row processing slider', () => {
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

  it('shows no item-row slider when no task is in processingState', async () => {
    const { wrapper } = mountWorkspaceItem()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
  })

  it('shows an item-row slider when one of its tasks is in processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(1)
    // The item name must still be visible — the slider sits at the
    // bottom of the row, not in place of the name.
    expect(wrapper.text()).toContain('My Project')
  })

  it('hides the item-row slider when the last processing task is removed', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(1)
    // Worker SSE emits a 'deleted' event → App.vue clears the entry.
    processingState.value = {}
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
  })

  it('keeps the item-row slider visible when one of two tasks is still processing', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(1)
    // Clear only one — the other is still busy → slider stays.
    processingState.value = { task_beta: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(1)
  })

  it('shows no item-row slider for an unrelated session in processingState', async () => {
    // Guards the key-by-id contract: a session id that does NOT
    // match any task.id must not trigger the slider, even if the
    // map is non-empty.
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { session_someone_else: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
  })

  it('shows no item-row slider when the item has no tasks', async () => {
    const { wrapper, processingState } = mountWorkspaceItem([])
    // Even a non-empty processingState must not produce a slider if
    // the item has no tasks at all (no keys to match).
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
  })

  it('item-loading spinner and item-processing slider can render simultaneously in separate slots', async () => {
    // The two indicators live in different slots (loading on the right,
    // processing slider at the bottom) and represent independent states
    // (folder-contents fetch vs. LLM worker), so they must be able
    // to show at the same time. This guards against a future
    // regression that re-joins them into a single v-if chain.
    const processingState: Ref<Record<string, boolean>> = ref({ task_alpha: true })
    const wrapper = mount(WorkspaceItem, {
      props: {
        item: { ...itemWithTasks, isLoading: true },
        isActive: false,
        workspaceId: 'ws_1',
      },
      global: { provide: { processingState } },
    })
    expect(wrapper.findAll('[data-testid="item-loading-spinner"]')).toHaveLength(1)
    expect(visibleItemSpinners(wrapper)).toHaveLength(1)
  })

  it('active dot and item-processing slider can render simultaneously in separate slots', async () => {
    // Same reasoning as the loading/processing pair above: the
    // FolderExplorer active dot (right slot) and the LLM-processing
    // slider (bottom slot) are independent and must coexist. A user
    // can have a selected item that is also being worked on.
    const { wrapper, processingState } = mountWorkspaceItem(itemWithTasks.tasks, true)
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="item-active-dot"]')).toHaveLength(1)
  })

  it('item-loading spinner still hides the active dot (preserved right-slot priority)', async () => {
    // Even though the active dot no longer competes with the
    // processing slider, it must still be hidden while the loading
    // spinner is showing (original behavior, untouched by this
    // change).
    const processingState: Ref<Record<string, boolean>> = ref({})
    const wrapper = mount(WorkspaceItem, {
      props: {
        item: { ...itemWithTasks, isLoading: true },
        isActive: true,
        workspaceId: 'ws_1',
      },
      global: { provide: { processingState } },
    })
    expect(wrapper.findAll('[data-testid="item-loading-spinner"]')).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="item-active-dot"]')).toHaveLength(0)
  })

  it('item-processing slider appears AFTER the chevron in DOM order (bottom edge of row)', async () => {
    // The visual contract changed in 2026-08-29: the slider was
    // moved from the leftmost slot (where the yellow circle used
    // to sit) to the BOTTOM edge of the row (a thin yellow strip).
    // It now sits AFTER the chevron + content in DOM order, not
    // before. Verified by finding the chevron in the row's HTML
    // BEFORE the slider testid.
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    const row = wrapper.find('button')
    const html = row.html()
    const chevronIdx = html.indexOf('item-row-chevron')
    const sliderIdx = html.indexOf('item-processing-spinner')
    expect(chevronIdx).toBeGreaterThan(-1)
    expect(sliderIdx).toBeGreaterThan(-1)
    expect(sliderIdx).toBeGreaterThan(chevronIdx)
  })
})

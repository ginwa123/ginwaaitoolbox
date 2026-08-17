/**
 * Regression tests for the "workspace item row shows no spinner while
 * one of its tasks is processing" gap. The per-TASK row already has a
 * spinner (see workspaceItemTaskSpinner.spec.ts), but the per-ITEM row
 * (the project row) had no indicator at all — so a user who collapsed
 * the task list could not tell "this project is busy". WorkspaceItem
 * must read the same `processingState` ref App.vue provides and show a
 * yellow spinner on the item row when ANY of its tasks is processing.
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

describe('WorkspaceItem item-row processing spinner', () => {
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

  it('shows no item-row spinner when no task is in processingState', async () => {
    const { wrapper } = mountWorkspaceItem()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(0)
  })

  it('shows an item-row spinner when one of its tasks is in processingState', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    const spinners = wrapper.findAll('[data-testid="item-processing-spinner"]')
    expect(spinners).toHaveLength(1)
    // The item name must still be visible — the spinner sits in the
    // right-side slot, not in place of the name.
    expect(wrapper.text()).toContain('My Project')
  })

  it('hides the item-row spinner when the last processing task is removed', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(1)
    // Worker SSE emits a 'deleted' event → App.vue clears the entry.
    processingState.value = {}
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(0)
  })

  it('keeps the item-row spinner visible when one of two tasks is still processing', async () => {
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(1)
    // Clear only one — the other is still busy → spinner stays.
    processingState.value = { task_beta: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(1)
  })

  it('shows no item-row spinner for an unrelated session in processingState', async () => {
    // Guards the key-by-id contract: a session id that does NOT
    // match any task.id must not trigger the spinner, even if the
    // map is non-empty.
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { session_someone_else: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(0)
  })

  it('shows no item-row spinner when the item has no tasks', async () => {
    const { wrapper, processingState } = mountWorkspaceItem([])
    // Even a non-empty processingState must not produce a spinner if
    // the item has no tasks at all (no keys to match).
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(0)
  })

  it('item-loading spinner and item-processing spinner can render simultaneously in separate slots', async () => {
    // The two indicators live in different slots (loading on the right,
    // processing on the left) and represent independent states
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
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(1)
  })

  it('active dot and item-processing spinner can render simultaneously in separate slots', async () => {
    // Same reasoning as the loading/processing pair above: the
    // FolderExplorer active dot (right slot) and the LLM-processing
    // spinner (left slot) are independent and must coexist. A user
    // can have a selected item that is also being worked on.
    const { wrapper, processingState } = mountWorkspaceItem(itemWithTasks.tasks, true)
    processingState.value = { task_alpha: true }
    await nextTick()
    expect(wrapper.findAll('[data-testid="item-processing-spinner"]')).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="item-active-dot"]')).toHaveLength(1)
  })

  it('item-loading spinner still hides the active dot (preserved right-slot priority)', async () => {
    // Even though the active dot no longer competes with the
    // processing spinner, it must still be hidden while the
    // loading spinner is showing (original behavior, untouched by
    // this change).
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

  it('item-processing spinner appears BEFORE the chevron in DOM order (leftmost slot)', async () => {
    // The visual contract: the processing spinner must be the
    // leftmost element on the row, matching the chat-list and
    // per-task-row pattern. The chevron sits to its right.
    //
    // After the minimalist sidebar rewrite (2026-07-02), the
    // chevron is a unicode ▶ glyph inside a <span
    // data-testid="item-row-chevron"> — NOT an SVG path. The test
    // now keys off the testid instead of the path string, since
    // the chevron is no longer an SVG.
    const { wrapper, processingState } = mountWorkspaceItem()
    processingState.value = { task_alpha: true }
    await nextTick()
    const row = wrapper.find('button')
    const html = row.html()
    const spinnerIdx = html.indexOf('item-processing-spinner')
    const chevronIdx = html.indexOf('item-row-chevron')
    expect(spinnerIdx).toBeGreaterThan(-1)
    expect(chevronIdx).toBeGreaterThan(-1)
    expect(spinnerIdx).toBeLessThan(chevronIdx)
  })
})

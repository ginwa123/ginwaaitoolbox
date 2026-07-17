/**
 * Component tests for the "Load more" button at the bottom of an
 * expanded workspace item's task list. The button is the only path
 * to fetch the next page of tasks — there is no auto-load, no
 * scroll listener, no IntersectionObserver. Click-to-load only.
 *
 * Plan: docs/plans/2026-06-10-workspace-item-task-pagination.md
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const baseItem = {
  id: 'item_1',
  name: 'My Project',
  item_type: 'folder',
  tasks: [
    { id: 'task_alpha', name: 'Alpha task' },
    { id: 'task_beta', name: 'Beta task' },
  ],
}

function mountWorkspaceItem(
  overrides: { hasMoreTasks?: boolean; isLoadingMoreTasks?: boolean } = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...baseItem, ...overrides },
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
  // Tasks (and the Load More button) are only rendered when the
  // parent item is expanded. Mutate `expandedItemIds` and reassign
  // the ref to trigger reactivity, matching the production toggle in
  // stores/workspaces.ts:toggleExpandedItem.
  const ws = useWorkspacesStore()
  ws.expandedItemIds['item_1'] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

describe('WorkspaceItem Load More button', () => {
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

  it('renders the button with "Load more" text when hasMoreTasks is true', async () => {
    const { wrapper } = mountWorkspaceItem({ hasMoreTasks: true })
    expandItem()
    await nextTick()
    const btn = wrapper.find('[data-testid="load-more-tasks"]')
    expect(btn.exists()).toBe(true)
    expect(btn.text()).toBe('Load more')
  })

  it('hides the button when hasMoreTasks is false', async () => {
    const { wrapper } = mountWorkspaceItem({ hasMoreTasks: false })
    expandItem()
    await nextTick()
    expect(wrapper.find('[data-testid="load-more-tasks"]').exists()).toBe(false)
  })

  it('hides the button when hasMoreTasks is undefined (e.g. fetch failed)', async () => {
    // hasMoreTasks stays undefined when the per-item tasks fetch
    // throws during init() (workspaces.ts:193 errdefer). The button
    // must stay hidden in that case so the user doesn't see a
    // dangling button that does nothing.
    const { wrapper } = mountWorkspaceItem({})
    expandItem()
    await nextTick()
    expect(wrapper.find('[data-testid="load-more-tasks"]').exists()).toBe(false)
  })

  it('emits loadMoreTasks with [workspaceId, itemId] on click', async () => {
    const { wrapper } = mountWorkspaceItem({ hasMoreTasks: true })
    expandItem()
    await nextTick()
    const btn = wrapper.find('[data-testid="load-more-tasks"]')
    await btn.trigger('click')
    const emitted = wrapper.emitted('loadMoreTasks')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_1', 'item_1'])
  })

  it('shows the spinner and "Loading…" text while isLoadingMoreTasks is true', async () => {
    const { wrapper } = mountWorkspaceItem({
      hasMoreTasks: true,
      isLoadingMoreTasks: true,
    })
    expandItem()
    await nextTick()
    const btn = wrapper.find('[data-testid="load-more-tasks"]')
    expect(btn.text()).toBe('Loading…')
    // The spinner lives inside the button as a nested div
    expect(btn.find('div.animate-spin').exists()).toBe(true)
  })

  it('disables the button while isLoadingMoreTasks is true (no double-click)', async () => {
    const { wrapper } = mountWorkspaceItem({
      hasMoreTasks: true,
      isLoadingMoreTasks: true,
    })
    expandItem()
    await nextTick()
    const btn = wrapper.find('[data-testid="load-more-tasks"]')
    expect(btn.attributes('disabled')).toBeDefined()
  })

  it('does NOT emit selectTask when Load more is clicked (stopPropagation guard)', async () => {
    // The Load More button lives inside the task-list <div>, which is
    // a SIBLING of the main item row, so bubbling isn't strictly
    // necessary today. But the handler calls event.stopPropagation()
    // defensively — a future refactor that moves the button inside the
    // row <button> would otherwise trigger the row's @click handler
    // and emit selectTask as a side effect. This test guards the
    // stopPropagation.
    const { wrapper } = mountWorkspaceItem({ hasMoreTasks: true })
    expandItem()
    await nextTick()
    const btn = wrapper.find('[data-testid="load-more-tasks"]')
    await btn.trigger('click')
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  it('is hidden when the item is not expanded (v-if guards the whole list)', async () => {
    // The Load More button is INSIDE the `v-if="isExpanded && ..."`
    // wrapper, so it disappears when the item is collapsed. This
    // guards against a refactor that moves the button OUT of the
    // wrapper and accidentally shows it when the item is collapsed.
    const { wrapper } = mountWorkspaceItem({ hasMoreTasks: true })
    // NOTE: do NOT call expandItem() here — the item stays collapsed.
    await nextTick()
    expect(wrapper.find('[data-testid="load-more-tasks"]').exists()).toBe(false)
  })
})

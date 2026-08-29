/**
 * Regression tests for the "workspace row shows no slider while one of
 * its items has a processing task" gap. The ChatsList already shows a
 * slider on each chat row, and the per-task / per-item rows do the same
 * — but the workspace row (the top-level grouping) had only a count
 * badge, with no "busy" indicator. A user who collapsed the workspaces
 * section could not tell "something in this workspace is running"
 * without expanding it. WorkspaceList must read the same
 * `processingState` ref App.vue provides and render a SessionSlider on
 * the workspace row when ANY task in ANY item of the workspace is
 * processing.
 *
 * Updated 2026-08-29: the yellow spinner circle was replaced by a
 * SessionSlider. Count VISIBLE sliders only (aria-busy="true"). The
 * slider moved to the bottom of the row; DOM-order test now verifies
 * "after the chevron", not "before".
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore, type Workspace, type WorkspaceItem as WsItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeWorkspace(
  id: string,
  name: string,
  items: Array<WsItem & { tasks?: Array<{ id: string; name: string }> }> = [],
): Workspace {
  return {
    id,
    name,
    icon: '📂',
    expanded: false,
    items: items as WsItem[],
  }
}

function mountWorkspaceList(workspaces: Workspace[]) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceList, {
    props: {
      workspaces,
      activeWorkspaceItemId: null,
    },
    // WorkspaceList consumes useSidebarStore; create a Pinia first so
    // the store exists and the `workspacesExpanded` flag can be flipped
    // on for the slider rows to be visible.
    global: {
      provide: { processingState },
      // Stub WorkspaceItem so the test focuses on the workspace-row
      // indicators (slider / count badge) and not the items'
      // internal state.
      stubs: { WorkspaceItem: WorkspaceItem },
    },
  })
  const sidebar = useWorkspacesStore()
  void sidebar // silence unused
  return { wrapper, processingState }
}

// Count only VISIBLE workspace-row sliders (aria-busy="true").
const visibleWorkspaceSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-processing-spinner"][aria-busy="true"]')

describe('WorkspaceList workspace-row processing slider', () => {
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

  it('shows no workspace slider when no task is in processingState', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountWorkspaceList([ws])
    // Expand the workspaces section so the inner row is rendered.
    await wrapper.find('button').trigger('click')
    await nextTick()
    processingState.value = { task_x: true } // unrelated task
    await nextTick()
    expect(visibleWorkspaceSpinners(wrapper)).toHaveLength(0)
  })

  it('shows a workspace slider when one of its tasks is in processingState', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountWorkspaceList([ws])
    await wrapper.find('button').trigger('click')
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    expect(visibleWorkspaceSpinners(wrapper)).toHaveLength(1)
  })

  it('hides the workspace slider when the last processing task is removed', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountWorkspaceList([ws])
    await wrapper.find('button').trigger('click')
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    expect(visibleWorkspaceSpinners(wrapper)).toHaveLength(1)
    // Worker SSE emits 'deleted' → App.vue clears the entry.
    processingState.value = {}
    await nextTick()
    expect(visibleWorkspaceSpinners(wrapper)).toHaveLength(0)
  })

  it('shows the count badge alongside the processing slider (separate slots)', async () => {
    // The processing slider lives at the bottom of the row; the count
    // badge lives in the right slot. They are independent indicators
    // (busy-ness vs. size) and must be able to render at the same
    // time.
    const ws = makeWorkspace('ws_1', 'Coding', [
      { id: 'item_1', name: 'be', item_type: 'folder', tasks: [{ id: 'task_a', name: 'A' }] },
      { id: 'item_2', name: 'fe', item_type: 'folder', tasks: [] },
    ])
    const { wrapper, processingState } = mountWorkspaceList([ws])
    await wrapper.find('button').trigger('click')
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    expect(visibleWorkspaceSpinners(wrapper)).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="workspace-count-badge"]')).toHaveLength(1)
    expect(wrapper.text()).toContain('2')
  })

  it('renders one slider per workspace that has a processing task', async () => {
    // Two workspaces, two processing tasks in different workspaces →
    // two sliders, one on each workspace row.
    const wsA = makeWorkspace('ws_a', 'Alpha', [
      { id: 'item_a', name: 'a', item_type: 'folder', tasks: [{ id: 'task_alpha', name: 'A' }] },
    ])
    const wsB = makeWorkspace('ws_b', 'Beta', [
      { id: 'item_b', name: 'b', item_type: 'folder', tasks: [{ id: 'task_beta', name: 'B' }] },
    ])
    const { wrapper, processingState } = mountWorkspaceList([wsA, wsB])
    await wrapper.find('button').trigger('click')
    await nextTick()
    processingState.value = { task_alpha: true, task_beta: true }
    await nextTick()
    expect(visibleWorkspaceSpinners(wrapper)).toHaveLength(2)
  })

  it('workspace processing slider appears AFTER the chevron in DOM order (bottom edge of row)', async () => {
    // The visual contract changed in 2026-08-29: the slider was
    // moved from the leftmost slot (where the yellow circle used
    // to sit) to the BOTTOM edge of the row. It now sits AFTER the
    // chevron + count badge in DOM order.
    const ws = makeWorkspace('ws_1', 'Coding', [
      { id: 'item_1', name: 'be', item_type: 'folder', tasks: [{ id: 'task_a', name: 'A' }] },
    ])
    const { wrapper, processingState } = mountWorkspaceList([ws])
    await wrapper.find('button').trigger('click')
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    // The workspace row is the FIRST <button> inside the inner
    // v-show block. The section header is the first <button> overall
    // — we already clicked it to expand. The second <button> is the
    // workspace row.
    const buttons = wrapper.findAll('button')
    // Find the workspace row button: it is the one whose HTML
    // contains the workspace name "Coding" and a chevron arrow.
    const row = buttons.find((b) => b.text().includes('Coding'))!
    const html = row.html()
    const chevronCharIdx = html.indexOf('▶')
    const sliderIdx = html.indexOf('workspace-processing-spinner')
    expect(chevronCharIdx).toBeGreaterThan(-1)
    expect(sliderIdx).toBeGreaterThan(-1)
    expect(sliderIdx).toBeGreaterThan(chevronCharIdx)
  })
})

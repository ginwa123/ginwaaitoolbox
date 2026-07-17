/**
 * Regression tests for the "workspace row shows no spinner while one of
 * its items has a processing task" gap. The ChatsList already shows a
 * spinner on the leftmost slot of each chat row, and the per-task /
 * per-item rows do the same — but the workspace row (the top-level
 * grouping) had only a count badge, with no "busy" indicator. A user
 * who collapsed the workspaces section could not tell "something in
 * this workspace is running" without expanding it. WorkspaceList must
 * read the same `processingState` ref App.vue provides and render a
 * yellow spinner on the workspace row (in the same leftmost slot the
 * ChatsList and task rows use) when ANY task in ANY item of the
 * workspace is processing.
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
    // on for the spinner rows to be visible (the spinner only renders
    // inside the Transition block, which is gated on
    // sidebarStore.workspacesExpanded).
    global: {
      provide: { processingState },
      // Stub WorkspaceItem so the test focuses on the workspace-row
      // indicators (spinner / count badge) and not the items'
      // internal state. The stub still renders so the parent layout
      // (workspaces list → workspaces group → item rows) is exercised.
      stubs: { WorkspaceItem: true },
    },
  })
  // Expand the workspaces section so the inner row is rendered.
  const sidebar = useWorkspacesStore()
  // The sidebar store in the desktop app exposes `workspacesExpanded`
  // via useSidebarStore. We don't have a direct handle here, so
  // instead we mutate the store via the public action used by
  // WorkspaceList itself: clicking the section header button. Easier
  // path: dispatch the store action via the wrapper's bound method.
  // Workaround: WorkspaceList reads `sidebarStore.workspacesExpanded`
  // — find the button and click it. We use a simpler approach: set the
  // value directly on the underlying ref via the store, but since
  // WorkspaceList is what toggles it, we drive it through a DOM event.
  // Simplest: just toggle via the component's first button (the
  // section header).
  void sidebar // silence unused
  return { wrapper, processingState }
}

describe('WorkspaceList workspace-row processing spinner', () => {
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

  it('shows no workspace spinner when no task is in processingState', async () => {
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
    expect(wrapper.findAll('[data-testid="workspace-processing-spinner"]')).toHaveLength(0)
  })

  it('shows a workspace spinner when one of its tasks is in processingState', async () => {
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
    const spinners = wrapper.findAll('[data-testid="workspace-processing-spinner"]')
    expect(spinners).toHaveLength(1)
  })

  it('hides the workspace spinner when the last processing task is removed', async () => {
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
    expect(wrapper.findAll('[data-testid="workspace-processing-spinner"]')).toHaveLength(1)
    // Worker SSE emits 'deleted' → App.vue clears the entry.
    processingState.value = {}
    await nextTick()
    expect(wrapper.findAll('[data-testid="workspace-processing-spinner"]')).toHaveLength(0)
  })

  it('shows the count badge alongside the processing spinner (separate slots)', async () => {
    // The processing spinner lives in the left slot; the count badge
    // lives in the right slot. They are independent indicators
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
    expect(wrapper.findAll('[data-testid="workspace-processing-spinner"]')).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="workspace-count-badge"]')).toHaveLength(1)
    expect(wrapper.text()).toContain('2')
  })

  it('renders one spinner per workspace that has a processing task', async () => {
    // Two workspaces, two processing tasks in different workspaces →
    // two spinners, one on each workspace row.
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
    expect(wrapper.findAll('[data-testid="workspace-processing-spinner"]')).toHaveLength(2)
  })

  it('workspace processing spinner appears BEFORE the chevron in DOM order (leftmost slot)', async () => {
    // Visual contract: spinner is the leftmost indicator on the row,
    // matching the chat-list and per-task-row pattern. The chevron
    // sits to its right.
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
    const spinnerIdx = html.indexOf('workspace-processing-spinner')
    const chevronIdx = html.indexOf('rotate(90deg)') // chevron with the expanded style
    // Chevron may not have rotate(90deg) when collapsed — instead
    // look for the literal "▶" character which is the chevron glyph.
    const chevronCharIdx = html.indexOf('▶')
    expect(spinnerIdx).toBeGreaterThan(-1)
    expect(chevronCharIdx).toBeGreaterThan(-1)
    expect(spinnerIdx).toBeLessThan(chevronCharIdx)
  })
})

/**
 * The busy indicator for the SELECTED workspace now lives in the
 * Projects section header — the workspace rows it used to sit on are
 * gone (revamp plan:
 * docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md).
 *
 * ProjectsList must read the same `processingState` ref App.vue
 * provides and render a SessionSlider in the section header when ANY
 * task in ANY item of the selected workspace is processing. Count
 * VISIBLE sliders only (aria-busy="true").
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { type Workspace, type WorkspaceItem as WsItem } from '../stores/workspaces'
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
    expanded: true,
    items: items as WsItem[],
  }
}

function mountProjectsList(workspace: Workspace | null) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(ProjectsList, {
    props: {
      workspace,
      activeWorkspaceItemId: null,
    },
    global: {
      provide: { processingState },
      // Render the real WorkspaceItem so its (stubbed-key) presence
      // matches production; the slider under test is in the header.
      stubs: { WorkspaceItem: WorkspaceItem },
    },
  })
  return { wrapper, processingState }
}

const visibleHeaderSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-processing-spinner"][aria-busy="true"]')

describe('ProjectsList section-header processing slider', () => {
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
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountProjectsList(ws)
    await nextTick()
    processingState.value = { task_x: true } // unrelated task
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('shows the slider when one of the selected workspace tasks is processing', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountProjectsList(ws)
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(1)
    wrapper.unmount()
  })

  it('hides the slider when the last processing task is removed', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountProjectsList(ws)
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(1)
    // Worker SSE emits 'deleted' → App.vue clears the entry.
    processingState.value = {}
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('slider renders in the section header AFTER the chevron in DOM order', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, processingState } = mountProjectsList(ws)
    await nextTick()
    processingState.value = { task_a: true }
    await nextTick()
    const header = wrapper
      .findAll('button')
      .find((b) => b.text().includes('Projects'))!
    const html = header.html()
    const chevronIdx = html.indexOf('▶')
    const sliderIdx = html.indexOf('workspace-processing-spinner')
    expect(chevronIdx).toBeGreaterThan(-1)
    expect(sliderIdx).toBeGreaterThan(-1)
    expect(sliderIdx).toBeGreaterThan(chevronIdx)
    wrapper.unmount()
  })

  it('renders no slider (and the empty-state hint) when there is no selected workspace', async () => {
    const { wrapper, processingState } = mountProjectsList(null)
    await nextTick()
    processingState.value = { task_any: true }
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(wrapper.find('[data-testid="projects-no-workspace"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

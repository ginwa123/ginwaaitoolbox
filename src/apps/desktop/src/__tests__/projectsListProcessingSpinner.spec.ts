/**
 * The busy indicator for the SELECTED workspace now lives in the
 * Projects section header — the workspace rows it used to sit on are
 * gone (revamp plan:
 * docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md).
 *
 * ProjectsList must read the same `processingState` ref App.vue
 * provides and render the elapsed time pill in the section header when
 * ANY task in ANY item of the selected workspace is running. The circle
 * spinner was removed — the time pill is the only marker.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
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
  const workerActivity = ref<Record<string, WorkerActivity>>({})
  const workerNow = ref(Date.now())
  const wrapper = mount(ProjectsList, {
    props: {
      workspace,
      activeWorkspaceItemId: null,
    },
    global: {
      provide: { processingState, workerActivity, workerNow },
      // Render the real WorkspaceItem so its (stubbed-key) presence
      // matches production; the chip under test is in the header.
      stubs: { WorkspaceItem: WorkspaceItem },
    },
  })
  const setBusy = (ids: string[]) => {
    const now = Date.now()
    processingState.value = Object.fromEntries(ids.map((id) => [id, true]))
    workerActivity.value = Object.fromEntries(
      ids.map((id) => [
        id,
        { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
      ]),
    )
  }
  const clearBusy = () => {
    processingState.value = {}
    workerActivity.value = {}
  }
  return { wrapper, processingState, workerActivity, setBusy, clearBusy }
}

const visibleHeaderSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-processing-spinner"]')
const visibleHeaderChips = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-elapsed-chip"]')

describe('ProjectsList section-header elapsed chip', () => {
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

  it('shows no chip when no task is busy', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_x']) // unrelated task
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('shows the chip when one of the selected workspace tasks is running', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_a'])
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(1)
    wrapper.unmount()
  })

  it('hides the chip when the last busy task finishes', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy, clearBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_a'])
    await nextTick()
    expect(visibleHeaderChips(wrapper)).toHaveLength(1)
    // Worker SSE emits 'deleted' → App.vue clears the entry.
    clearBusy()
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('chip renders in the section header AFTER the chevron in DOM order', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_a'])
    await nextTick()
    const header = wrapper.findAll('button').find((b) => b.text().includes('Projects'))!
    const html = header.html()
    const chevronIdx = html.indexOf('▶')
    const chipIdx = html.indexOf('workspace-elapsed-chip')
    expect(chevronIdx).toBeGreaterThan(-1)
    expect(chipIdx).toBeGreaterThan(-1)
    expect(chipIdx).toBeGreaterThan(chevronIdx)
    wrapper.unmount()
  })

  it('renders no chip (and the empty-state hint) when there is no selected workspace', async () => {
    const { wrapper, setBusy } = mountProjectsList(null)
    await nextTick()
    setBusy(['task_any'])
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    expect(wrapper.find('[data-testid="projects-no-workspace"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

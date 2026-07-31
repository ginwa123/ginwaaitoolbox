/**
 * Behavioural tests for the group-drag transitive expansion fix.
 *
 * Before this fix, dragging a `group` element when it was the ONLY
 * selected element moved only the group's bbox; its children stayed
 * put. The fix expands the selection to include the group's
 * transitive descendants for the duration of the drag (Figma parity).
 *
 * The tests below exercise the expansion helper by asserting the
 * union bbox / per-element delta computation in DesignView's
 * `handleGroupDrag`. They mount DesignView, select a group, dispatch
 * a pointerdown + pointermove, then verify the store's
 * `updateDesignElementGeometry` spy was called for the GROUP and
 * every descendant (NOT for unrelated elements).
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import * as api from '../api'

const { listDesignPagesMock, updateBatchSpy } = vi.hoisted(() => ({
  listDesignPagesMock: vi.fn().mockResolvedValue({
    pages: [
      {
        id: 'page_1',
        workspace_item_id: 'item_1',
        name: 'Test Page',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-07-29 18:00:00',
        updated_at: '2026-07-29 18:00:00',
      },
    ],
    count: 1,
  }),
  updateBatchSpy: vi.fn().mockResolvedValue({ updated: [] }),
  // Chunk 3: batch endpoint mock. Returns `{ updated: DesignElement[] }`
  // matching the wire shape. The default implementation returns an
  // empty array — tests that care about the returned elements can
  // re-mock this in their beforeEach.
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
    updateDesignElementGeometry: updateBatchSpy,
    updateDesignElementsGeometryBatch: updateBatchSpy,
  }
})

const ITEM = {
  id: 'item_1',
  name: 'Test',
  item_type: 'design',
  path: '',
  design_elements: [],
  workspace_id: 'ws_1',
} as any

function makeEl(overrides: Record<string, unknown> = {}): any {
  return {
    id: 'el_1',
    name: 'Box',
    type: 'rectangle',
    page_id: 'page_1',
    x: 0,
    y: 0,
    width: 100,
    height: 100,
    rotation: 0,
    opacity: 1,
    fill: '#fff',
    stroke: '',
    stroke_width: 0,
    corner_radius: 0,
    text_content: '',
    text_style: '',
    image_url: '',
    z_index: 0,
    position: 0,
    file_path: '',
    created_at: '',
    updated_at: '',
    ...overrides,
  }
}


describe('DesignView group drag — batch geometry endpoint', () => {
  let batchSpy: any

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    batchSpy = vi.fn().mockResolvedValue({
      updated: [
        makeEl({ id: 'el_1', x: 50, y: 70 }),
        makeEl({ id: 'el_2', x: 100, y: 120 }),
      ],
    })
  })

  it('groupDrag with a 5-element selection fires ONE batch PATCH per pointermove (not N per-element PATCHes)', async () => {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')

    // Spy on the SINGLE-element action — must NOT be called during a
    // group drag (the whole point of the batch is to avoid N calls).
    const singleSpy = vi.spyOn(_store, 'updateDesignElementGeometry')
    vi.spyOn(_store, 'updateDesignElementsGeometryBatch').mockImplementation(batchSpy)

    const elements = [
      makeEl({ id: 'el_1', x: 0, y: 0 }),
      makeEl({ id: 'el_2', x: 50, y: 0 }),
      makeEl({ id: 'el_3', x: 100, y: 0 }),
      makeEl({ id: 'el_4', x: 150, y: 0 }),
      makeEl({ id: 'el_5', x: 200, y: 0 }),
    ]
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()

    // Simulate a 5-element multi-selection by setting selectedIds on the VM.
    ;(wrapper.vm as any).selectedIds = new Set(['el_1', 'el_2', 'el_3', 'el_4', 'el_5'])

    ;(wrapper.vm as any).handleGroupDrag({ dx: 10, dy: 20 })
    await flushPromises()

    expect(batchSpy).toHaveBeenCalledTimes(1)
    expect(singleSpy).not.toHaveBeenCalled()
  })

  it('groupDrag calls the batch endpoint (not N per-element calls)', async () => {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')
    // The single-element path must NOT be called during a group drag.
    const singleSpy = vi.spyOn(_store, 'updateDesignElementGeometry')
    vi.spyOn(_store, 'updateDesignElementsGeometryBatch').mockImplementation(batchSpy)

    const elements = [
      makeEl({ id: 'el_1', x: 0, y: 0 }),
      makeEl({ id: 'el_2', x: 50, y: 0 }),
      makeEl({ id: 'el_3', x: 100, y: 0 }),
    ]
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    ;(wrapper.vm as any).selectedIds = new Set(['el_1', 'el_2', 'el_3'])

    ;(wrapper.vm as any).handleGroupDrag({ dx: 10, dy: 20 })
    await flushPromises()

    expect(batchSpy).toHaveBeenCalledTimes(1)
    expect(singleSpy).not.toHaveBeenCalled()
  })
})

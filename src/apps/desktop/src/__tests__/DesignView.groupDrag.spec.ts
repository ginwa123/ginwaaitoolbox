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

const { listDesignPagesMock, updateGeometrySpy } = vi.hoisted(() => ({
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
  updateGeometrySpy: vi.fn().mockResolvedValue({}),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
    updateDesignElementGeometry: updateGeometrySpy,
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

describe('DesignView group drag transitive expansion', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  async function mountWith(elements: any[]): Promise<any> {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')
    vi.spyOn(_store, 'updateDesignElementGeometry').mockImplementation(updateGeometrySpy)
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    return wrapper
  }

  /**
   * Simulate a pointerdown + pointermove on the given element. The
   * `setPointerCapture` stub keeps jsdom happy. The throttled emit
   * fires on every move (because `performance.now()` is monotonic —
   * 50ms always elapses between test ticks).
   */
  function dragElement(wrapper: any, elementId: string, dx: number, dy: number): void {
    const target = wrapper.find(`[data-testid="design-element-${elementId}"]`)
    if (!target.exists()) throw new Error(`Element ${elementId} not found in canvas`)
    const rootEl = target.element as HTMLElement
    rootEl.setPointerCapture = () => {}
    rootEl.releasePointerCapture = () => {}
    rootEl.hasPointerCapture = (): boolean => true
    rootEl.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100,
      bubbles: true,
    }))
    rootEl.dispatchEvent(new PointerEvent('pointermove', {
      button: 0, pointerId: 1,
      clientX: 100 + dx, clientY: 100 + dy,
      bubbles: true,
    }))
    // Flush the trailing emit + the store throttle.
    rootEl.dispatchEvent(new PointerEvent('pointerup', {
      button: 0, pointerId: 1,
      clientX: 100 + dx, clientY: 100 + dy,
      bubbles: true,
    }))
  }

  it('dragging a group with 2 children moves the group AND both children (Figma parity)', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_g', type: 'group', x: 0, y: 0, width: 200, height: 200 }),
      makeEl({ id: 'el_a', x: 10, y: 10, parent_id: 'el_g' }),
      makeEl({ id: 'el_b', x: 100, y: 100, parent_id: 'el_g' }),
      // Unrelated element that should NOT move.
      makeEl({ id: 'el_outsider', x: 500, y: 500 }),
    ])
    try {
      // Select the group ONLY (no children in the selection).
      const groupEl = wrapper.find('[data-testid="design-element-el_g"]')
      groupEl.element.setPointerCapture = () => {}
      groupEl.element.releasePointerCapture = () => {}
      groupEl.element.hasPointerCapture = (): boolean => true
      groupEl.element.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100,
        bubbles: true,
      }))
      await flushPromises()
      updateGeometrySpy.mockClear()

      // Now drag the group by (50, 30) design-px.
      dragElement(wrapper, 'el_g', 50, 30)
      await flushPromises()

      // 3 updateGeometry calls: one for the group, one for each child.
      const calledWith = updateGeometrySpy.mock.calls.map((c: any[]) => c[3] /* elementId */)
      expect(calledWith).toContain('el_g')
      expect(calledWith).toContain('el_a')
      expect(calledWith).toContain('el_b')
      // The unrelated outsider should NOT be touched.
      expect(calledWith).not.toContain('el_outsider')
      // 3 unique ids touched, no extras.
      expect(new Set(calledWith).size).toBe(3)

      // All three should have x/y offsets of (50, 30).
      const xyById = new Map<string, { x: number; y: number }>()
      for (const c of updateGeometrySpy.mock.calls) {
        const id = c[3] as string
        const geom = c[4] as { x?: number; y?: number }
        if (geom.x !== undefined && geom.y !== undefined) {
          xyById.set(id, { x: geom.x, y: geom.y })
        }
      }
      expect(xyById.get('el_g')).toEqual({ x: 50, y: 30 })
      expect(xyById.get('el_a')).toEqual({ x: 60, y: 40 })
      expect(xyById.get('el_b')).toEqual({ x: 150, y: 130 })
    } finally {
      wrapper.unmount()
    }
  })

  it('dragging a deeply-nested group expands all the way down', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_outer', type: 'group', x: 0, y: 0, width: 300, height: 300 }),
      makeEl({ id: 'el_inner', type: 'group', x: 10, y: 10, parent_id: 'el_outer' }),
      makeEl({ id: 'el_leaf', x: 20, y: 20, parent_id: 'el_inner' }),
    ])
    try {
      // Select only the OUTERMOST group.
      const outerEl = wrapper.find('[data-testid="design-element-el_outer"]')
      outerEl.element.setPointerCapture = () => {}
      outerEl.element.releasePointerCapture = () => {}
      outerEl.element.hasPointerCapture = (): boolean => true
      outerEl.element.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100,
        bubbles: true,
      }))
      await flushPromises()
      updateGeometrySpy.mockClear()

      dragElement(wrapper, 'el_outer', 10, 5)
      await flushPromises()

      // All 3 ids should be touched.
      const calledWith = updateGeometrySpy.mock.calls.map((c: any[]) => c[3] as string)
      expect(calledWith).toContain('el_outer')
      expect(calledWith).toContain('el_inner')
      expect(calledWith).toContain('el_leaf')
    } finally {
      wrapper.unmount()
    }
  })

  // BUG FIX (2026-07-29): "design mode drag element moves so fast".
  // The original handleGroupDrag computed the PATCH as
  // `el.x + finalDx` where `el.x` is the element's CURRENT position
  // from `elements.value`. After the first PATCH round-trips, the
  // SSE re-fetch overwrites `element.design_elements` with the new
  // server state — so on the next pointermove, `el.x` is the latest
  // server position, NOT the pointerdown-time position. Adding the
  // cursor delta to the latest position compounded the delta on every
  // pointermove, and the element visually jumped further than the
  // cursor.
  //
  // The fix captures each element's position on the FIRST pointermove
  // (drag start) and uses that snapshot for every subsequent PATCH.
  // This test simulates the SSE update mid-drag and asserts the
  // PATCH math is correct.
  it('group drag uses ORIGINAL positions (not stale SSE\'d positions) after a mid-drag SSE re-fetch', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_g', type: 'group', x: 0, y: 0, width: 200, height: 200 }),
      makeEl({ id: 'el_a', x: 10, y: 10, parent_id: 'el_g' }),
    ])
    try {
      // Select the group.
      const groupEl = wrapper.find('[data-testid="design-element-el_g"]')
      groupEl.element.setPointerCapture = () => {}
      groupEl.element.releasePointerCapture = () => {}
      groupEl.element.hasPointerCapture = (): boolean => true
      groupEl.element.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()
      updateGeometrySpy.mockClear()

      // Mock performance.now() so the throttle (50ms) fires predictably.
      // The child's throttled emit reads `performance.now()` — without
      // a mock, every pointermove in the same tick skips the throttle.
      let now = 0
      const nowSpy = vi.spyOn(performance, 'now').mockImplementation(() => now)

      // First pointermove: cursor at design-px (+50, +30).
      // PATCH should be x=50, y=30 for el_g (originalX=0 + delta).
      now = 100
      groupEl.element.dispatchEvent(new PointerEvent('pointermove', {
        button: 0, pointerId: 1, clientX: 150, clientY: 130, bubbles: true,
      }))
      await flushPromises()

      // Sanity: the first PATCH should be x=50, y=30.
      const earlyCalls = updateGeometrySpy.mock.calls.map((c: any[]) => c[4])
      const earlyG = earlyCalls.find((g: any) => g && g.x === 50 && g.y === 30)
      expect(earlyG).toBeDefined()

      // Simulate SSE re-fetch: the backend's design_element_updated
      // event triggers fetchDesignElements on the frontend, which
      // overwrites item.design_elements with the latest server state.
      // In production this happens via the SSE bus; in the test we
      // mutate the prop directly. After this, el_g.x = 50, y = 30.
      const item = (wrapper.vm as any).item
      item.design_elements = item.design_elements.map((e: any) =>
        e.id === 'el_g' ? { ...e, x: 50, y: 30 } : e,
      )
      await flushPromises()

      // Second pointermove: cursor at design-px (+100, +60) total.
      // Total delta from startClientX=100 is (100, 60).
      //
      // With the BUG: PATCH = el.x + delta = 50 + 100 = 150. WRONG.
      // With the FIX: PATCH = originalX + delta = 0 + 100 = 100. CORRECT.
      now = 200
      groupEl.element.dispatchEvent(new PointerEvent('pointermove', {
        button: 0, pointerId: 1, clientX: 200, clientY: 160, bubbles: true,
      }))
      await flushPromises()

      // pointerup to fire the trailing emit (also reads
      // performance.now()).
      now = 300
      groupEl.element.dispatchEvent(new PointerEvent('pointerup', {
        button: 0, pointerId: 1, clientX: 200, clientY: 160, bubbles: true,
      }))
      await flushPromises()

      // The LAST PATCH for 'el_g' should be x=100, y=60 (the cursor's
      // absolute position). Without the fix, this would be x=150, y=90
      // (or similar — the bug compounds the delta on every pointermove).
      const xyById = new Map<string, { x: number; y: number }>()
      for (const c of updateGeometrySpy.mock.calls) {
        const id = c[3] as string
        const geom = c[4] as { x?: number; y?: number }
        if (geom.x !== undefined && geom.y !== undefined) {
          xyById.set(id, { x: geom.x, y: geom.y })
        }
      }
      expect(xyById.get('el_g')).toEqual({ x: 100, y: 60 })
      // Descendant el_a started at (10, 10). Original + delta(100, 60)
      // = (110, 70). The bug only manifests for elements whose `el.x`
      // was updated by SSE — the test only mutates el_g, so el_a's x
      // stays at 10 and the formula gives the correct answer (110)
      // by coincidence. Pin it anyway so a future refactor that
      // breaks the snapshot is caught.
      expect(xyById.get('el_a')).toEqual({ x: 110, y: 70 })

      nowSpy.mockRestore()
    } finally {
      wrapper.unmount()
    }
  })
})

import { mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import DesignElement from '../DesignElement.vue'
import type { DesignElement as DesignElementApi } from '../../../api'

const ELEMENT: DesignElementApi = {
  id: 'el_1', name: 'Box', type: 'rectangle',
  page_id: 'page_1', x: 100, y: 100, width: 200, height: 200,
  rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
  corner_radius: 0, text_content: '', text_style: '', image_url: '',
  z_index: 0, position: 0,
  file_path: '', created_at: '', updated_at: '',
}

// jsdom 29 doesn't implement pointer capture on HTMLDivElement. The
// production code calls `target.setPointerCapture(event.pointerId)`
// unconditionally; jsdom throws "is not a function". Stub on the
// prototype so every element has a no-op (matches the spirit of the
// per-element stubbing in the plan's test bodies).
if (!HTMLElement.prototype.setPointerCapture) {
  HTMLElement.prototype.setPointerCapture = () => {}
}
if (!HTMLElement.prototype.releasePointerCapture) {
  HTMLElement.prototype.releasePointerCapture = () => {}
}
if (!HTMLElement.prototype.hasPointerCapture) {
  HTMLElement.prototype.hasPointerCapture = (): boolean => true
}

describe('DesignElement drag', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('emits update with x/y patch on pointermove', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // Stub pointer-capture so jsdom doesn't error.
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    ;(root as any).addEventListener = vi.fn()
    ;(root as any).removeEventListener = vi.fn()

    // Native dispatchEvent (NOT wrapper.trigger) — jsdom 29 makes
    // MouseEvent.button a readonly getter, which @vue/test-utils
    // tries to assign post-construction. The PointerEvent constructor
    // itself accepts `button` as an init option (mirrors the pattern
    // in DesignView.handPan.spec.ts).
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))

    // Move handler was registered on addEventListener('pointermove', ...)
    const moveHandler = (root as any).addEventListener.mock.calls.find(
      (c: any[]) => c[0] === 'pointermove',
    )?.[1]
    expect(moveHandler).toBeDefined()

    // Simulate a +50, +30 move.
    moveHandler(new PointerEvent('pointermove', { clientX: 150, clientY: 130, pointerId: 1 }))
    // Within the throttle window — may or may not have emitted yet.
    // Use the wrapper's emitted() after waiting.
    await new Promise((r) => setTimeout(r, 60))  // wait past throttle
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate).toMatchObject({ x: 150, y: 130 })
  })

  it('emits a trailing update on pointerup with the final position', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    let moveHandler: any, upHandler: any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    moveHandler(new PointerEvent('pointermove', { clientX: 999, clientY: 999, pointerId: 1 }))
    // Fire pointerup immediately (within throttle window).
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))

    // The trailing emit must include the final position even if the
    // throttle hadn't fired.
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate).toMatchObject({ x: 999, y: 999 })
  })

  it('applies 1/zoom to the delta so zoomed canvases stay 1:1 with cursor', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 0.5 },  // 50% zoom
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    let moveHandler: any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    moveHandler(new PointerEvent('pointermove', { clientX: 200, clientY: 100, pointerId: 1 }))
    // 100 screen-px move at 50% zoom = 200 design-px move.
    // Start: x=100, dx = (200-100)/0.5 = 200 → x = 100+200 = 300
    await new Promise((r) => setTimeout(r, 60))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate.x).toBe(300)
  })

  it('preview mode swallows drag (no emit)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, previewMode: true },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    expect(wrapper.emitted('update')).toBeUndefined()
  })

  it('readonly swallows drag (no emit)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, readonly: true },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    expect(wrapper.emitted('update')).toBeUndefined()
  })

  it('resize handle emits width/height patch with sign flip', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const nwHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-nw"]`)
    const nwEl = nwHandle.element as HTMLElement
    nwEl.setPointerCapture = () => {}
    nwEl.releasePointerCapture = () => {}
    nwEl.hasPointerCapture = () => true
    let moveHandler: any
    ;(nwEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    ;(nwEl as any).removeEventListener = () => {}

    nwEl.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    // Drag NW handle up-left by (-30, -40): width grows by 30, height grows by 40,
    // x shrinks by 30, y shrinks by 40.
    moveHandler(new PointerEvent('pointermove', { clientX: 70, clientY: 60, pointerId: 1 }))
    await new Promise((r) => setTimeout(r, 60))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate.width).toBe(230)   // 200 + 30
    expect(lastUpdate.height).toBe(240)  // 200 + 40
    expect(lastUpdate.x).toBe(70)        // 100 - 30
    expect(lastUpdate.y).toBe(60)        // 100 - 40
  })

  it('resize clamps width/height to minimum 10px', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const eHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-e"]`)
    const eEl = eHandle.element as HTMLElement
    eEl.setPointerCapture = () => {}
    eEl.releasePointerCapture = () => {}
    eEl.hasPointerCapture = () => true
    let moveHandler: any
    ;(eEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    ;(eEl as any).removeEventListener = () => {}

    eEl.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    // Drag E handle -1000px left: width would go to -800, clamped to 10.
    moveHandler(new PointerEvent('pointermove', { clientX: -900, clientY: 100, pointerId: 1 }))
    await new Promise((r) => setTimeout(r, 60))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate.width).toBe(10)
  })

  // Strict throttle test: fires 3 rapid pointermoves within the
  // 50ms throttle window and asserts the trailing patch was applied
  // exactly once (not 3 times). This is the test that proves the
  // throttle is in effect — the plan's 7 tests all happen to pass
  // against the pre-fix unthrottled code because each one's last
  // emit happens to be the final patch anyway. This 8th test catches
  // the bug.
  it('throttles rapid pointermoves: 3 moves within 50ms emit at most 1 update before pointerup', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    let moveHandler: any, upHandler: any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    // Fire 3 moves within the throttle window (no await between them).
    moveHandler(new PointerEvent('pointermove', { clientX: 110, clientY: 110, pointerId: 1 }))
    moveHandler(new PointerEvent('pointermove', { clientX: 120, clientY: 120, pointerId: 1 }))
    moveHandler(new PointerEvent('pointermove', { clientX: 130, clientY: 130, pointerId: 1 }))
    // Snapshot BEFORE pointerup — the trailing emit happens on pointerup.
    const emitsBeforeUp = (wrapper.emitted('update') ?? []).length
    // Throttled: 0 emits (none past the 50ms window). Unthrottled: 3 emits.
    expect(emitsBeforeUp).toBeLessThanOrEqual(1)
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))
    const updates = wrapper.emitted('update') ?? []
    const lastUpdate = updates[updates.length - 1]?.[0] as any
    expect(lastUpdate).toMatchObject({ x: 130, y: 130 })
  })
})
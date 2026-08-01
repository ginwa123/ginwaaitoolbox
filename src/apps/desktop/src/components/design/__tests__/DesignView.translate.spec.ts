/**
 * Behavioural tests for the SINGLE-element drag wire.
 *
 * Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
 *
 * The wire is:
 *   1. User pointerdown on a single (non-group) element body.
 *   2. DesignElement.vue fires `translate` with the (dx, dy) cursor delta.
 *   3. DesignView.vue's `@translate="handleElementTranslate"` handler
 *      receives the delta and emits `translateElement(id, dx, dy)` upward.
 *   4. AppLayout.vue's `@translate-element="handleDesignTranslateElement"`
 *      calls `useDesignHandlers.translateElement` which calls
 *      `workspacesStore.translateDesignElement` which POSTs
 *      `/api/workspaces/.../elements/:id/translate`.
 *
 * This test exercises steps 1-3 by mounting DesignView, dispatching
 * pointerdown + pointermove + pointerup, and asserting the
 * `translateElement` emit carries the right (id, dx, dy).
 *
 * Companion spec `workspacesStoreTranslateResize.spec.ts` covers
 * step 4 at the store layer.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../DesignView.vue'
import { useWorkspacesStore } from '../../../stores/workspaces'

const { listDesignPagesMock } = vi.hoisted(() => ({
  listDesignPagesMock: vi.fn().mockResolvedValue({
    pages: [
      {
        id: 'page_1',
        workspace_item_id: 'item_1',
        name: 'Test Page',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-08-06 00:00:00',
        updated_at: '2026-08-06 00:00:00',
      },
    ],
    count: 1,
  }),
}))

vi.mock('../../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../api')>()
  return { ...actual, listDesignPages: listDesignPagesMock }
})

const ELEMENT = {
  id: 'el_1', name: 'Box', type: 'rectangle', page_id: 'page_1',
  x: 100, y: 100, width: 200, height: 200,
  rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
  corner_radius: 0, text_content: '', text_style: '', image_url: '',
  z_index: 0, position: 0, file_path: '', created_at: '', updated_at: '',
  parent_id: '',
} as any

const ITEM = {
  id: 'item_1', name: 'Test', item_type: 'design', path: '',
  workspace_id: 'ws_1',
} as any

describe('DesignView single-element drag → translate emit', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('sends translate emit with (id, dx, dy) when user drags the body', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [ELEMENT] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    try {
      await flushPromises()
      const elementEl = wrapper.find('[data-design-element]').element as HTMLElement
      elementEl.setPointerCapture = () => {}
      elementEl.releasePointerCapture = () => {}
      elementEl.hasPointerCapture = (): boolean => true

      // 1. pointerdown (selects + starts drag)
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()

      // 2. simulate the pointermove + pointerup that DesignElement's
      // `startDrag` registers on the element's addEventListener.
      let moveHandler: ((e: PointerEvent) => void) | null = null
      let upHandler: ((e: PointerEvent) => void) | null = null
      ;(elementEl as any).addEventListener = (type: string, cb: any) => {
        if (type === 'pointermove') moveHandler = cb
        if (type === 'pointerup') upHandler = cb
      }
      ;(elementEl as any).removeEventListener = () => {}

      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()

      expect(moveHandler).toBeTypeOf('function')
      expect(upHandler).toBeTypeOf('function')

      // Drag right by 50, down by 30.
      moveHandler!(new PointerEvent('pointermove', {
        clientX: 150, clientY: 130, pointerId: 1,
      }))
      upHandler!(new PointerEvent('pointerup', { pointerId: 1 }))
      await flushPromises()

      // 3. expect the `translateElement` emit to have fired with
      //    (el_1, 50, 30) — the delta in design-px (zoom=1.0).
      const translates = wrapper.emitted('translateElement') ?? []
      const last = translates[translates.length - 1]
      expect(last).toBeDefined()
      expect(last).toEqual(['el_1', 50, 30])
    } finally {
      wrapper.unmount()
    }
  })
})

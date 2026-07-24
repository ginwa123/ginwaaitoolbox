import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { useDesignHandlers } from '../useDesignHandlers'

const updateDesignElementGeometrySpy = vi.fn().mockResolvedValue({ id: 'el_1' })
const updateDesignElementSpy = vi.fn().mockResolvedValue({ id: 'el_1' })
const deleteDesignElementSpy = vi.fn().mockResolvedValue({ success: true })

vi.mock('../../stores/workspaces', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../stores/workspaces')>()
  return {
    ...actual,
    useWorkspacesStore: () => ({
      activeDesignPageId: 'page_test',
      updateDesignElementGeometry: updateDesignElementGeometrySpy,
      updateDesignElement: updateDesignElementSpy,
      deleteDesignElement: deleteDesignElementSpy,
    }),
  }
})

describe('useDesignHandlers', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    vi.stubGlobal('confirm', vi.fn(() => true))
  })

  it('routes a geometry-only patch to updateDesignElementGeometry', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 100, y: 200 })
    expect(updateDesignElementGeometrySpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_1', { x: 100, y: 200 })
    expect(updateDesignElementSpy).not.toHaveBeenCalled()
  })

  it('routes a non-geometry patch to updateDesignElement', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { fill: '#ff0000' })
    expect(updateDesignElementSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_1', { fill: '#ff0000' })
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
  })

  it('routes a mixed patch to updateDesignElement (full PUT, not geometry-only)', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 50, fill: 'red' })
    expect(updateDesignElementSpy).toHaveBeenCalled()
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
  })

  it('deleteElement routes to deleteDesignElement', async () => {
    const { deleteElement } = useDesignHandlers()
    await deleteElement('ws_1', 'item_1', 'el_1')
    expect(deleteDesignElementSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_1')
  })
})

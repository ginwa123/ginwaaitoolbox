/**
 * Unit tests for the drag-and-drop handlers on the workspace row
 * in WorkspaceList.vue. The handlers convert the HTML5 drag
 * events (dragstart, dragover, drop, dragend) into a
 * `reorder-workspaces` emit with the new top-to-bottom ID order.
 *
 * Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import { type Workspace } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeWorkspace(id: string, name: string): Workspace {
  return { id, name, icon: '📁', expanded: false, items: [] }
}

describe('WorkspaceList drag-and-drop', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
    })
  })

  afterEach(() => {
    // Cleanup: the workspaces-section header needs to be expanded
    // to render the inner row. Each test clicks the header before
    // assertions; nothing to do here.
  })

  /** Find the draggable workspace-header div (the one with @dragstart). */
  function findDraggableRows(wrapper: ReturnType<typeof mount>) {
    return wrapper.findAll('[draggable="true"]')
  }

  /**
   * Build a fake DragEvent with a writable dataTransfer. JSDOM does
   * not provide the browser's `DataTransfer` class, so we use a
   * minimal in-memory stub that implements just the surface our
   * component touches (`setData` / `getData`). This is enough to
   * exercise the drag handlers without a real browser.
   *
   * The stub is shared across all events in a single test (returned
   * by `makeDragStore()`), so the data set on `dragstart` is visible
   * on the subsequent `drop` — matching real browser behavior where
   * the dataTransfer is the same object across the drag lifecycle.
   */
  function makeDragStore() {
    const store = new Map<string, string>()
    return {
      effectAllowed: 'none' as 'none' | 'copy' | 'move' | 'link' | 'copyMove' | 'copyLink' | 'linkMove' | 'all',
      dropEffect: 'none' as 'none' | 'copy' | 'move' | 'link',
      setData(type: string, value: string) {
        store.set(type, value)
      },
      getData(type: string): string {
        return store.get(type) ?? ''
      },
    }
  }

  function makeDragEvent(type: string, dt: ReturnType<typeof makeDragStore>): DragEvent {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const event = new Event(type, { bubbles: true, cancelable: true }) as any
    event.dataTransfer = dt
    return event as DragEvent
  }

  it('emits reorderWorkspaces with the new order when ws_b is dropped on ws_a', async () => {
    const workspaces = [
      makeWorkspace('ws_c', 'C'),
      makeWorkspace('ws_b', 'B'),
      makeWorkspace('ws_a', 'A'),
    ]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      global: { stubs: { WorkspaceItem: true } },
    })
    // Expand the workspaces section so the inner rows render.
    await wrapper.find('button').trigger('click')
    await nextTick()

    const rows = findDraggableRows(wrapper)
    expect(rows.length).toBe(3)

    // Simulate dragging the third row (ws_a) onto the first row (ws_c).
    // After drop, ws_a should be at the top: [ws_a, ws_c, ws_b].
    const sourceRow = rows[2]!
    const targetRow = rows[0]!

    // Shared dataTransfer across the dragstart → drop pair.
    const dt = makeDragStore()

    // dragstart on source: sets dataTransfer to 'ws_a'
    const startEvent = makeDragEvent('dragstart', dt)
    sourceRow.element.dispatchEvent(startEvent)
    expect(dt.getData('application/x-workspace-id')).toBe('ws_a')

    // drop on target: fires the emit
    const dropEvent = makeDragEvent('drop', dt)
    targetRow.element.dispatchEvent(dropEvent)

    const emitted = wrapper.emitted('reorderWorkspaces')
    expect(emitted).toBeDefined()
    expect(emitted).toHaveLength(1)
    // Our emit passes the array as a SINGLE argument, so the
    // emitted-payload shape is `[[arg1]]` — `emitted[0]` is the
    // args of the first emit, and `emitted[0][0]` is the first
    // (and only) arg, which is the new ordered IDs array.
    expect(emitted![0]![0]).toEqual(['ws_a', 'ws_c', 'ws_b'])
  })

  it('does not emit when a workspace is dropped on itself', async () => {
    const workspaces = [makeWorkspace('ws_a', 'A'), makeWorkspace('ws_b', 'B')]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      global: { stubs: { WorkspaceItem: true } },
    })
    await wrapper.find('button').trigger('click')
    await nextTick()

    const rows = findDraggableRows(wrapper)
    const dt = makeDragStore()
    const startEvent = makeDragEvent('dragstart', dt)
    rows[0]!.element.dispatchEvent(startEvent)
    const dropEvent = makeDragEvent('drop', dt)
    rows[0]!.element.dispatchEvent(dropEvent)

    expect(wrapper.emitted('reorderWorkspaces')).toBeUndefined()
  })

  it('clears the dragging state on dragend (no opacity-50 after dragend)', async () => {
    // After a successful drag, the source row gets `opacity-50` via
    // the `draggingId === workspace.id` class binding. The dragend
    // handler must clear `draggingId` so the class drops off
    // (otherwise the row stays dimmed forever after every drag).
    // We assert this via the rendered class on the row.
    const workspaces = [makeWorkspace('ws_a', 'A'), makeWorkspace('ws_b', 'B')]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      global: { stubs: { WorkspaceItem: true } },
    })
    await wrapper.find('button').trigger('click')
    await nextTick()

    const rows = findDraggableRows(wrapper)
    const dt = makeDragStore()

    // Pre-drag: source row has no opacity-50 class.
    const sourceBefore = rows[0]!.element as HTMLElement
    expect(sourceBefore.className.includes('opacity-50')).toBe(false)

    // During drag: source row is dimmed.
    const startEvent = makeDragEvent('dragstart', dt)
    sourceBefore.dispatchEvent(startEvent)
    await nextTick()
    const sourceDuring = findDraggableRows(wrapper)[0]!.element as HTMLElement
    expect(sourceDuring.className.includes('opacity-50')).toBe(true)

    // After dragend: opacity-50 is removed.
    const endEvent = new Event('dragend', { bubbles: true })
    findDraggableRows(wrapper)[0]!.element.dispatchEvent(endEvent)
    await nextTick()
    const sourceAfter = findDraggableRows(wrapper)[0]!.element as HTMLElement
    expect(sourceAfter.className.includes('opacity-50')).toBe(false)
  })
})

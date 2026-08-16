/**
 * Unit tests for the drag-and-drop handlers on workspace ITEMS in
 * WorkspaceList.vue. The handlers convert the HTML5 drag events
 * (dragstart, dragover, drop, dragend) on a per-workspace `<ul>`
 * (event delegation) into a `reorder-workspace-items` emit with
 * the new top-to-bottom ID order, scoped to the workspace the
 * drop target belongs to.
 *
 * Mirrors workspaceListDragDrop.spec.ts (the workspace-level test)
 * but scoped to a single workspace's items.
 *
 * Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
 */
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { defineComponent, h, nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import {
  useWorkspacesStore,
  type Workspace,
  type WorkspaceItem,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

/**
 * Minimal stub for WorkspaceItemComponent that renders just the
 * `<li>` with the data-* attributes the parent uses for event
 * delegation. The real component has a lot of children (button,
 * spinner, task list, etc.) that we don't need for the
 * drag-and-drop test — the events bubble up to the parent `<ul>`
 * and the handler uses `closest('[data-item-id]')` to find the
 * source. Keeping the stub minimal avoids the real component's
 * deep dep tree (WorkspaceItemTask, etc.) which would slow the
 * test down and require its own setup.
 */
const WorkspaceItemStub = defineComponent({
  name: 'WorkspaceItem',
  props: {
    item: { type: Object, required: true },
    isActive: { type: Boolean, default: false },
    workspaceId: { type: String, required: true },
    isItemDragging: { type: Boolean, default: false },
    isItemDragOver: { type: Boolean, default: false },
  },
  emits: ['click', 'delete', 'addTask', 'selectTask'],
  setup(props, { emit }) {
    return () =>
      h(
        'li',
        {
          draggable: 'true',
          'data-item-id': props.item.id,
          'data-workspace-id': props.workspaceId,
          class: { 'opacity-50': props.isItemDragging },
          style: {
            boxShadow:
              props.isItemDragOver && !props.isItemDragging
                ? '0 -2px 0 0 var(--color-violet)'
                : 'none',
          },
          onClick: () => emit('click', props.item),
        },
        props.item.name,
      )
  },
})

function makeItem(id: string, name: string): WorkspaceItem {
  return { id, name, item_type: 'folder' }
}

function makeWorkspace(
  id: string,
  name: string,
  items: WorkspaceItem[] = [],
): Workspace {
  return { id, name, icon: '📁', expanded: true, items }
}

describe('WorkspaceList item drag-and-drop', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
    })
  })

  /**
   * Build a fake DragEvent with a writable dataTransfer. JSDOM does
   * not provide the browser's `DataTransfer` class, so we use a
   * minimal in-memory stub that implements just the surface our
   * component touches (`setData` / `getData`).
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

  /** Find the draggable item <li>s (the data-item-id elements). */
  function findDraggableItems(wrapper: ReturnType<typeof mount>) {
    return wrapper.findAll('[data-item-id]')
  }

  it('emits reorderWorkspaceItems with the new order when item2 is dropped on item0', async () => {
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', '1'),
        makeItem('item2', '2'),
        makeItem('item3', '3'),
      ]),
    ]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    // The workspace is already expanded (makeWorkspace sets
    // expanded: true), so the inner <ul> renders without needing
    // to click the section header.
    await nextTick()

    const items = findDraggableItems(wrapper)
    expect(items.length).toBe(3)

    // Drag the second item (item2) onto the first item (item1).
    // After drop, item2 should be at the top: [item2, item1, item3].
    const sourceItem = items[1]!
    const targetItem = items[0]!

    const dt = makeDragStore()

    // dragstart on source: sets dataTransfer to 'item2'
    const startEvent = makeDragEvent('dragstart', dt)
    sourceItem.element.dispatchEvent(startEvent)
    expect(dt.getData('application/x-item-id')).toBe('item2')

    // dragover on target: enables the drop
    const overEvent = makeDragEvent('dragover', dt)
    targetItem.element.dispatchEvent(overEvent)

    // drop on target: fires the emit
    const dropEvent = makeDragEvent('drop', dt)
    targetItem.element.dispatchEvent(dropEvent)

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted).toHaveLength(1)
    // Emit payload is `(workspaceId, orderedItemIds)` — 2 args.
    expect(emitted![0]![0]).toBe('ws_a')
    expect(emitted![0]![1]).toEqual(['item2', 'item1', 'item3'])

    wrapper.unmount()
  })

  it('does not emit when an item is dropped on the same slot', async () => {
    // The item handler short-circuits on self-drop — mirrors
    // the workspace-level handler (which has the same check).
    // This is a deliberate design choice: the same-order
    // no-op is a UX-level concern (the user explicitly dropped
    // on the same row, so the UI shouldn't flicker) and it's
    // cheaper to skip the event entirely than to round-trip
    // through the store's same-order check. The store's
    // same-order check still exists as defense-in-depth (see
    // workspacesStoreItemReorder.spec.ts).
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
    ]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    const dt = makeDragStore()

    // Drag item1 onto item1 (same slot).
    items[0]!.element.dispatchEvent(makeDragEvent('dragstart', dt))
    items[0]!.element.dispatchEvent(makeDragEvent('drop', dt))

    expect(wrapper.emitted('reorderWorkspaceItems')).toBeUndefined()

    wrapper.unmount()
  })

  it('is a no-op (no emit) when an item is dropped on an item from a different workspace', async () => {
    // Cross-workspace drop is out of scope for this plan; the
    // handler must silently no-op (no event emitted) so the
    // source workspace's order stays intact and no API call
    // is made for a drop the backend would reject.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
      makeWorkspace('ws_b', 'B', [makeItem('item3', '3'), makeItem('item4', '4')]),
    ]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    expect(items.length).toBe(4)

    // Drag item1 (workspace A) onto item3 (workspace B).
    const dt = makeDragStore()
    items[0]!.element.dispatchEvent(makeDragEvent('dragstart', dt))
    items[2]!.element.dispatchEvent(makeDragEvent('drop', dt))

    expect(wrapper.emitted('reorderWorkspaceItems')).toBeUndefined()

    wrapper.unmount()
  })

  it('clears the dragging state on dragend (no opacity-50 after dragend)', async () => {
    // The dragend handler must clear `draggingItemId` so the
    // dimmed source <li> goes back to normal. Without this, the
    // row would stay dimmed forever after every drag.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
    ]
    const wrapper = mount(WorkspaceList, {
      props: { workspaces, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    const source = items[0]!.element as HTMLElement
    const dt = makeDragStore()

    // Pre-drag: no opacity-50.
    expect(source.className.includes('opacity-50')).toBe(false)

    // During drag: source is dimmed.
    source.dispatchEvent(makeDragEvent('dragstart', dt))
    await nextTick()
    const sourceDuring = findDraggableItems(wrapper)[0]!.element as HTMLElement
    expect(sourceDuring.className.includes('opacity-50')).toBe(true)

    // After dragend: opacity-50 is removed.
    const endEvent = new Event('dragend', { bubbles: true })
    findDraggableItems(wrapper)[0]!.element.dispatchEvent(endEvent)
    await nextTick()
    const sourceAfter = findDraggableItems(wrapper)[0]!.element as HTMLElement
    expect(sourceAfter.className.includes('opacity-50')).toBe(false)

    wrapper.unmount()
  })
})

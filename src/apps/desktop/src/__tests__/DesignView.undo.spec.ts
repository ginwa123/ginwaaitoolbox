/**
 * Behavioural tests for design-mode undo/redo keyboard shortcuts
 * (Cmd+Z / Cmd+Shift+Z / Cmd+Y) bound in DesignView.vue.
 *
 * Mocks the `useDesignHistory` composable so we can assert the
 * keyboard handler dispatches the right call without needing the
 * full DesignView mount + element tree.
 *
 * Tests cover:
 *   - Empty stack: Cmd+Z is a no-op
 *   - Input-focus guard: Cmd+Z inside an <input> does not fire
 *   - After entry pushed: Cmd+Z dispatches undo
 *
 * 3 behavioural tests. Project convention is behavioural only — see
 * ~/.config/nalar/memories/static-contract-test-when-to-prefer-behavioural.md.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { ref } from 'vue'
import DesignView from '../components/design/DesignView.vue'

// Hoisted mock — the composable's undo/redo will be these spies.
const undoMock = vi.fn().mockResolvedValue(undefined)
const redoMock = vi.fn().mockResolvedValue(undefined)
const capturePreStateMock = vi.fn()
const capturePostStateMock = vi.fn().mockResolvedValue(undefined)
const captureDeleteMock = vi.fn().mockResolvedValue(undefined)
const captureReorderMock = vi.fn().mockResolvedValue(undefined)
const captureGroupMock = vi.fn().mockResolvedValue(undefined)
const canUndoRef = ref(false)
const canRedoRef = ref(false)
const nextUndoLabelRef = ref<string | null>(null)
const nextRedoLabelRef = ref<string | null>(null)

vi.mock('../composables/useDesignHistory', () => ({
  useDesignHistory: () => ({
    canUndo: canUndoRef,
    canRedo: canRedoRef,
    nextUndoLabel: nextUndoLabelRef,
    nextRedoLabel: nextRedoLabelRef,
    undo: undoMock,
    redo: redoMock,
    capturePreState: capturePreStateMock,
    capturePostState: capturePostStateMock,
    captureDelete: captureDeleteMock,
    captureReorder: captureReorderMock,
    captureGroup: captureGroupMock,
    captureCreate: vi.fn().mockResolvedValue(undefined),
  }),
}))

// Stub the api layer so DesignView mounts cleanly.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: vi.fn().mockResolvedValue({
      pages: [
        {
          id: 'page_1',
          workspace_item_id: 'item_1',
          name: 'Test Page',
          width: 1440,
          height: 1024,
          position: 0,
          created_at: '2026-07-29 12:00:00',
          updated_at: '2026-07-29 12:00:00',
        },
      ],
      count: 1,
    }),
    reorderDesignElements: vi.fn().mockResolvedValue({ reordered: [] }),
    deleteDesignElement: vi.fn().mockResolvedValue(undefined),
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

describe('DesignView undo/redo keyboard shortcuts', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    canUndoRef.value = false
    canRedoRef.value = false
    nextUndoLabelRef.value = null
    nextRedoLabelRef.value = null
    undoMock.mockClear()
    redoMock.mockClear()
    capturePreStateMock.mockClear()
    capturePostStateMock.mockClear()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('Cmd+Z with empty stack is a no-op', async () => {
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(undoMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('Cmd+Z inside an <input> does NOT trigger undo (input-focus guard)', async () => {
    canUndoRef.value = true
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
      attachTo: document.body,
    })
    await flushPromises()
    // Create a real <input> in the DOM and dispatch a keydown on it.
    const input = document.createElement('input')
    document.body.appendChild(input)
    input.focus()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(undoMock).not.toHaveBeenCalled()
    document.body.removeChild(input)
    wrapper.unmount()
  })

  it('Cmd+Z after entry pushed dispatches undo once', async () => {
    canUndoRef.value = true
    nextUndoLabelRef.value = 'Move element'
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(undoMock).toHaveBeenCalledOnce()
    wrapper.unmount()
  })

  it('Cmd+Shift+Z dispatches redo once', async () => {
    canRedoRef.value = true
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'z',
        metaKey: true,
        shiftKey: true,
        bubbles: true,
      }),
    )
    await flushPromises()
    expect(redoMock).toHaveBeenCalledOnce()
    wrapper.unmount()
  })

  it('Cmd+Y dispatches redo once (Windows convention)', async () => {
    canRedoRef.value = true
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'y', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(redoMock).toHaveBeenCalledOnce()
    wrapper.unmount()
  })
})

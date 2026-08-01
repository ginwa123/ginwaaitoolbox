/**
 * Tests for KanbanView's chat-pane branch (kanban-embed-chatview plan,
 * Task 2 + Task 3 + Task 4).
 *
 * The chat pane used to be a sibling of KanbanView in AppLayout
 * (the 3-column block at AppLayout.vue:1739-1825). It now lives
 * INSIDE KanbanView: when activeTask is set AND it belongs to this
 * kanban, the board renders side-by-side with the ChatView (plus the
 * resize handle added in Task 3). The handle's drag + localStorage
 * persistence + 40% default fall-back are covered here too.
 *
 * Tests are BEHAVIOURAL: mount the component, drive the state
 * (setActiveWorkspaceItem + setActiveTask on the workspaces store),
 * assert the DOM (find() + exists()) and side effects
 * (localStorage reads).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { flushPromises, mount } from '@vue/test-utils'
import { ref } from 'vue'

import KanbanView from '../components/kanban/KanbanView.vue'
import {
  useWorkspacesStore,
  type Workspace,
  type WorkspaceItem,
  type Task,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ITEM_ID = 'item_kanban_1'
const OTHER_ITEM_ID = 'item_kanban_2'
const TASK_ID = 'task_1'
const WS_ID = 'ws_1'

function makeItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem {
  return {
    id: ITEM_ID,
    name: 'Sprint A',
    item_type: 'kanban',
    kanban_columns: [],
    tasks: [],
    path: '/tmp/proj',
    ...overrides,
  } as WorkspaceItem
}

function makeTask(id = TASK_ID, name = 'Hello'): Task {
  return { id, name, task_type: 'standard' } as Task
}

function makeWorkspace(items: WorkspaceItem[]): Workspace {
  return {
    id: WS_ID,
    name: 'WS',
    icon: '📁',
    expanded: true,
    items,
  }
}

function mountKanban(item: WorkspaceItem) {
  return mount(KanbanView, {
    props: { item, workspaceId: WS_ID },
    global: {
      provide: { processingState: ref({}) },
      // Stub ChatView so the test doesn't pull in the full 3140-line
      // component (and its SSE/heavy deps). The stub forwards the
      // most-tested attrs (chatId / chatName) as data-* attributes so
      // tests can assert them, and exposes the @close event so tests
      // can trigger it.
      stubs: {
        ChatView: {
          template:
            '<div data-test-stub-chatview :data-chat-id="chatId" :data-chat-name="chatName" @close="$emit(\'close\')" />',
          emits: ['close'],
          props: {
            chatId: { type: String, default: '' },
            chatName: { type: String, default: '' },
          },
        },
      },
    },
  })
}

describe('KanbanView — chat pane branch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    localStorage.removeItem('kanban-column-width')
  })

  afterEach(() => {
    // Defensive: startKanbanResize mutates body styles; reset in case a
    // test failed before mouseup.
    document.body.style.userSelect = ''
    document.body.style.cursor = ''
    vi.restoreAllMocks()
  })

  it('renders full-width board when no active task', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspace([makeItem()])]
    store.setActiveWorkspaceItem(ITEM_ID)

    const wrapper = mountKanban(makeItem())
    await flushPromises()

    expect(wrapper.find('[data-kanban-host]').exists()).toBe(true)
    expect(wrapper.find('[data-kanban-with-chat]').exists()).toBe(false)
  })

  it('renders chat pane when active task belongs to this kanban', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([
        makeItem({ tasks: [makeTask()] }),
        makeItem({ id: OTHER_ITEM_ID, name: 'Sprint B' }),
      ]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem({ tasks: [makeTask()] }))
    await flushPromises()

    expect(wrapper.find('[data-kanban-host]').exists()).toBe(true)
    expect(wrapper.find('[data-kanban-with-chat]').exists()).toBe(true)
  })

  it('does NOT render chat pane when active task belongs to a different kanban', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([
        makeItem({ tasks: [] }),
        makeItem({ id: OTHER_ITEM_ID, name: 'Sprint B', tasks: [makeTask()] }),
      ]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    // activeTask belongs to OTHER_ITEM_ID
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem())
    await flushPromises()

    expect(wrapper.find('[data-kanban-with-chat]').exists()).toBe(false)
  })

  it('emits close-chat when ChatView close event fires', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([makeItem({ tasks: [makeTask()] })]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem({ tasks: [makeTask()] }))
    await flushPromises()

    // Find the stub ChatView in the chat-pane branch and dispatch a close.
    const stub = wrapper.find('[data-test-stub-chatview]')
    expect(stub.exists()).toBe(true)
    await stub.trigger('close')
    await flushPromises()

    // Vue 3 normalises kebab-case <-> camelCase for template listeners
    // (@close-chat => 'closeChat' on the wire). Assert the camelCase
    // form here since wrapper.emitted() returns the raw key.
    const emits = wrapper.emitted('closeChat')
    expect(emits).toBeTruthy()
    expect(emits?.length).toBe(1)
  })

  it('renders the chat pane with the active task chat-id', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([makeItem({ tasks: [makeTask()] })]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem({ tasks: [makeTask()] }))
    await flushPromises()

    const stub = wrapper.find('[data-test-stub-chatview]')
    expect(stub.exists()).toBe(true)
    expect(stub.attributes('data-chat-id')).toBe(TASK_ID)
  })

  it('drag the resize handle updates the kanban column width', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([makeItem({ tasks: [makeTask()] })]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem({ tasks: [makeTask()] }))
    await flushPromises()

    const handle = wrapper.find('[data-kanban-resize-handle]')
    expect(handle.exists()).toBe(true)

    // Simulate drag: mousedown on handle, mousemove +50 on document,
    // mouseup on document. The default start width is the rendered
    // width of the kanban column (measured at mousedown time).
    await handle.trigger('mousedown', { clientX: 200, preventDefault: () => {} })
    document.dispatchEvent(new MouseEvent('mousemove', { clientX: 250 }))
    document.dispatchEvent(new MouseEvent('mouseup', { clientX: 250 }))
    await flushPromises()

    const boardColumn = wrapper.find('[data-kanban-with-chat] > :first-child')
    const style = (boardColumn.element as HTMLElement).style.width
    expect(style).toMatch(/^\d+px$/i)
    const w = parseInt(style, 10)
    expect(w).toBeGreaterThanOrEqual(0)
    expect(w).toBeLessThanOrEqual(720)
  })

  it('mouseup persists the width to localStorage', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([makeItem({ tasks: [makeTask()] })]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem({ tasks: [makeTask()] }))
    await flushPromises()

    const handle = wrapper.find('[data-kanban-resize-handle]')
    await handle.trigger('mousedown', { clientX: 200, preventDefault: () => {} })
    document.dispatchEvent(new MouseEvent('mousemove', { clientX: 250 }))
    document.dispatchEvent(new MouseEvent('mouseup', { clientX: 250 }))
    await flushPromises()

    const saved = localStorage.getItem('kanban-column-width')
    expect(saved).not.toBeNull()
    expect(parseInt(saved as string, 10)).toBeGreaterThan(0)
  })

  it('falls back to 40% flex default when no localStorage value', async () => {
    // localStorage cleared in beforeEach — no saved width.
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([makeItem({ tasks: [makeTask()] })]),
    ]
    store.setActiveWorkspaceItem(ITEM_ID)
    store.setActiveTask(TASK_ID)

    const wrapper = mountKanban(makeItem({ tasks: [makeTask()] }))
    await flushPromises()

    const boardColumn = wrapper.find('[data-kanban-with-chat] > :first-child')
    const style = (boardColumn.element as HTMLElement).style
    // 40% fallback uses flex-basis (kanbanColumnStyle returns
    // { flex: '0 1 40%', ... } when kanbanColumnWidth.value === null).
    // jsdom normalizes the cssText; the flex shorthand may be split
    // into flexBasis / flexGrow / flexShrink — check at least one
    // contains 40%.
    const flexBasis = style.flexBasis || style.getPropertyValue('flex-basis')
    expect(flexBasis).toMatch(/40/)
  })
})
// AppLayout — design chat dialog mount wiring.
//
// When the user clicks the top-right 💬 button in DesignView, the
// `open-chat` event fires with `{ pageId, pageName, workspaceItemTaskId }`.
// AppLayout's existing `handleDesignOpenChat` calls
// `workspacesStore.setActiveTask(payload.workspaceItemTaskId)`. The new
// `<DesignChatDialog>` mount reads `activeTask` + `activeWorkspaceItem`
// (and gates on `item_type === 'design'`) and renders centred on top of
// the design canvas.
//
// This spec verifies the mount gates correctly:
//   - No active task → dialog not rendered
//   - Active task on a design item → dialog rendered
//   - Active task on a non-design item (e.g. kanban) → dialog NOT
//     rendered (kanban has its own KanbanChatDialog mount)
//
// The test follows the established vue-teleport-vitest-document-queryselector
// pattern (attachTo: document.body + document.querySelector).

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

// Stub vue-router (AppLayout uses useRoute()/useRouter() for URL sync).
const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    back: vi.fn(),
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

import * as api from '../api'

const WS_ID = 'ws_1'
const KANBAN_ITEM_ID = 'item_kanban_1'
const DESIGN_ITEM_ID = 'item_design_1'
const TASK_ID = 'task_1'

function makeStubClient(): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    onStateChange: () => () => {},
  }
  return stub as SseClient
}

function installBusForTests() {
  __resetSseBus()
  installSseBus()
  __setSseBusGlobalClient(makeStubClient())
}

function makeKanbanItem(overrides: Partial<WorkspaceItem> = {}): WorkspaceItem {
  return {
    id: KANBAN_ITEM_ID,
    name: 'Sprint A',
    item_type: 'kanban',
    kanban_columns: [],
    tasks: [],
    ...overrides,
  } as WorkspaceItem
}

function makeDesignItem(tasks: Task[] = []): WorkspaceItem {
  return {
    id: DESIGN_ITEM_ID,
    name: 'Design',
    item_type: 'design',
    tasks,
  } as WorkspaceItem
}

function mountAppLayout(): VueWrapper {
  return mount(AppLayout, {
    attachTo: document.body,
    global: {
      provide: { processingState: ref({}) },
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        SettingsView: true,
        CodeEditor: true,
        KanbanView: true,
        DesignView: true,
        Chats: true,
        // NOTE: do NOT stub KanbanChatDialog / DesignChatDialog — we
        // want the real <Teleport to="body"> content to render so
        // document.querySelector can find the dialog testids.
      },
    },
  })
}

describe('AppLayout — design chat dialog mount', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    // jsdom 29 dropped localStorage — install stub before pinia loads.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    installBusForTests()
    // Stub the workspace-store API calls fired by AppLayout's onMounted
    // → initializeFromSystemFolder → init() → getWorkspaces(). Without
    // these, jsdom's fetch throws an ERR_INVALID_URL on every test
    // (no test server) — the error is caught by AppLayout's own
    // try/catch so the test still passes, but it floods the output.
    //
    // CRITICAL: each test sets `store.workspaces = [...]` to inject
    // fixtures. The store's init() then OVERWRITES workspaces.value
    // with the API response — so we must also mock getWorkspaces /
    // getWorkspacesItems / getTasks to return data that preserves the
    // fixtures the test cares about. Tests that set up specific
    // workspaces mutate these mocks AFTER the default beforeEach
    // stub, so the default returns minimal empty data.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    } as any)
    vi.useFakeTimers()
    setActivePinia(createPinia())
    document.body.innerHTML = ''
  })

  // Mock the API calls in init() so they preserve the per-test fixture.
  // Each test calls this AFTER setting store.workspaces = [...] and
  // BEFORE mount, so init() doesn't wipe the fixture.
  function rewireApiForFixture(store: ReturnType<typeof useWorkspacesStore>) {
    vi.spyOn(api, 'getWorkspaces').mockImplementation(async () => {
      return { workspaces: store.workspaces as any }
    })
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async (wsId: string) => {
      const ws = store.workspaces.find((w: any) => w.id === wsId)
      return { items: (ws?.items ?? []) as any, count: ws?.items?.length ?? 0 }
    })
    vi.spyOn(api, 'getTasks').mockImplementation(async (wsId: string, itemId: string) => {
      const ws = store.workspaces.find((w: any) => w.id === wsId)
      const item = ws?.items?.find((i: any) => i.id === itemId)
      return {
        tasks: (item?.tasks ?? []) as any,
        has_more: false,
        next_cursor: null,
      }
    })
  }

  // Post-init workspace fixture override. `init()` rebuilds
  // workspaces.value from scratch — for DESIGN items it strips the
  // `tasks` array (line 639 of workspaces.ts: `if (item_type === 'kanban'
  // || item_type === 'design') return` early-returns before the getTasks
  // call, then the new-item builder at line 778-780 sets
  // `tasks: tasksByItem.get(item.id) ?? []` for non-kanban items,
  // giving an empty array). This means our `activeTask` computed
  // (which walks workspaces.value[].items[].tasks) finds no task for
  // design items after init — even though production has the task
  // accessible via the FK in workspace_pages.workspace_item_task_id.
  //
  // For the test, the simplest workaround is to manually re-attach the
  // tasks array to the design item AFTER init() has finished (we await
  // flushPromises() before calling this). The KANBAN equivalent
  // (`AppLayout.kanbanChatDialog.spec.ts`) doesn't need this because
  // kanban items preserve tasks through init() via the special-case
  // branch at line 778-779. Documented in:
  // `.nalar/memories/workspace-store-init-wipes-fixtures.md` (the
  // pre-existing pattern that this file follows).
  function restoreDesignItemTasksAfterInit(
    store: ReturnType<typeof useWorkspacesStore>,
    itemsToRestore: Array<{ itemId: string; tasks: Task[] }>,
  ) {
    for (const { itemId, tasks } of itemsToRestore) {
      for (const ws of store.workspaces) {
        const item = ws.items.find((i: any) => i.id === itemId)
        if (item && item.item_type === 'design') {
          item.tasks = [...tasks]
        }
      }
    }
  }

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    wrapper?.unmount()
    wrapper = null
    document
      .querySelectorAll('[data-testid="design-chat-dialog"]')
      .forEach((el) => el.remove())
    document
      .querySelectorAll('[data-testid="design-chat-dialog-root"]')
      .forEach((el) => el.remove())
  })

  it('does NOT render DesignChatDialog when no task is active', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [makeDesignItem()] },
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    wrapper = mountAppLayout()
    await flushPromises()
    expect(
      document.querySelector('[data-testid="design-chat-dialog"]'),
    ).toBeNull()
  })

  it('renders DesignChatDialog when active task belongs to a design item', async () => {
    const store = useWorkspacesStore()
    const designTasks: Task[] = [
      { id: TASK_ID, name: 'Design Chat: Login' } as Task,
    ]
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          makeKanbanItem(),
          makeDesignItem(designTasks),
        ],
      },
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    restoreDesignItemTasksAfterInit(store, [
      { itemId: DESIGN_ITEM_ID, tasks: designTasks },
    ])
    await flushPromises()
    expect(
      document.querySelector('[data-testid="design-chat-dialog"]'),
    ).not.toBeNull()
  })

  it('does NOT render DesignChatDialog when active task belongs to a non-design item', async () => {
    const store = useWorkspacesStore()
    const kanbanTasks: Task[] = [{ id: TASK_ID, name: 'Kanban Task' } as Task]
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          // DESIGN item has NO matching task
          makeDesignItem(),
          // KANBAN item owns the active task
          makeKanbanItem({ tasks: kanbanTasks }),
        ],
      },
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    store.setActiveTask(TASK_ID) // TASK_ID lives under the kanban item
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    // (no restoreDesignItemTasksAfterInit here — design item is empty,
    // kanban item preserves its tasks through init() naturally)
    await flushPromises()
    expect(
      document.querySelector('[data-testid="design-chat-dialog"]'),
    ).toBeNull()
  })

  it('renders DesignChatDialog for the design item that owns the active task (the store resolves which item is active)', async () => {
    // Contract: `setActiveTask(taskId)` walks the workspace tree to
    // find which item owns the task and sets `activeWorkspaceItemId`
    // accordingly — overwriting any prior `setActiveWorkspaceItem`
    // value. This test verifies a multi-design-item scenario where
    // the user has TWO design items, the task lives under one of
    // them, and the store resolves to the right one. (Earlier draft
    // tried to test "user navigates AWAY from a design item while
    // its chat is open" — that's not reachable in practice because
    // the per-page FK ties the chat to the page's item, not to the
    // "currently-navigated-to" item. `handleCloseTaskView` clears
    // activeTask before the user can navigate, so the race doesn't
    // occur.) What we DO need to verify: with two design items +
    // one task, the dialog opens for the task's owner.
    const OTHER_DESIGN_ID = 'item_design_2'
    const store = useWorkspacesStore()
    const designTasks: Task[] = [{ id: TASK_ID, name: 'Multi Design' } as Task]
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          // other design item — no task
          {
            id: OTHER_DESIGN_ID,
            name: 'Other Design',
            item_type: 'design',
            tasks: [],
          } as WorkspaceItem,
          // task lives under THIS design item
          makeDesignItem(designTasks),
        ],
      },
    ] as any
    store.setActiveTask(TASK_ID) // resolves activeWorkspaceItemId via tree walk
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    restoreDesignItemTasksAfterInit(store, [
      { itemId: DESIGN_ITEM_ID, tasks: designTasks },
    ])
    await flushPromises()
    // Task's owning item becomes active (setActiveTask tree-walk).
    const dbg = useWorkspacesStore()
    expect(dbg.activeWorkspaceItemId).toBe(DESIGN_ITEM_ID)
    // Dialog renders for the task's owning item.
    expect(
      document.querySelector('[data-testid="design-chat-dialog"]'),
    ).not.toBeNull()
  })

  it('renders dialog header with the active task name', async () => {
    const store = useWorkspacesStore()
    const designTasks: Task[] = [
      { id: TASK_ID, name: 'My Design Chat' } as Task,
    ]
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          makeKanbanItem(),
          makeDesignItem(designTasks),
        ],
      },
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    restoreDesignItemTasksAfterInit(store, [
      { itemId: DESIGN_ITEM_ID, tasks: designTasks },
    ])
    await flushPromises()
    const title = document.querySelector(
      '[data-testid="design-chat-dialog-title"]',
    )
    expect(title).not.toBeNull()
    expect(title?.textContent).toContain('My Design Chat')
  })

  it('closes the dialog when activeTask is cleared (handleCloseTaskView path)', async () => {
    // The dialog's open state is bound to activeTask via a watcher.
    // Clearing activeTask (which handleCloseTaskView does) must flip
    // the dialog open state to false.
    const store = useWorkspacesStore()
    const designTasks: Task[] = [{ id: TASK_ID, name: 'Will Close' } as Task]
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          makeKanbanItem(),
          makeDesignItem(designTasks),
        ],
      },
    ] as any
    store.setActiveWorkspaceItem(DESIGN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    restoreDesignItemTasksAfterInit(store, [
      { itemId: DESIGN_ITEM_ID, tasks: designTasks },
    ])
    await flushPromises()
    expect(
      document.querySelector('[data-testid="design-chat-dialog"]'),
    ).not.toBeNull()
    // Clear the active task (handleCloseTaskView does this).
    store.setActiveTask(null)
    await flushPromises()
    expect(
      document.querySelector('[data-testid="design-chat-dialog"]'),
    ).toBeNull()
  })
})
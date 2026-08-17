// AppLayout — kanban chat dialog mount wiring.
//
// When the user navigates to a kanban task (via URL
// `?view=workspace&...&itemId=Y/chat/task_<id>` or by clicking a task
// card), AppLayout's existing wiring sets
// `workspacesStore.activeTask` + `activeTaskWorkspaceItemId`. The new
// `<KanbanChatDialog>` mount reads those store refs and renders centered
// on top of the kanban board.
//
// SIMPLIFY-URL-BROWSER (2026-08-15): the legacy `?view=task&task=<id>`
// URL has been collapsed into the workspace URL with the chat task id
// encoded as `/chat/<taskId>` on `itemId`. This spec drives the
// `setActiveTask` path directly via the store, so the URL shape
// doesn't matter for these assertions — the dialog mount is gated on
// `activeWorkspaceItem.item_type === 'kanban' && activeTask`.
//
// This spec verifies the mount gates correctly:
//   - No active task → dialog not rendered
//   - Active task on a kanban item → dialog rendered
//   - Active task on a non-kanban item (e.g. design) → dialog NOT rendered
//     (design + routine have their own chat mounts)
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
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
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
      },
    },
  })
}

describe('AppLayout — kanban chat dialog mount', () => {
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
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '' } as any)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({
      messages: [],
      has_more: false,
       
      next_cursor: null,
      total: 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
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
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { workspaces: store.workspaces as any }
    })
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async (wsId: string) => {
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const ws = store.workspaces.find((w: any) => w.id === wsId)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      return { items: (ws?.items ?? []) as any, count: ws?.items?.length ?? 0 }
    })
    vi.spyOn(api, 'getTasks').mockImplementation(async (wsId: string, itemId: string) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const ws = store.workspaces.find((w: any) => w.id === wsId)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const item = ws?.items?.find((i: any) => i.id === itemId)
      return {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        tasks: (item?.tasks ?? []) as any,
        has_more: false,
        next_cursor: null,
      }
    })
  }

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    wrapper?.unmount()
    wrapper = null
    document
      .querySelectorAll('[data-testid="kanban-chat-dialog"]')
      .forEach((el) => el.remove())
     
    document
      .querySelectorAll('[data-testid="kanban-chat-dialog-root"]')
      .forEach((el) => el.remove())
  })

  it('does NOT render KanbanChatDialog when no task is active', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [makeKanbanItem()] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    wrapper = mountAppLayout()
    await flushPromises()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog"]'),
    ).toBeNull()
  })

  it('renders KanbanChatDialog when active task belongs to a kanban item', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
         
        id: WS_ID,
        name: 'WS',
        items: [
          {
            ...makeKanbanItem(),
            tasks: [{ id: TASK_ID, name: 'Hello Task' } as Task],
          },
          makeDesignItem(),
        ],
      },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog"]'),
    ).not.toBeNull()
  })

  it('does NOT render KanbanChatDialog when active task belongs to a non-kanban item', async () => {
    const store = useWorkspacesStore()
     
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          // KANBAN item has NO matching task
          makeKanbanItem(),
          // DESIGN item owns the active task
          makeDesignItem([{ id: TASK_ID, name: 'Design Task' } as Task]),
        ],
      },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    store.setActiveTask(TASK_ID) // TASK_ID lives under the design item
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    expect(
      document.querySelector('[data-testid="kanban-chat-dialog"]'),
    ).toBeNull()
  })

  it('renders dialog header with the active task name', async () => {
    const store = useWorkspacesStore()
     
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          {
            ...makeKanbanItem(),
            tasks: [{ id: TASK_ID, name: 'My Important Task' } as Task],
          },
          makeDesignItem(),
        ],
      },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(KANBAN_ITEM_ID)
    store.setActiveTask(TASK_ID)
    rewireApiForFixture(store)
    wrapper = mountAppLayout()
    await flushPromises()
    const title = document.querySelector(
      '[data-testid="kanban-chat-dialog-title"]',
    )
    expect(title).not.toBeNull()
    expect(title?.textContent).toContain('My Important Task')
  })
})
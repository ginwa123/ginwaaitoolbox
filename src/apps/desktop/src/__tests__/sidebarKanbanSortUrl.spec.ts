/**
 * Behavioural tests for Sidebar's handleSelectItem when the user
 * clicks a kanban workspace item (kanban default-URL, 2026-08-06).
 *
 * Why. The user wants the URL to commit to a default sort on the
 * first click of a kanban item — so a refresh preserves the implicit
 * "newest first" pick and the wire payload doesn't carry silent
 * defaults. Sidebar.handleSelectItem now builds a
 * `?sorts=col_X:updated_at:desc,...` string from the item's columns
 * and passes it through the navigate emit's new 7th positional arg.
 *
 * Match-up: the URL write side is tested in
 * AppLayout.urlPersist.spec.ts ("handleNavigate writes sorts into
 * the URL"). This file tests the Sidebar-side construction.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref, createApp } from 'vue'
import { setActivePinia, createPinia, type Pinia } from 'pinia'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import * as api from '../api'

// Local SseClient stub — mirrors the pattern in sidebarActiveState.spec.ts.
// The real SseClient type isn't exported from sseBus, so we type the
// stub as `any` to match the `__setSseBusGlobalClient` signature.
// Each method returns a no-op so the bus internals stay quiet.
function makeStubClient(initial: 'connecting'): any {
  const stub = {
    state: initial,
    lastError: null,
    getState: () => initial,
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
  return stub
}

// Stub the router so we don't pull in a real Router. handleSelectItem
// doesn't call the router directly — it emits `navigate` which
// AppLayout handles. Here we only need Sidebar's emit to be observed.
const { useRouterMock } = vi.hoisted(() => ({
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: vi.fn(() => ({ query: {}, path: '/', fullPath: '/' })),
  }
})

function mountSidebar() {
  return mount(Sidebar, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

const WS_ID = 'ws_sortby'
const KANBAN_ID = 'item_kanban_sortby'
const FOLDER_ID = 'item_folder_sortby'
const DESIGN_ID = 'item_design_sortby'

function makeKanbanItem(overrides: Record<string, unknown> = {}) {
  return {
    id: KANBAN_ID,
    name: 'Kanban',
    item_type: 'kanban',
    path: '/tmp',
    kanban_columns: [
      { id: 'col_a', name: 'todo', workspace_item_id: KANBAN_ID, position: 0, created_at: '2026-01-01' },
      { id: 'col_b', name: 'in_progress', workspace_item_id: KANBAN_ID, position: 1, created_at: '2026-01-01' },
    ],
    tasks: [],
    isLoaded: true,
    isLoading: false,
    ...overrides,
  }
}

function makeFolderItem(overrides: Record<string, unknown> = {}) {
  return {
    id: FOLDER_ID,
    name: 'Folder',
    item_type: 'folder',
    path: '/tmp',
    isLoaded: true,
    isLoading: false,
    ...overrides,
  }
}

function makeDesignItem(overrides: Record<string, unknown> = {}) {
  return {
    id: DESIGN_ID,
    name: 'Design',
    item_type: 'design',
    path: '/tmp',
    isLoaded: true,
    isLoading: false,
    ...overrides,
  }
}

describe('Sidebar.handleSelectItem — kanban default-URL emits sortsParam (2026-08-06)', () => {
  let pinia: Pinia

  beforeEach(() => {
    pinia = setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: {
        getItem: vi.fn(() => null),
        setItem: vi.fn(),
        removeItem: vi.fn(),
        clear: vi.fn(),
      },
      writable: true,
      configurable: true,
    })
    // ChatsList (a child of Sidebar) calls useSseBus() in setup. We
    // install a stub bus before mount so its session listener
    // registration succeeds.
    __resetSseBus()
    const busApp = createApp({})
    installSseBus(busApp)
    __setSseBusGlobalClient(makeStubClient('connecting'))
    // Silence getChats — Sidebar's mounted children may try to fetch.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    // Stub listKanbanColumns (used by the click handler when
    // columns aren't loaded). Returns columns matching the kanban
    // item fixture so the URL gets the expected sorts param.
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({
      columns: [
        { id: 'col_a', name: 'todo', workspace_item_id: KANBAN_ID, position: 0, created_at: '2026-01-01' },
        { id: 'col_b', name: 'in_progress', workspace_item_id: KANBAN_ID, position: 1, created_at: '2026-01-01' },
      ],
      count: 2,
    })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('clicking a kanban item emits navigate with ?sorts=col_X:updated_at:desc,...', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeKanbanItem()],
      },
    ] as any

    const wrapper = mountSidebar()
    const layout = wrapper.vm as any
    expect(typeof layout.handleSelectItem).toBe('function')

    await layout.handleSelectItem(WS_ID, KANBAN_ID)
    await nextTick()

    const navEmits = wrapper.emitted('navigate')
    expect(navEmits).toBeDefined()
    expect(navEmits!.length).toBeGreaterThan(0)

    // The last navigate emit is the kanban-click one. Arg shape:
    // (view, chatName, taskId, workspaceId, itemId, pageId, sortsParam)
    const last = navEmits![navEmits!.length - 1]!
    expect(last[0]).toBe('workspace')
    expect(last[3]).toBe(WS_ID)
    expect(last[4]).toBe(KANBAN_ID)
    expect(last[5]).toBeUndefined() // pageId (NOT a design page)
    expect(last[6]).toBe('col_a:updated_at:desc,col_b:updated_at:desc')

    wrapper.unmount()
  })

  it('clicking a folder item does NOT emit sortsParam', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeFolderItem()],
      },
    ] as any

    const wrapper = mountSidebar()
    const layout = wrapper.vm as any

    await layout.handleSelectItem(WS_ID, FOLDER_ID)
    await nextTick()

    const navEmits = wrapper.emitted('navigate')
    expect(navEmits).toBeDefined()
    const last = navEmits![navEmits!.length - 1]!
    expect(last[0]).toBe('workspace')
    expect(last[4]).toBe(FOLDER_ID)
    expect(last[6]).toBeUndefined() // no sortsParam for folders

    wrapper.unmount()
  })

  it('clicking a design item does NOT emit sortsParam', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem()],
      },
    ] as any

    const wrapper = mountSidebar()
    const layout = wrapper.vm as any

    await layout.handleSelectItem(WS_ID, DESIGN_ID)
    await nextTick()

    const navEmits = wrapper.emitted('navigate')
    expect(navEmits).toBeDefined()
    const last = navEmits![navEmits!.length - 1]!
    expect(last[4]).toBe(DESIGN_ID)
    expect(last[6]).toBeUndefined() // no sortsParam for designs

    wrapper.unmount()
  })

  it('when kanban columns are NOT pre-loaded, click fetches them and emits sortsParam', async () => {
    const ws = useWorkspacesStore()
    // Pre-load WITHOUT columns — the click handler must fetch them.
    const kanban = makeKanbanItem()
    kanban.kanban_columns = []
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [kanban],
      },
    ] as any

    const wrapper = mountSidebar()
    const layout = wrapper.vm as any

    await layout.handleSelectItem(WS_ID, KANBAN_ID)
    // The handler awaits fetchKanbanColumns — let the awaited
    // promise resolve.
    await nextTick()
    await nextTick()
    await nextTick()

    const navEmits = wrapper.emitted('navigate')
    expect(navEmits).toBeDefined()
    const last = navEmits![navEmits!.length - 1]!
    // Even though the columns started empty, the fetch landed and
    // the URL still gets the sorts param.
    expect(last[6]).toBe('col_a:updated_at:desc,col_b:updated_at:desc')

    wrapper.unmount()
  })
})
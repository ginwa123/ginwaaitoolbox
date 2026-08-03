/**
 * Tests for AppLayout's URL → activeWorkspaceItemId persistence on
 * page reload. Before this feature, the URL `?view=workspace` was
 * preserved on reload but the active kanban/folder/design item was
 * lost (the in-memory `activeWorkspaceItemId` reset to null on every
 * page refresh). This file pins:
 *
 *   1. Sidebar's handleSelectItem emits `navigate` with
 *      (workspaceId, itemId) so the parent can mirror them into URL
 *   2. AppLayout's handleNavigate('workspace', ..., wsId, itemId)
 *      pushes the workspaceId + itemId query params alongside view
 *   3. On mount, AppLayout reads (workspaceId, itemId) from URL and
 *      restores activeWorkspaceItemId once the workspaces list loads
 *   4. A stale URL (item no longer exists) does not crash — the
 *      kanban-empty state is shown and the pending restore clears.
 *
 * Plan: feature "url browser kanban" (workspace kanban URL persistence).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace, WorkspaceItem, KanbanColumn } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState = 'open'): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient('open'))
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const WS_ID = 'ws_test'
const KANBAN_ID = 'item_kanban_url'
const DESIGN_ID = 'item_design_url'
const OTHER_WS_ID = 'ws_other'
const PAGE_ID_1 = 'page_first'
const PAGE_ID_2 = 'page_second'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_test',
  workspace_item_id: KANBAN_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-07-16 12:00:00',
  ...overrides,
})

const makeKanbanItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: KANBAN_ID,
  name: 'Sprint Backlog',
  item_type: 'kanban',
  kanban_columns: [
    makeColumn({ id: 'col_todo', name: 'todo', position: 0 }),
    makeColumn({ id: 'col_inprogress', name: 'in progress', position: 1 }),
  ],
  tasks: [],
  ...overrides,
})

const makeDesignItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: DESIGN_ID,
  name: 'Design Mockup',
  item_type: 'design',
  path: '/tmp/design',
  tasks: [],
  ...overrides,
})

function mountAppLayout(workspaces: Workspace[] = [], routeQuery: Record<string, string> = {}) {
  useRouteMock.mockReturnValue({
    query: routeQuery,
    path: '/app',
    fullPath: '/app' + (Object.keys(routeQuery).length ? `?${new URLSearchParams(routeQuery).toString()}` : ''),
  } as any)
  const ws = useWorkspacesStore()
  ws.workspaces = workspaces
  return mount(AppLayout, {
    global: {
      stubs: {
        // Stub Sidebar so it doesn't try to render / fetch data
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        Chats: true,
        SettingsView: true,
        ChatView: true,
        CodeEditor: true,
        KanbanView: { template: '<div data-kanban-view="stub" :data-item-id="item.id" />', props: ['item', 'workspaceId', 'itemId'] },
        DesignView: { template: '<div data-design-view="stub" :data-item-id="item.id" />', props: ['item', 'workspaceId', 'itemId'] },
      },
    },
  })
}

describe('AppLayout — handleNavigate("workspace", wsId, itemId) pushes workspaceId + itemId into the URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('when called with (workspaceId, itemId), the router receives .replace with those params', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    expect(typeof layout.handleNavigate).toBe('function')
    layout.handleNavigate('workspace', undefined, undefined, WS_ID, KANBAN_ID)
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: WS_ID, itemId: KANBAN_ID },
    })
    wrapper.unmount()
  })

  it('when called WITHOUT (workspaceId, itemId), the URL still has just view=workspace (back-compat)', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    layout.handleNavigate('workspace')
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace' },
    })
    wrapper.unmount()
  })

  // NEW (design-page-nav fix, 2026-08-06): pageId is now a 6th
  // positional arg of handleNavigate so Sidebar.handleSelectDesignPage
  // can switch the URL off `?view=task` into
  // `?view=workspace&pageId=Z`. Pin the contract so a future
  // refactor can't silently drop the pageId from the URL.
  it('when called with (workspaceId, itemId, pageId), the URL includes pageId', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    layout.handleNavigate('workspace', undefined, undefined, WS_ID, DESIGN_ID, PAGE_ID_1)
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: PAGE_ID_1,
      },
    })
    wrapper.unmount()
  })

  // NEW (design-page-nav fix, 2026-08-06): empty pageId is omitted
  // from the URL so we don't pollute the address bar with
  // `?pageId=` when the caller didn't pin a page.
  it('when called with empty-string pageId, the URL omits pageId', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    layout.handleNavigate('workspace', undefined, undefined, WS_ID, KANBAN_ID, '')
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: WS_ID, itemId: KANBAN_ID },
    })
    wrapper.unmount()
  })
})

describe('AppLayout — page reload of ?view=workspace&workspaceId=X&itemId=Y restores the active item', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({ columns: [], count: 0 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('mounting with ?view=workspace&workspaceId=X&itemId=Y in the URL restores activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace],
      { view: 'workspace', workspaceId: WS_ID, itemId: KANBAN_ID },
    )
    // The watcher in AppLayout that picks the URL-stashed params
    // fires on the workspaces ref update. `mountAppLayout` already
    // populated `ws.workspaces` synchronously, so the watcher's
    // immediate run should restore activeWorkspaceItemId within a
    // tick.
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(KANBAN_ID)
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(true)
    wrapper.unmount()
  })

  it('stale URL (item no longer exists) is ignored — no crash, activeWorkspaceItemId stays null', async () => {
    const ws = useWorkspacesStore()
    const otherKanban = makeKanbanItem({ id: 'item_other_kanban' })
    const wrapper = mountAppLayout(
      [{ id: OTHER_WS_ID, name: 'WS', icon: '📁', expanded: true, items: [otherKanban] } as Workspace],
      // URL refers to an item that's NOT in the workspaces list:
      { view: 'workspace', workspaceId: WS_ID, itemId: KANBAN_ID },
    )
    await nextTick()
    await nextTick()
    // The pending restore watcher should detect the mismatch and clear
    // itself, leaving activeWorkspaceItemId null.
    expect(ws.activeWorkspaceItemId).toBeNull()
    // The kanban view should NOT render — there's no active item.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })

  it('mounting with no URL params does NOT auto-select any workspace item', async () => {
    const ws = useWorkspacesStore()
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace],
      {},
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBeNull()
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })
})

describe('AppLayout — design item URL persistence (Chunk 3 of design-url-persistence plan)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({ columns: [], count: 0 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('handleNavigate("workspace", wsId, designId) pushes workspaceId + designId into the URL', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    layout.handleNavigate('workspace', undefined, undefined, WS_ID, DESIGN_ID)
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
    })
    wrapper.unmount()
  })

  it('mounting with ?view=workspace&workspaceId=X&itemId=designId restores the design view', async () => {
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace],
      { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(DESIGN_ID)
    const view = wrapper.find('[data-design-view="stub"]')
    expect(view.exists()).toBe(true)
    wrapper.unmount()
  })

  it('activeWorkspaceItem → URL watcher fires when activeWorkspaceItemId changes externally', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace' },
      path: '/app',
      fullPath: '/app?view=workspace',
    } as any)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, { view: 'workspace' })
    await nextTick()
    await nextTick()
    // AppLayout.onMounted calls initializeFromSystemFolder() which
    // calls init() which overwrites `workspaces.value` with the
    // (empty) API mock result. Re-set workspaces so the URL
    // watcher's lookup of activeWorkspace succeeds.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Externally set activeWorkspaceItemId — the watcher should fire
    // and call router.replace with the new URL.
    ws.setActiveWorkspaceItem(DESIGN_ID)
    await nextTick()
    await nextTick()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
    })
    wrapper.unmount()
  })

  it('activeWorkspaceItem → URL watcher does NOT overwrite the URL when on view=task', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    // URL is on view=task — the watcher must NOT clobber it.
    const wrapper = mountAppLayout(ws.workspaces, { view: 'task', task: 'task_xyz' })
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    ws.setActiveWorkspaceItem(DESIGN_ID)
    await nextTick()
    await nextTick()
    expect(replaceMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  // FIX (chatview-bug, task_1785726648589): when the user navigates
  // from a design item to a kanban (or folder), the store's
  // `activeDesignPageId` is NOT reset by `setActiveWorkspaceItem` —
  // it stays whatever the design's active page was. The URL
  // watcher reads `[activeWorkspaceItemId, activeDesignPageId]` and
  // writes the URL based on both. Pre-fix, the watcher included
  // `pageId` in the URL purely because `activeDesignPageId` was
  // truthy, without checking whether the new active item is a
  // design. The URL ended up as
  // `?view=workspace&itemId=KANBAN_ID&pageId=DESIGN_PAGE_ID` —
  // stale, and a reload would try to restore the design page
  // against a kanban that doesn't have pages. The fix: only
  // include `pageId` in the URL when the active item is a design.
  it('activeWorkspaceItem → URL watcher does NOT leak stale pageId when switching from design to kanban', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID, pageId: PAGE_ID_1 },
      path: '/app',
      fullPath: '/app?view=workspace&workspaceId=ws_test&itemId=item_design_url&pageId=page_first',
    } as any)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    // Both design AND kanban items live in the same workspace.
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeKanbanItem()],
      } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: DESIGN_ID,
      pageId: PAGE_ID_1,
    })
    await nextTick()
    await nextTick()
    // AppLayout.onMounted calls initializeFromSystemFolder() which
    // calls init() which overwrites `workspaces.value` with the
    // (empty) API mock result. Re-set workspaces so the URL
    // watcher's lookup of activeWorkspace succeeds.
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeKanbanItem()],
      } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Simulate the user clicking the kanban in the sidebar —
    // activeWorkspaceItemId changes to the kanban. The store's
    // activeDesignPageId is STILL PAGE_ID_1 (stale, set from the
    // previous design mount) — that's the leak.
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    await nextTick()
    // The URL the watcher writes must NOT include pageId — the
    // active item is a kanban, and pageId is design-item-scoped.
    // We don't care which exact call the URL-sync watcher made;
    // any router.replace after the item switch that includes a
    // pageId would be the bug.
    const calls = replaceMock.mock.calls
    const lastCall = calls[calls.length - 1]
    expect(lastCall).toBeDefined()
    // lastCall[0] is the router.replace arg; non-null assertion
    // is safe because expect(lastCall).toBeDefined() above
    // narrowed `lastCall` (still possibly undefined per the
    // index lookup — TS doesn't carry the toBeDefined narrowing
    // across expressions).
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    expect(lastArg).toMatchObject({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: KANBAN_ID,
      },
    })
    expect(lastArg.query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  // FIX (chatview-bug, task_1785726648589, sibling case): same
  // scenario as the kanban test above, but the user navigates from
  // a design to a folder. Folders don't have design pages either,
  // so the URL must NOT carry the stale pageId.
  it('activeWorkspaceItem → URL watcher does NOT leak stale pageId when switching from design to folder', async () => {
    const FOLDER_ID = 'item_folder_url'
    const makeFolderItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
      id: FOLDER_ID,
      name: 'Folder',
      item_type: 'folder',
      path: '/tmp/folder',
      tasks: [],
      ...overrides,
    })
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID, pageId: PAGE_ID_1 },
      path: '/app',
      fullPath: '/app?view=workspace&workspaceId=ws_test&itemId=item_design_url&pageId=page_first',
    } as any)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeFolderItem()],
      } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: DESIGN_ID,
      pageId: PAGE_ID_1,
    })
    await nextTick()
    await nextTick()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeFolderItem()],
      } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Simulate the user clicking the folder in the sidebar.
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    await nextTick()
    const calls = replaceMock.mock.calls
    const lastCall = calls[calls.length - 1]
    expect(lastCall).toBeDefined()
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    expect(lastArg).toMatchObject({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: FOLDER_ID,
      },
    })
    expect(lastArg.query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('handleCloseTaskView preserves workspaceId + itemId when the active task belongs to a design', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    // Simulate the user opening a task chat on the design item, with
    // an active design page (the typical workflow — design canvas +
    // page tabs + chat panel).
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    ws.setActiveTask('task_design_chat')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.handleCloseTaskView()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: PAGE_ID_2,
      },
    })
    wrapper.unmount()
  })

  it('handleCloseTaskView omits pageId when no design page is active', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask('task_kanban_chat')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.handleCloseTaskView()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: WS_ID, itemId: KANBAN_ID },
    })
    const lastQuery = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]![0].query
    expect(lastQuery.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('closeGitViewer preserves workspaceId + itemId + pageId when on a design item', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeGitViewer()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: PAGE_ID_2,
      },
    })
    wrapper.unmount()
  })

  it('closeSkillViewer preserves workspaceId + itemId + pageId when on a design item', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeSkillViewer()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: PAGE_ID_2,
      },
    })
    wrapper.unmount()
  })

  it('closeCodeEditor preserves workspaceId + itemId + pageId when on a design item', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeCodeEditor()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: PAGE_ID_2,
      },
    })
    wrapper.unmount()
  })

  // ─── add-workspace-id-params plan (2026-08-06) ──────────────────
  //
  // When the user closes a git/skill/code-editor viewer while a
  // task is active (e.g. they opened a viewer from the chat
  // panel of a kanban task), the new URL must include workspaceId
  // + itemId + pageId so the kanban / design context survives the
  // navigation. Pre-fix these branches wrote `?view=task&task=X`
  // only, dropping the breadcrumb.
  it('closeGitViewer includes workspaceId + itemId when the active task belongs to a kanban (add-workspace-id-params)', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    const kanban = makeKanbanItem()
    // Inject the active task into the kanban's `tasks` array so the
    // activeTask computed can find it (mirrors the workspaces
    // store's setActiveTask auto-discovery at workspaces.ts:3366).
    kanban.tasks = [{ id: 'task_active', name: 'Active Task' } as any]
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask('task_active')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeGitViewer()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const query = lastCall![0].query as Record<string, string>
    // The close-viewer priority is: activeWorkspaceItem > activeTask
    // > chat. The user has both a kanban active AND a task active,
    // so the URL returns to the kanban view. workspaceId + itemId
    // are now required so the URL stays in the workspace context.
    expect(query.view).toBe('workspace')
    expect(query.workspaceId).toBe(WS_ID)
    expect(query.itemId).toBe(KANBAN_ID)
    // pageId must NOT leak into a kanban URL.
    expect(query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('closeGitViewer falls to chat branch when only the task is active (no workspace item)', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    // No workspace item active — only a chat task (chat-only).
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace,
    ]
    // activeTask.value is null because no item owns the task —
    // activeTask computed walks the tree. The branch falls through
    // to chat since neither activeWorkspaceItem nor activeTask
    // computed is truthy. Defensive: workspaceId absent.
    ws.setActiveTask('task_chat_only')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeGitViewer()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const query = lastCall![0].query as Record<string, string>
    // Falls through to chat branch (no workspace item, no resolvable task).
    expect(query.workspaceId).toBeUndefined()
    expect(query.itemId).toBeUndefined()
    expect(query.view).toBe('chat')
    wrapper.unmount()
  })

  it('closeSkillViewer includes workspaceId + itemId + pageId when the active task belongs to a design', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    design.tasks = [{ id: 'task_design_active', name: 'Design Task' } as any]
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    ws.setActiveTask('task_design_active')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeSkillViewer()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const query = lastCall![0].query as Record<string, string>
    // The close-viewer priority is: activeWorkspaceItem > activeTask
    // > chat. Both the design item AND the task are active, so the
    // URL returns to the workspace view (carrying the design
    // breadcrumb + active page).
    expect(query.view).toBe('workspace')
    expect(query.workspaceId).toBe(WS_ID)
    expect(query.itemId).toBe(DESIGN_ID)
    expect(query.pageId).toBe(PAGE_ID_2)
    wrapper.unmount()
  })

  it('closeCodeEditor falls through to chat when no workspace item owns the task', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    // No workspace item active — chat-only task.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace,
    ]
    ws.setActiveTask('task_chat_only')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeCodeEditor()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const query = lastCall![0].query as Record<string, string>
    // The branch falls through to chat (no active workspace item,
    // and `activeTask` computed returns null because no item owns
    // the task).
    expect(query.view).toBe('chat')
    expect(query.workspaceId).toBeUndefined()
    expect(query.itemId).toBeUndefined()
    wrapper.unmount()
  })
})

describe('AppLayout — design page URL persistence (pageId in URL)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({ columns: [], count: 0 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('activeDesignPage → URL watcher fires when activeDesignPageId changes externally', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
      path: '/app',
      fullPath: '/app?view=workspace',
    } as any)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: DESIGN_ID,
    })
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Externally set activeDesignPageId — the watcher should fire
    // and call router.replace with the new URL including pageId.
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: PAGE_ID_2,
      },
    })
    wrapper.unmount()
  })

  it('URL mirror does NOT include pageId when activeDesignPageId is empty', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace' },
      path: '/app',
      fullPath: '/app?view=workspace',
    } as any)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, { view: 'workspace' })
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Set the active workspace item (with no pageId).
    ws.setActiveWorkspaceItem(DESIGN_ID)
    await nextTick()
    await nextTick()
    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
    })
    // Ensure pageId is NOT in the query.
    const calls = replaceMock.mock.calls
    const lastCall = calls[calls.length - 1]
    expect(lastCall![0].query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('URL mirror does NOT overwrite non-workspace views (view=task) when activeDesignPageId changes', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'task', task: 'task_xyz' },
      path: '/app',
      fullPath: '/app?view=task&task=task_xyz',
    } as any)
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, { view: 'task', task: 'task_xyz' })
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    ws.setActiveDesignPage(PAGE_ID_1)
    await nextTick()
    await nextTick()
    expect(replaceMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('mounting with ?view=workspace&pageId=Z restores activeDesignPageId in the store', async () => {
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace],
      { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID, pageId: PAGE_ID_2 },
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(DESIGN_ID)
    expect(ws.activeDesignPageId).toBe(PAGE_ID_2)
    wrapper.unmount()
  })

  it('mounting without pageId does NOT auto-select any design page', async () => {
    const ws = useWorkspacesStore()
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace],
      { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(DESIGN_ID)
    expect(ws.activeDesignPageId).toBe('')
    wrapper.unmount()
  })

  // NEW (kanban default-URL, 2026-08-06): handleNavigate accepts a
  // 7th positional arg `sortsParam` and mirrors it into the URL
  // query as `?sorts=...`. Sidebar passes this when the user clicks
  // a kanban workspace item so the default sort survives a reload.
  it('handleNavigate("workspace", wsId, itemId, "", sortsParam) writes sorts into the URL', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any

    const sortsParam = 'col_a:updated_at:desc,col_b:updated_at:desc'
    // 7-arg call: view, chatName, taskId, workspaceId, itemId, pageId, sortsParam
    layout.handleNavigate(
      'workspace',
      undefined,
      undefined,
      WS_ID,
      KANBAN_ID,
      '',
      sortsParam,
    )

    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: KANBAN_ID,
        sorts: sortsParam,
      },
    })
    wrapper.unmount()
  })

  it('handleNavigate("workspace", wsId, itemId, "", undefined) OMITS sorts (non-kanban path)', async () => {
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    const layout = wrapper.vm as any

    // 7-arg call with undefined sortsParam (e.g. folder / design click).
    layout.handleNavigate(
      'workspace',
      undefined,
      undefined,
      WS_ID,
      DESIGN_ID,
      'page_X',
      undefined,
    )

    expect(replaceMock).toHaveBeenCalledWith({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: DESIGN_ID,
        pageId: 'page_X',
      },
    })
    const lastQuery = replaceMock.mock.calls[0]![0].query
    expect(lastQuery.sorts).toBeUndefined()
    wrapper.unmount()
  })
})
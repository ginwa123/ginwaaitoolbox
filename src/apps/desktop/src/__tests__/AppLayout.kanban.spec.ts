/**
 * Tests for AppLayout's main-content rendering when the active
 * workspace item is a kanban (post-2026-06-21 migration). The
 * kanban board used to render inline in the sidebar; it now lives
 * in the main content area as a sibling of ChatView.
 *
 *   - <KanbanView> renders in the main content area when
 *     activeWorkspaceItem.item_type === 'kanban' and no task is
 *     active
 *   - When an active task is set AND the task's parent is the
 *     active kanban, <KanbanView> renders full-width and
 *     <ChatView> floats as an overlay on top of the kanban (the
 *     "floating chat overlay" pattern, 2026-06-29). The
 *     ChatView's ✕ close button clears the active task and
 *     returns to the kanban-only view.
 *   - When the active task's parent is NOT the active kanban
 *     (e.g. a folder task), only <ChatView> renders (the original
 *     single-column behavior is preserved).
 *   - Folder items still render the empty-state placeholder
 *     (no <KanbanView>)
 *   - The kanban events (addColumn, moveTask, etc.) wire through
 *     to the workspaces store
 *
 * Pre-2026-06-29 the kanban+chat was a 3-col flex layout
 * (sidebar | kanban | chatview) with a drag-resize handle
 * between the kanban and the chat columns. Post-refactor, the
 * chat floats on top of the kanban (no side-by-side column
 * boundary to resize). The design-mode branch kept its 3-col
 * layout — see DesignChatToggle.spec.ts for design-mode tests.
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { flushPromises, mount } from '@vue/test-utils'
import { createApp, nextTick, reactive, ref } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace, WorkspaceItem, KanbanColumn, Task } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// Test-only stub SseClient. Mirrors the helper in App.spec.ts /
// sseBus.spec.ts (kept inline rather than shared to avoid coupling
// between spec files). Starts in 'open' state — the SseStatusBadge
// is a no-op for 'open' and 'closed', so the AppLayout mount won't
// render any pill, which keeps the existing assertions about
// <KanbanView> / <ChatView> placement clean.
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

// Install the SSE bus singleton BEFORE mounting AppLayout. Required
// by (a) the workspaces store's installSessionEventHandlers which
// calls useSseBus() in its init() (line 1553 of stores/workspaces.ts),
// and (b) the <SseStatusBadge /> child of AppLayout which calls
// useSseBus() in its setup. App.vue's production onMounted does this
// install; in tests we do it explicitly per beforeEach.
function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient('open'))
}

// AppLayout uses useRouter / useRoute. Stub the composables at
// module level (Options-API mocks only patch this.$router, not
// the setup-time call). The reactive route is mutated per-test
// to drive the URL-driven routes.
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

const WS_ID = 'ws_1'
const KANBAN_ID = 'item_kanban'
const FOLDER_ID = 'item_folder'
const TASK_ID = 'task_in_kanban'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_a',
  workspace_item_id: KANBAN_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: TASK_ID,
  name: 'My Task',
  ...overrides,
})

const makeKanbanItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: KANBAN_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [
    makeColumn({ id: 'col_todo', name: 'todo', position: 0 }),
    makeColumn({ id: 'col_done', name: 'done', position: 1 }),
  ],
  tasks: [],
  ...overrides,
})

const makeFolderItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: FOLDER_ID,
  name: 'My Project',
  item_type: 'folder',
  path: '/abs/path',
  tasks: [],
  ...overrides,
})

function mountAppLayout(workspaces: Workspace[] = []) {
  const ws = useWorkspacesStore()
  // Initialize the store's `workspaces` ref directly (skip init()).
  // init() fetches from the API and is mocked below.
  ws.workspaces = workspaces
  return mount(AppLayout, {
    global: {
      stubs: {
        // Stub the heavy / unrelated children to keep the test
        // focused on main-content routing.
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        ChatView: true,
        Chats: true,
        SettingsView: true,
        CodeEditor: true,
        KanbanView: { template: '<div data-kanban-view="stub" :data-item-id="item.id" />', props: ['item', 'workspaceId', 'itemId'] },
      },
    },
  })
}

describe('AppLayout — kanban main-content rendering', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Reset the route mock to a clean workspace default.
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    } as any)
    // Mock workspace + chat API calls that fire-and-forget on mount.
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

  it('renders <KanbanView> in the main content area when activeWorkspaceItem is a kanban', async () => {
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    // The stub <KanbanView> has data-kanban-view="stub" + a
    // data-item-id set from props.item.id. Assert the kanban
    // received the right item.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(true)
    expect(view.attributes('data-item-id')).toBe(KANBAN_ID)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> for folder items (the folder branch shows the empty-state placeholder)', async () => {
    const folder = makeFolderItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [folder] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> when no active workspace item is set', async () => {
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ])
    await nextTick()
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })
})

describe('AppLayout — kanban task view (floating chat overlay)', () => {
  // Pre-2026-06-29: ChatView and KanbanView shared a 3-col flex
  // layout (sidebar | kanban | chatview) — kanban at ~40% width,
  // chatview absorbing the rest. Resize handle between them.
  //
  // Post-2026-06-29: ChatView floats on top of the kanban as an
  // absolute-positioned panel anchored to the right edge. Kanban
  // fills the full main area. No resize handle (the chat width is
  // a fixed constant). Data attribute renamed from
  // `data-kanban-three-column` to `data-kanban-with-floating-chat`.
  //
  // The 3-col layout is still used by the design-mode branch
  // (data-design-three-column / data-design-resize-handle), which
  // is tested in DesignChatToggle.spec.ts.
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    } as any)
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

  it('renders BOTH <KanbanView> and <ChatView> when the active task\'s parent is the active kanban (floating chat overlay)', async () => {
    // The "click a kanban card" flow now opens the task's chat
    // view as a floating overlay on top of the kanban (not as a
    // 3-col split). The user keeps the full kanban board in view
    // and the chat sits over the right side of it. A ✕ button
    // in the chat header collapses the chat back to the kanban-
    // only view.
    //
    // The v-else-if condition requires:
    //   activeTask && activeWorkspaceItem.item_type === 'kanban'
    //   && activeTaskWorkspaceItemId === activeWorkspaceItem.id
    // The last clause is what distinguishes this case from a
    // task whose parent is a folder (those still use the
    // single-column ChatView branch).
    const kanban = makeKanbanItem({
      tasks: [makeTask({ kanban_column_id: 'col_todo' })],
    })
    const routeObj = reactive({
      query: { view: 'task', task: TASK_ID } as Record<string, string>,
      path: '/app',
      fullPath: `/app?view=task&task=${TASK_ID}`,
    })
    useRouteMock.mockReturnValue(routeObj as any)
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask(TASK_ID)
    await nextTick()
    // Kanban renders full-width. Wrapper has the new
    // data-kanban-with-floating-chat attribute (added 2026-06-29).
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(true)
    expect(view.attributes('data-item-id')).toBe(KANBAN_ID)
    const floatingContainer = wrapper.find('[data-kanban-with-floating-chat]')
    expect(floatingContainer.exists()).toBe(true)
    // The old 3-col container MUST NOT be present (would mean the
    // refactor regressed to a side-by-side layout).
    const oldThreeCol = wrapper.find('[data-kanban-three-column]')
    expect(oldThreeCol.exists()).toBe(false)
    // The floating chat panel exists inside the wrapper.
    const floatingChat = wrapper.find('[data-testid="floating-chat"]')
    expect(floatingChat.exists()).toBe(true)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> when the active task\'s parent is a different workspace item (single-column ChatView)', async () => {
    // When the user has a folder task selected AND a kanban is
    // the active workspace item (an edge case — the user
    // selected the kanban first, then somehow ended up with a
    // task from a different parent), the floating-chat branch's
    // last condition (`activeTaskWorkspaceItemId === activeWorkspaceItem.id`)
    // is false. We fall through to the single-column ChatView
    // branch, so the kanban does NOT render alongside the chat.
    // This guards against the visual mess of showing a chat
    // for one task alongside an unrelated kanban.
    const folder = makeFolderItem({
      id: FOLDER_ID,
      tasks: [makeTask({ id: 'task_in_folder', kanban_column_id: null })],
    })
    const kanban = makeKanbanItem({ id: KANBAN_ID }) // no tasks in this kanban
    const routeObj = reactive({
      query: { view: 'task', task: 'task_in_folder' } as Record<string, string>,
      path: '/app',
      fullPath: `/app?view=task&task=task_in_folder`,
    })
    useRouteMock.mockReturnValue(routeObj as any)
    const wrapper = mountAppLayout([
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [kanban, folder],
      } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID) // kanban is the active WS item
    ws.setActiveTask('task_in_folder') // ...but the active task lives in the folder
    await nextTick()
    // activeTaskWorkspaceItemId === FOLDER_ID, not KANBAN_ID — so
    // the floating-chat branch doesn't match. The standalone
    // ChatView (task) branch renders, and the kanban stays out.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    const floatingContainer = wrapper.find('[data-kanban-with-floating-chat]')
    expect(floatingContainer.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does NOT render a kanban-column resize handle in the floating chat layout (removed 2026-06-29)', async () => {
    // Pre-2026-06-29, the kanban+chat was a 3-col flex layout
    // with a drag-resize handle between the kanban column and
    // the chat column. Post-refactor, the kanban fills the
    // full main area and the chat floats on top — there is no
    // side-by-side column boundary to resize. The
    // `kanban-resize-handle` testid no longer exists in this
    // branch. (The design-mode branch still has its own
    // `design-resize-handle`; that's tested in DesignChatToggle.spec.ts.)
    const kanban = makeKanbanItem({
      tasks: [makeTask({ kanban_column_id: 'col_todo' })],
    })
    useRouteMock.mockReturnValue({
      query: { view: 'task', task: TASK_ID } as Record<string, string>,
      path: '/app',
      fullPath: `/app?view=task&task=${TASK_ID}`,
    } as any)
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask(TASK_ID)
    await nextTick()
    const handle = wrapper.find('[data-testid="kanban-resize-handle"]')
    expect(handle.exists()).toBe(false)
    wrapper.unmount()
  })

  it('renders the floating chat panel anchored to the right edge of the kanban wrapper', async () => {
    // The floating chat is `position: absolute; right: 0` inside
    // the kanban wrapper (which is `position: relative`). Verify
    // the data-floating-chat container is a descendant of the
    // kanban-with-floating-chat wrapper, NOT a sibling (the old
    // 3-col layout made it a sibling of the kanban column).
    const kanban = makeKanbanItem({
      tasks: [makeTask({ kanban_column_id: 'col_todo' })],
    })
    useRouteMock.mockReturnValue({
      query: { view: 'task', task: TASK_ID } as Record<string, string>,
      path: '/app',
      fullPath: `/app?view=task&task=${TASK_ID}`,
    } as any)
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask(TASK_ID)
    await nextTick()
    const wrapperEl = wrapper.find('[data-kanban-with-floating-chat]')
    expect(wrapperEl.exists()).toBe(true)
    // The floating chat is a CHILD of the wrapper (not a sibling).
    const childFloatingChat = wrapperEl.find('[data-testid="floating-chat"]')
    expect(childFloatingChat.exists()).toBe(true)
    wrapper.unmount()
  })

  // NOTE: The pre-2026-06-29 tests for kanban-resize-handle,
  // kanban-column-width persistence, and "restores persisted
  // kanban width on mount" were REMOVED when the kanban+chat
  // layout migrated from a 3-col flex layout to a floating
  // overlay. The kanban column now fills the full main area
  // (no resize needed); the resize handle + width persistence
  // logic was specific to the 3-col layout and no longer has a
  // test surface in this branch.
  //
  // The 3-col flex layout + resize handle still exists for the
  // design-mode branch (data-design-three-column /
  // design-resize-handle). Those tests live in
  // DesignChatToggle.spec.ts and were NOT touched by this refactor.
})

describe('AppLayout — kanban survives route navigation (regression: activeWorkspaceItemId is NOT cleared by ?view=workspace)', () => {
  // Pre-migration, the AppLayout's route.query watcher
  // (line 727-732) cleared activeWorkspaceItemId whenever the URL
  // query `view === 'workspace'`. Sidebar's handleSelectItem
  // navigates to that exact URL, so if we had wired the kanban
  // to the active workspace item + workspace URL, the route
  // watcher would have cleared the kanban selection the moment
  // it was set, leaving the user with an empty main content area.
  //
  // Post-migration, AppLayout renders <KanbanView> when the
  // active item is a kanban. The route watcher must NOT clear
  // activeWorkspaceItemId in that case — the kanban IS the
  // active workspace item.
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Drive AppLayout with a `?view=workspace` URL.
    useRouteMock.mockReturnValue({
      query: { view: 'workspace' } as Record<string, string>,
      path: '/app',
      fullPath: '/app?view=workspace',
    } as any)
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

  it('when URL is ?view=workspace and activeWorkspaceItem is a kanban, the kanban renders (not the empty state)', async () => {
    // Regression guard: prior to the kanban→main-content migration,
    // AppLayout's route.query watcher at the `!view || view ===
    // 'workspace'` branch called workspacesStore.setActiveWorkspaceItem(null)
    // — which clobbered the active kanban selection the moment
    // Sidebar's handleSelectItem set it (because handleSelectItem
    // navigates to exactly this URL).
    //
    // The fix: the watcher no longer clears activeWorkspaceItemId
    // for `view === 'workspace'`. Folder items would also have
    // been broken by the previous clear; this test pins both
    // folder and kanban cases in place.
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    // Set the active item AFTER mount so it doesn't race with
    // AppLayout's onMounted → initializeFromSystemFolder → init()
    // call (which would otherwise wipe the test-injected kanban
    // from the store with the mocked-empty API response).
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    // currentView is 'workspace' (per the route mock) but the
    // kanban branch is checked BEFORE the workspace empty-state
    // branch in the v-else-if chain, so the kanban view wins.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(true)
    wrapper.unmount()
  })

  // Regression guard for commit d0a05eb0 ("feat(design): Figma-
  // lite redesign — file-backed HTML + 3 LLM tools", PR #90).
  // That commit added the design+chat 3-column branch at line
  // ~1530 but accidentally typed `v-if` instead of `v-else-if`.
  // The typo split the main-content chain in two: chain A still
  // renders the kanban view (line ~1490), and chain B (the new
  // chain starting at the typo'd `v-if`) renders the workspace
  // folder preview at line ~1616 because `currentView === 'workspace'`
  // is the first branch in chain B that's true. The user sees
  // the kanban board above the workspace folder card (the
  // "strange UI at the bottom" report from task 1784047851096).
  //
  // Fix: that block is now `v-else-if` (merged back into chain A).
  // This test pins the contract: when the active workspace item
  // is a kanban AND the URL is ?view=workspace, only the kanban
  // view renders — the workspace folder preview's
  // data-testid="workspace-folder-preview" must NOT be in the DOM.
  it('kanban renders alone — workspace folder preview is NOT in the DOM (?view=workspace + kanban active)', async () => {
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    // Kanban view is rendered (sanity — passes pre-fix too).
    expect(wrapper.find('[data-kanban-view="stub"]').exists()).toBe(true)
    // THE actual regression assertion: workspace folder preview
    // must NOT be in the DOM. Pre-fix this assertion failed because
    // the typo'd `v-if` started a second chain that also evaluated
    // `currentView === 'workspace'` to true.
    expect(wrapper.find('[data-testid="workspace-folder-preview"]').exists()).toBe(false)
    wrapper.unmount()
  })
})

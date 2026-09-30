/**
 * Regression specs for the two Documents-feature failures a user reported
 * against Migration 095 ("Documents" sidebar section + viewer).
 *
 * BUG 1 — "No workspace selected" with a workspace plainly selected.
 *   `Sidebar.vue` bound `DocumentsList`'s `workspace-id` prop to the RAW
 *   `workspacesStore.activeWorkspaceId` ref, and `DocumentsView.vue` read
 *   the same ref for its own fetch scope. That ref is only set by the
 *   header dropdown or a `?workspaceId=` URL restore — clicking a project
 *   row under PROJECTS sets only `activeWorkspaceItemId`. Every other
 *   consumer in the tree binds `activeWorkspace?.id ?? null`, the computed
 *   carrying the documented precedence fallback (explicit → persisted →
 *   item-owning workspace → first workspace). Documents was the only
 *   section still on the raw ref.
 *
 *   Why the old specs missed it: `DocumentsList.spec.ts` mounts the
 *   component with an explicit `workspaceId: 'ws_1'` PROP, so it can only
 *   ever test the component, never the binding that feeds it. Test 1
 *   below therefore mounts the real `Sidebar`, which is the only way to
 *   exercise that binding.
 *
 * BUG 2 — clicking a document row does nothing.
 *   A two-hop loop in AppLayout, not the one-hop race the store comment
 *   describes. Verified hop by hop:
 *     hop 2 — the URL→store watcher watches `[route.path, route.query]`,
 *       so a query-only `?doc=` change re-ran the project branch and
 *       re-adopted the path's project. Its `isOverlayView` guard covered
 *       gitfile/skill/code-editor but NOT `doc`, even though
 *       `currentView` and `useCurrentMainView` both check `doc` FIRST.
 *       This watcher was the one place that didn't.
 *     hop 3 — that re-adoption re-fired the store→URL mirror, whose `sub`
 *       whitelist was pageId/sorts/detail only, so `router.replace(target)`
 *       dropped `doc`. Note the mirror's local `currentView` is a raw
 *       `route.query.view` read that shadows the computed, so on a
 *       path-based URL (no `view=` param) its guard passes and hop 3 runs.
 *   Net effect: the click's own navigation was undone a microtask later,
 *   which is exactly "nothing happens".
 *
 * ── Note on how these specs are shaped ──
 * Both watcher tests need `useRoute` to hand back a REACTIVE object that
 * the test mutates AFTER mount. A plain object per test (the shape
 * `sidebarSingleActive.spec.ts` uses, and `AppLayout.chatClickUrlOverwrite`
 * relies on) never re-triggers `[route.path, route.query]`, so the whole
 * hop-2 → hop-3 chain silently does not run and the specs pass against the
 * broken code. Verified: with a plain route object these two tests are
 * green on pre-fix source. `route` below is `reactive()` and the tests
 * navigate by assigning to it.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import * as realApi from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useDocumentsStore } from '../stores/documents'
import AppLayout from '../components/AppLayout.vue'
import Sidebar from '../components/shell/Sidebar.vue'
import DocumentsView from '../components/workspace/DocumentsView.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const listDocuments = vi.hoisted(() => vi.fn())
const getDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    getDocument,
    getChats: vi.fn(),
    getWorkspaces: vi.fn(),
    getWorkspacesItems: vi.fn(),
    getTasks: vi.fn(),
    getSystemFolder: vi.fn(),
    getFolderContents: vi.fn(),
    createDocument: vi.fn(),
    updateDocument: vi.fn(),
    deleteDocument: vi.fn(),
  }
})

const { useRouteMock, useRouterMock, replaceMock, pushMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
  useRouterMock: vi.fn(),
  replaceMock: vi.fn(),
  pushMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

function makeStubClient(): SseClient {
  return {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'open',
    isConnected: () => true,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    state: 'open',
    lastError: null,
  } as unknown as SseClient
}

const WS_ID = 'ws_docs'
const ITEM_ID = 'item_kanban'
const DOC_ID = 'doc_1'
const PROJECT_PATH = `/app/${WS_ID}/projects/${ITEM_ID}`

const DOC = {
  id: DOC_ID,
  workspace_id: WS_ID,
  title: 'Release plan',
  content: '# Heading',
  format: 'markdown',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
}

/** One workspace owning one project — the shape in the user's screenshot. */
function makeWorkspace() {
  return {
    id: WS_ID,
    name: 'agentic coding',
    icon: '📁',
    expanded: true,
    items: [{ id: ITEM_ID, name: 'AGENTIC_KANBAN', item_type: 'kanban', tasks: [] }],
  }
}

/** The pre-bug state: workspaces loaded, a project selected, but the
 *  explicit workspace ref never set (nobody used the header dropdown). */
function seedProjectClickNavigation() {
  const ws = useWorkspacesStore()
  ws.workspaces = [makeWorkspace()]
  ws.setActiveWorkspaceItem(ITEM_ID)
  // Asserted, not assumed: the whole point is that this stays null while
  // the app still knows a workspace is selected.
  expect(ws.activeWorkspaceId).toBe(null)
  return ws
}

/** REACTIVE route — the test navigates by assigning to it after mount. */
const route = reactive({
  path: '/app',
  query: {} as Record<string, string>,
  fullPath: '/app',
})

function navigate(path: string, query: Record<string, string> = {}) {
  route.path = path
  route.query = { ...query }
  const qs = new URLSearchParams(query).toString()
  route.fullPath = path + (qs ? `?${qs}` : '')
}

beforeEach(() => {
  setActivePinia(createPinia())
  document.body.innerHTML = ''
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient())

  navigate('/app', {})
  useRouteMock.mockReturnValue(route)
  useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock })
  replaceMock.mockReset()
  replaceMock.mockReturnValue(Promise.resolve())
  pushMock.mockReset()

  listDocuments.mockReset()
  getDocument.mockReset()
  listDocuments.mockResolvedValue({ documents: [DOC], count: 1 })
  getDocument.mockResolvedValue({ document: DOC })
  vi.mocked(realApi.getChats).mockResolvedValue({
    sessions: [],
    has_more: false,
    next_cursor: null,
    total: 0,
  })
  vi.mocked(realApi.getWorkspaces).mockResolvedValue({ workspaces: [] })
  vi.mocked(realApi.getWorkspacesItems).mockResolvedValue({ items: [], count: 0 })
  vi.mocked(realApi.getTasks).mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  vi.mocked(realApi.getSystemFolder).mockResolvedValue({
    path: '/',
    absolute: '/',
    home: '/',
    entries: [],
  } as never)
})

afterEach(() => {
  __resetSseBus()
  vi.clearAllMocks()
})

const flush = async () => {
  for (let i = 0; i < 4; i++) await nextTick()
}

// ─── BUG 1 ────────────────────────────────────────────────────────────────

describe('Documents — a project click still counts as "a workspace is selected"', () => {
  it('the sidebar section lists documents instead of "No workspace selected"', async () => {
    seedProjectClickNavigation()

    const wrapper = mount(Sidebar, {
      global: {
        mocks: { $router: { replace: vi.fn(), push: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
    await flush()

    // The regression: the Documents section said "No workspace selected"
    // while PROJECTS showed a plainly-selected project. Mounting the real
    // Sidebar is the only way to see this — the component-level spec
    // passes a `workspaceId` prop and so never sees the binding.
    expect(wrapper.find('[data-testid="documents-section-body"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-no-workspace"]').exists()).toBe(false)
    // And it actually scoped the fetch to the right workspace.
    expect(listDocuments).toHaveBeenCalledWith(WS_ID)
    expect(wrapper.find(`[data-testid="document-row-${DOC_ID}"]`).exists()).toBe(true)
    wrapper.unmount()
  })

  it('the viewer resolves the workspace and fetches, instead of hanging on "Loading document…"', async () => {
    // DocumentsView receives only `documentId` — it has to learn the
    // workspace from the store itself. Pre-fix its `watch` bailed on a
    // null workspace, so no fetch ever happened.
    //
    // The documents store is deliberately LEFT EMPTY: `loadDocument`
    // short-circuits on a cache hit, so seeding it would make the spec
    // pass on the broken code. The fetch call is the assertion.
    seedProjectClickNavigation()
    const wrapper = mount(DocumentsView, { props: { documentId: DOC_ID } })
    await flush()

    expect(getDocument).toHaveBeenCalledWith(WS_ID, DOC_ID)
    wrapper.unmount()
  })

  it('with the document already listed, the editor and its controls render', async () => {
    // Rendering contract, reached the way a real click reaches it: the
    // sidebar has listed the workspace, so `findById` serves the body.
    seedProjectClickNavigation()
    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true
    const wrapper = mount(DocumentsView, { props: { documentId: DOC_ID } })
    await flush()

    expect(wrapper.get('[data-testid="documents-title"]').text()).toBe('Release plan')
    // The control the user was looking for: "the ui to adjust documents".
    expect(wrapper.find('[data-testid="documents-edit"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-delete"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

// ─── BUG 2 ────────────────────────────────────────────────────────────────

const STUB_CONFIG = {
  Sidebar: true,
  RightSidebar: true,
  GitFileViewer: true,
  SkillDetail: true,
  Chats: true,
  SettingsView: true,
  ChatView: true,
  CodeEditor: true,
  KanbanView: {
    template: '<div data-kanban-view="stub" :data-item-id="item.id" />',
    props: ['item', 'workspaceId', 'itemId'],
  },
  DesignView: {
    template: '<div data-design-view="stub" :data-item-id="item.id" />',
    props: ['item', 'workspaceId', 'itemId'],
  },
}

/** Replace calls whose query is missing `doc` — the clobber shape. */
function replacesDroppingDoc() {
  return replaceMock.mock.calls.filter((call) => {
    const q = (call[0] ?? {}).query as Record<string, string> | undefined
    return q && q.doc === undefined
  })
}

describe('AppLayout — opening a document from a project survives the URL watchers', () => {
  it('a ?doc= click is not undone a microtask later by the store->URL mirror', async () => {
    // The user's exact state: sitting on a PROJECT path, because that is
    // where the Documents section lives. Path-based URLs carry no `view=`
    // query param, which is what let the mirror past its own guard.
    navigate(PROJECT_PATH)
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    ws.setActiveWorkspaceItem(ITEM_ID)
    await flush()
    replaceMock.mockClear()

    // DocumentsList.selectDocument's exact order: the router.replace is
    // async, so the synchronous store writes below happen FIRST and the
    // query lands a microtask later.
    ws.setActiveWorkspaceItem(null)
    ws.setActiveTask(null)
    await flush()
    navigate(PROJECT_PATH, { doc: DOC_ID })
    await flush()

    // The regression: the mirror re-adopted the project from the path and
    // then router.replace'd a URL with no `doc` — so the document the user
    // just clicked never opened, with no error anywhere to explain it.
    expect(replacesDroppingDoc()).toHaveLength(0)

    // And the URL->store watcher must not re-adopt the project either: the
    // document is the main content, so re-highlighting the project row
    // behind it is the "two active rows" bug sidebarSingleActive guards.
    expect(ws.activeWorkspaceItemId).toBe(null)
    wrapper.unmount()
  })

  it('regression-guard: the mirror CARRIES ?doc= so a store write cannot close the editor', async () => {
    // Cold boot / refresh on a document deep link. The URL restore adopts
    // the item from the path and the mirror fires with no prior state to
    // bail on — before the fix this was a second, click-free way to lose
    // the open document.
    navigate(PROJECT_PATH, { doc: DOC_ID })
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    replaceMock.mockClear()

    ws.setActiveWorkspaceItem(ITEM_ID)
    await flush()

    expect(replacesDroppingDoc()).toHaveLength(0)
    wrapper.unmount()
  })

  it('the document is an overlay inside <main>, not a 50/50 sibling of it', async () => {
    navigate(PROJECT_PATH, { doc: DOC_ID })
    useDocumentsStore().documents = [DOC]
    useDocumentsStore().loaded = true

    // DocumentsView is deliberately NOT stubbed here — the assertion is
    // about where AppLayout puts it and how it fills <main>.
    const wrapper = mount(AppLayout, { global: { stubs: STUB_CONFIG } })
    await flush()

    const inMain = wrapper.find('main [data-testid="documents-view"]')
    expect(inMain.exists()).toBe(true)
    // `absolute inset-0` is what makes it COVER the project behind it.
    // As a `flex-1` sibling of <main> it split the surface in half.
    expect(inMain.classes()).toContain('absolute')
    expect(inMain.classes()).toContain('inset-0')
    wrapper.unmount()
  })
})

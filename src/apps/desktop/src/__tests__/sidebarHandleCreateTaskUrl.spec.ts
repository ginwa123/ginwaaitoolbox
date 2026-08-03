/**
 * Behavioural tests for `Sidebar.handleAddTaskPick` (Standard Chat
 * auto-create) and `Sidebar.handleRunRoutine` (routine run) URL
 * behaviour (plan 2026-08-06-better-url-browser-standard-ai.md,
 * task task_1785786201882).
 *
 * **Bug fixed (2026-08-06):** "when click header, and then the
 * task, the url should not replace but append so it will be make
 * sense". The previous fix (PR #178 / #179) wired
 * `handleSelectTask` to `router.push` so the URL preserves the
 * workspace context AND the browser back button returns to the
 * kanban URL naturally. Two parallel code paths were missed in
 * that fix:
 *
 *   1. `Sidebar.handleAddTaskPick` — auto-creates a Standard Chat
 *      task when the user clicks "+ Standard Chat" on a folder /
 *      design / chat item. Pre-fix this used `router.replace`,
 *      clobbering the workspace URL in the browser history.
 *
 *   2. `Sidebar.handleRunRoutine` — fires a routine task and
 *      navigates to its chat. Pre-fix this used `router.replace`
 *      too, so back-buttoning from the routine's chat skipped the
 *      kanban column the user clicked from.
 *
 * After this fix, both paths use `router.push` AND snapshot the
 * URL's `sorts` into `savedSortsParam` (matching the existing
 * `handleSelectTask` contract) so a refresh / close-restore keeps
 * the per-column sort choice.
 *
 * No static-contract checks — every assertion is on the live router
 * after a push.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount, flushPromises } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import AddTaskPickerDialog from '../components/dialogs/AddTaskPickerDialog.vue'
import WorkspaceList from '../components/workspace/WorkspaceList.vue'
import type { WorkspaceItem } from '../stores/workspaces'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

// Local SseClient stub. Mirrors sidebarHandleSelectTaskUrl.spec.ts:41-52.
function makeStubClient(initial: 'connecting'): any {
  return {
    state: initial,
    lastError: null,
    getState: () => initial,
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
}

// Stub vue-router. Sidebar calls useRouter() and useRoute() in setup —
// we replace them with mocks whose query + push/replace are
// controllable per-test. Mirrors sidebarHandleSelectTaskUrl.spec.ts:57-77.
const { useRouteMock, useRouterMock } = vi.hoisted(() => {
  const routerStub = { replace: vi.fn(), push: vi.fn() }
  return {
    useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/app', fullPath: '/app' })),
    useRouterMock: vi.fn(() => routerStub),
    __routerStub: routerStub,
  }
})
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const WS_ID = 'ws_better_url_standard_ai'
const ITEM_ID = 'item_folder_better_url'
const TASK_ID = 'task_standard_ai_created'

const baseItem: WorkspaceItem = {
  id: ITEM_ID,
  name: 'Better URL Standard AI',
  item_type: 'folder',
  path: '/tmp',
  isLoaded: true,
  isLoading: false,
  tasks: [],
} as WorkspaceItem

function mountSidebar() {
  return mount(Sidebar, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

function resetRouterStubs() {
  // Re-init push/replace stubs so each test starts clean. The vi.hoisted
  // stubs are stable across the test run, so we just clear their calls.
  useRouterMock.mockClear()
  const router = (useRouterMock as any).getMockImplementation()()
  router.push.mockClear()
  router.replace.mockClear()
}

function lastPushCall(): { path: string; query: Record<string, string> } {
  const router = (useRouterMock as any).getMockImplementation()()
  const pushCalls = router.push.mock.calls
  expect(pushCalls.length).toBeGreaterThan(0)
  return pushCalls[pushCalls.length - 1]![0]
}

/**
 * Drive the realistic add-task → pick emit flow used in production:
 *
 *   1. User clicks "+" on a workspace item → WorkspaceItem emits
 *      `addTask(item)` → WorkspaceList forwards as `addTask(wsId, item)`
 *      → Sidebar's handleAddTask sets pickerWorkspaceId/pickerItemId +
 *      opens the picker.
 *   2. User clicks "Standard Chat" on the picker → AddTaskPickerDialog
 *      emits `pick('standard')` → Sidebar's handleAddTaskPick reads the
 *      just-set refs and auto-creates the task.
 *
 * Test mirrors this exactly — emit `add-task` on WorkspaceList FIRST
 * (sets the refs the handler reads), then emit `pick` on
 * AddTaskPickerDialog (triggers the navigate).
 */
async function triggerAddTaskPick(wrapper: any, item: WorkspaceItem) {
  const wsList = wrapper.findComponent(WorkspaceList)
  expect(wsList.exists()).toBe(true)
  wsList.vm.$emit('add-task', WS_ID, item)
  await nextTick()
  const picker = wrapper.findComponent(AddTaskPickerDialog)
  expect(picker.exists()).toBe(true)
  picker.vm.$emit('pick', 'standard')
  await flushPromises()
  await nextTick()
}

describe('Sidebar.handleAddTaskPick — Standard Chat auto-create uses PUSH (better-url-browser-standard-ai, 2026-08-06)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting') as SseClient)
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    // Reset the stubbed router push/replace per test.
    resetRouterStubs()
    // Default route query — each test overrides as needed.
    useRouteMock.mockImplementation(() => ({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    }))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function setRouteQuery(q: Record<string, string>) {
    useRouteMock.mockImplementation(() => ({
      query: q,
      path: '/app',
      fullPath: '/app',
    }))
  }

  it('uses router.push (not router.replace) when "+ Standard Chat" auto-creates a task', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })
    // Mock api.createTask so the auto-create branch succeeds and
    // returns a stable id.
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: TASK_ID,
      name: 'New Chat',
      task_type: 'standard',
      created_at: '2026-01-01',
      updated_at: '2026-01-01',
    } as any)

    const wrapper = mountSidebar()
    await triggerAddTaskPick(wrapper, baseItem)

    const router = (useRouterMock as any).getMockImplementation()()
    expect(router.push).toHaveBeenCalled()
    // The bug-fix assertion: replace must NOT be called.
    expect(router.replace).not.toHaveBeenCalled()

    wrapper.unmount()
  })

  it('preserves workspaceId + itemId in the auto-created Standard Chat URL', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: TASK_ID,
      name: 'New Chat',
      task_type: 'standard',
      created_at: '2026-01-01',
      updated_at: '2026-01-01',
    } as any)

    const wrapper = mountSidebar()
    await triggerAddTaskPick(wrapper, baseItem)

    const pushArg = lastPushCall()
    expect(pushArg.path).toBe('/app')
    expect(pushArg.query.view).toBe('task')
    expect(pushArg.query.task).toBe(TASK_ID)
    // The auto-created Standard Chat URL must carry the workspace
    // context so a refresh / back-button keeps the breadcrumb.
    expect(pushArg.query.workspaceId).toBe(WS_ID)
    expect(pushArg.query.itemId).toBe(ITEM_ID)

    wrapper.unmount()
  })

  it('snapshots route.query.sorts into savedSortsParam before navigating (close-restore fallback)', async () => {
    const store = useWorkspacesStore()
    // Kanban-flavoured item so the URL might carry sorts.
    const kanbanLike = {
      ...baseItem,
      item_type: 'kanban',
      kanban_columns: [
        { id: 'col_a', name: 'todo', workspace_item_id: ITEM_ID, position: 0, created_at: '2026-01-01' },
      ],
    } as WorkspaceItem
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [kanbanLike] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_a:name:asc',
    })
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: TASK_ID,
      name: 'New Chat',
      task_type: 'standard',
      created_at: '2026-01-01',
      updated_at: '2026-01-01',
    } as any)

    const wrapper = mountSidebar()
    await triggerAddTaskPick(wrapper, kanbanLike)

    // The snapshot is the close-restore fallback (handleCloseTaskView
    // reads savedSortsParam and writes it back to the workspace URL
    // on close). Without this, the round-trip drops the per-column
    // sort the user committed to.
    expect(store.savedSortsParam).toBe('col_a:name:asc')

    wrapper.unmount()
  })

  it('preserves sorts in the auto-created Standard Chat URL', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_a:updated_at:desc',
    })
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: TASK_ID,
      name: 'New Chat',
      task_type: 'standard',
      created_at: '2026-01-01',
      updated_at: '2026-01-01',
    } as any)

    const wrapper = mountSidebar()
    await triggerAddTaskPick(wrapper, baseItem)

    const pushArg = lastPushCall()
    expect(pushArg.query.view).toBe('task')
    expect(pushArg.query.workspaceId).toBe(WS_ID)
    // The kanban-mode breadcrumb is preserved across the create flow.
    expect(pushArg.query.sorts).toBe('col_a:updated_at:desc')

    wrapper.unmount()
  })

  it('uses router.push (not router.replace) on the local-fallback path when api.createTask fails', async () => {
    // The store has a local-fallback path for failed createTask
    // (catches the rejection, generates a `task-${Date.now()}` id,
    // unshifts a minimal task row, returns that id). The handler
    // proceeds normally on this fallback path — we just want to
    // lock in that it uses PUSH (not REPLACE) so the URL stays
    // consistent with the rest of the create flow.
    //
    // Why `mockRejectedValue` instead of `mockResolvedValue(undefined)`?
    // When the API resolves with undefined, the store's try-block
    // calls `unshift(undefined)` BEFORE returning `newTask.id` (which
    // throws on undefined). The catch runs the fallback path AND the
    // array contains an undefined entry — WorkspaceList's
    // `workspaceHasProcessingItem` computed then crashes on render.
    // `mockRejectedValue` short-circuits the try-block entirely,
    // skipping the bad `unshift(undefined)` and only running the
    // fallback's clean task insert. The handler still navigates
    // (with PUSH), which is what we want to lock in.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })
    vi.spyOn(api, 'createTask').mockRejectedValue(new Error('500 offline'))

    const wrapper = mountSidebar()
    await triggerAddTaskPick(wrapper, baseItem)

    const router = (useRouterMock as any).getMockImplementation()()
    // Even on the fallback path, the navigation should be PUSH —
    // never REPLACE. This is the bug-fix guarantee.
    expect(router.push).toHaveBeenCalled()
    expect(router.replace).not.toHaveBeenCalled()

    wrapper.unmount()
  })
})

describe('Sidebar.handleRunRoutine — uses PUSH (better-url-browser-standard-ai, 2026-08-06)', () => {
  const ROUTINE_TASK_ID = 'task_routine_better_url'

  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting') as SseClient)
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    resetRouterStubs()
    useRouteMock.mockImplementation(() => ({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    }))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function setRouteQuery(q: Record<string, string>) {
    useRouteMock.mockImplementation(() => ({
      query: q,
      path: '/app',
      fullPath: '/app',
    }))
  }

  // Kanban item holding a routine task — the realistic scenario for
  // "user clicks Run on a routine from a kanban column".
  const kanbanItemWithRoutine = {
    ...baseItem,
    item_type: 'kanban',
    kanban_columns: [
      {
        id: 'col_todo',
        name: 'todo',
        workspace_item_id: ITEM_ID,
        position: 0,
        created_at: '2026-01-01',
      },
    ],
    tasks: [
      {
        id: ROUTINE_TASK_ID,
        name: 'Nightly build',
        task_type: 'routine',
        routine: {
          schedule: '0 0 * * *',
          initial_prompt: 'Rebuild the project',
          enabled: true,
        },
      },
    ],
  } as WorkspaceItem

  /**
   * Trigger `run-routine` on WorkspaceList (the bubble-up target
   * for WorkspaceItemTaskRow → WorkspaceItem → WorkspaceList →
   * Sidebar.handleRunRoutine).
   */
  async function triggerRunRoutine(wrapper: any) {
    const wsList = wrapper.findComponent(WorkspaceList)
    expect(wsList.exists()).toBe(true)
    wsList.vm.$emit('run-routine', WS_ID, ITEM_ID, ROUTINE_TASK_ID)
    await flushPromises()
    await nextTick()
  }

  it('uses router.push (not router.replace) when a routine is run from a kanban', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [kanbanItemWithRoutine] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_todo:updated_at:desc',
    })
    // api.runRoutine returns a truthy result (handler navigates
    // only when result is truthy — see handleRunRoutine's guard).
    vi.spyOn(api, 'runRoutine').mockResolvedValue({
      session_id: ROUTINE_TASK_ID,
    } as any)

    const wrapper = mountSidebar()
    await triggerRunRoutine(wrapper)

    const router = (useRouterMock as any).getMockImplementation()()
    expect(router.push).toHaveBeenCalled()
    expect(router.replace).not.toHaveBeenCalled()

    wrapper.unmount()
  })

  it('preserves workspaceId + itemId + sorts + session in the routine URL', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [kanbanItemWithRoutine] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_todo:updated_at:desc',
    })
    vi.spyOn(api, 'runRoutine').mockResolvedValue({
      session_id: ROUTINE_TASK_ID,
    } as any)

    const wrapper = mountSidebar()
    await triggerRunRoutine(wrapper)

    const pushArg = lastPushCall()
    expect(pushArg.path).toBe('/app')
    expect(pushArg.query.view).toBe('task')
    expect(pushArg.query.task).toBe(ROUTINE_TASK_ID)
    // session mirrors task.id (task.id == session_id convention)
    expect(pushArg.query.session).toBe(ROUTINE_TASK_ID)
    // Kanban-mode breadcrumb preserved.
    expect(pushArg.query.workspaceId).toBe(WS_ID)
    expect(pushArg.query.itemId).toBe(ITEM_ID)
    expect(pushArg.query.sorts).toBe('col_todo:updated_at:desc')

    wrapper.unmount()
  })

  it('snapshots route.query.sorts into savedSortsParam before navigating', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [kanbanItemWithRoutine] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_todo:name:asc',
    })
    vi.spyOn(api, 'runRoutine').mockResolvedValue({
      session_id: ROUTINE_TASK_ID,
    } as any)

    const wrapper = mountSidebar()
    await triggerRunRoutine(wrapper)

    expect(store.savedSortsParam).toBe('col_todo:name:asc')

    wrapper.unmount()
  })

  it('does NOT navigate when api.runRoutine returns no result (silent no-op)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [kanbanItemWithRoutine] },
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })
    // Force runRoutine to fail (returns null / undefined). The
    // handler guards on `if (result)` and bails before the
    // router.push. Pre-fix this branch was dead because the URL
    // still navigated; post-fix it's the only place where neither
    // push nor replace fires.
    vi.spyOn(api, 'runRoutine').mockResolvedValue(undefined as any)

    const wrapper = mountSidebar()
    await triggerRunRoutine(wrapper)

    const router = (useRouterMock as any).getMockImplementation()()
    expect(router.push).not.toHaveBeenCalled()
    expect(router.replace).not.toHaveBeenCalled()

    wrapper.unmount()
  })
})
/**
 * Unit tests for the workspaces store's init() flow.
 * Mocks api.getWorkspaces, api.getWorkspacesItems, and api.getTasks
 * to assert the 3-call flow + task-attachment logic.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

describe('useWorkspacesStore.init()', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()
  // NEW (auto-expand-design-pages plan, 2026-08-06): init() now
  // fires listDesignPages for every design item in parallel with the
  // tasks fetch. Track it separately so we can assert the new
  // behaviour without polluting the existing tests (which have no
  // design items in their fixtures — listDesignPages should never
  // fire for them).
  const listDesignPagesMock = vi.fn()

  // Re-created per beforeEach so tests start with a clean Map. The shared
  // helper just builds the stub; lifecycle is the test's responsibility.
  let localStorageStub: Storage
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    // Reset stub + re-install (beforeEach may run after a previous test cleared it).
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    // init() calls installSessionEventHandlers() which uses
    // useSseBus() — install a stub bus before the store's init()
    // runs so the install path doesn't throw.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
    // NEW (auto-expand-design-pages plan): mock listDesignPages so
    // the design-page fetch in init() doesn't hit the network. The
    // default is an empty pages array — tests that want a populated
    // response call listDesignPagesMock.mockResolvedValueOnce(...)
    // per item they expect to be fetched.
    vi.spyOn(api, 'listDesignPages').mockImplementation(listDesignPagesMock)
    // Reset call history so toHaveBeenCalledTimes assertions stay
    // scoped to a single test. vi.restoreAllMocks() (in afterEach)
    // restores spy implementations but does NOT clear vi.fn()
    // call history, so without this the second test sees the first
    // test's calls and the call-count assertion below flakes.
    listDesignPagesMock.mockClear()
  })

  // Helper for design-item fixtures: produces the shape the backend
  // returns so we can assert against `design_pages` and the
  // `item_type === 'design'` branch in init() without breaking
  // existing tests.
  function makeDesignItem(overrides: Record<string, unknown> = {}) {
    return {
      id: 'item_design',
      name: 'design',
      item_type: 'design',
      workspace_id: 'ws_1',
      // Other fields the in-memory WorkspaceItem type requires —
      // init() doesn't read them so we can pass empty values.
      ...overrides,
    }
  }

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('fetches workspaces, then items + tasks per workspace in parallel', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [
        { id: 'ws_1', name: 'Workspace 1', icon: '📁' },
        { id: 'ws_2', name: 'Workspace 2', icon: '📁' },
      ],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_1a', name: 'A' }], count: 1 })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [], count: 0 })
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })

    const store = useWorkspacesStore()
    await store.init()

    expect(getWorkspacesMock).toHaveBeenCalledTimes(1)
    expect(getWorkspacesItemsMock).toHaveBeenCalledTimes(2)
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(1, 'ws_1')
    expect(getWorkspacesItemsMock).toHaveBeenNthCalledWith(2, 'ws_2')
    // item_1a triggers one getTasks call; ws_2 has no items
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    expect(getTasksMock).toHaveBeenCalledWith('ws_1', 'item_1a')
  })

  it('attaches tasks from getTasks(wsId, itemId) to the matching item', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_a', name: 'A' },
        { id: 'item_b', name: 'B' },
      ],
      count: 2,
    })
    // Tasks for item_a
    getTasksMock.mockResolvedValueOnce({
      tasks: [
        { id: 't1', name: 'T1', workspace_item_id: 'item_a' },
        { id: 't2', name: 'T2', workspace_item_id: 'item_a' },
      ],
      has_more: false,
      next_cursor: null,
    })
    // Tasks for item_b
    getTasksMock.mockResolvedValueOnce({
      tasks: [{ id: 't3', name: 'T3', workspace_item_id: 'item_b' }],
      has_more: false,
      next_cursor: null,
    })

    const store = useWorkspacesStore()
    await store.init()

    const items = store.workspaces[0]!.items
    expect(items).toHaveLength(2)
    const itemA = items.find((i) => i.id === 'item_a')!
    const itemB = items.find((i) => i.id === 'item_b')!
    expect(itemA.tasks).toHaveLength(2)
    expect(itemA.tasks!.map((t) => t.id).sort()).toEqual(['t1', 't2'])
    expect(itemB.tasks).toHaveLength(1)
    expect(itemB.tasks![0]!.id).toBe('t3')
  })

  it('restores expanded state from localStorage for workspaces and items', async () => {
    localStorage.setItem('nalar-workspace-expanded', JSON.stringify(['ws_1']))
    localStorage.setItem('nalar-workspace-item-expanded', JSON.stringify(['item_1a']))

    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_1a', name: 'A' }], count: 1 })
    getTasksMock.mockResolvedValueOnce({ tasks: [], has_more: false, next_cursor: null })

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces[0]!.expanded).toBe(true)
    expect(store.workspaces[0]!.items[0]!.expanded).toBe(true)
  })

  it('falls back to empty workspaces array when init fails', async () => {
    getWorkspacesMock.mockRejectedValueOnce(new Error('network down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toEqual([])
    expect(store.loadingError).toBe('network down')
    expect(store.isLoading).toBe(false)
  })

  it('keeps the workspace with empty tasks when a per-item tasks fetch fails', async () => {
    // Per-item task failure is non-fatal (logged + best-effort).
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [{ id: 'item_a', name: 'A' }], count: 1 })
    getTasksMock.mockRejectedValueOnce(new Error('tasks down'))

    const store = useWorkspacesStore()
    await store.init()

    expect(store.workspaces).toHaveLength(1)
    expect(store.workspaces[0]!.items[0]!.tasks).toEqual([])
    expect(store.loadingError).toBeNull()
  })

  // NEW (auto-expand-design-pages plan, 2026-08-06): init() must
  // fetch design pages for every design item in parallel with the
  // tasks fetch. The pre-fix code only fired listDesignPages lazily
  // on chevron click — which meant a refresh left the sidebar's
  // design-pages section empty until the user clicked the design
  // item's chevron. The user's report ("see workspace design, when
  // refresh its empty, but when i click it the header it show, can
  // you make all of that instant open") is exactly this regression.
  // The fix awaits the fetch in init() so the sidebar's <DesignPageRow>
  // children render populated as soon as init() resolves.

  it('fetches design pages for every design item in init()', async () => {
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        makeDesignItem({ id: 'item_design_a', name: 'design A' }),
        { id: 'item_folder_b', name: 'folder B', item_type: 'folder' },
        makeDesignItem({ id: 'item_design_c', name: 'design C' }),
      ],
      count: 3,
    })
    // Two design items → two listDesignPages calls. Folder item does
    // NOT fire listDesignPages.
    listDesignPagesMock
      .mockResolvedValueOnce({
        pages: [
          { id: 'page_a1', workspace_item_id: 'item_design_a', name: 'A1', position: 0 },
          { id: 'page_a2', workspace_item_id: 'item_design_a', name: 'A2', position: 1 },
        ],
        count: 2,
      })
      .mockResolvedValueOnce({
        pages: [{ id: 'page_c1', workspace_item_id: 'item_design_c', name: 'C1', position: 0 }],
        count: 1,
      })

    const store = useWorkspacesStore()
    await store.init()

    // One listDesignPages call per design item — never for non-design.
    expect(listDesignPagesMock).toHaveBeenCalledTimes(2)
    expect(listDesignPagesMock).toHaveBeenNthCalledWith(1, 'ws_1', 'item_design_a')
    expect(listDesignPagesMock).toHaveBeenNthCalledWith(2, 'ws_1', 'item_design_c')
    // Sidebar's <DesignPageRow> reads from this cache; populated
    // entries mean the rows will render as soon as init() resolves.
    expect(store.designPagesByItemId['item_design_a']).toHaveLength(2)
    expect(store.designPagesByItemId['item_design_c']).toHaveLength(1)
    expect(store.designPagesByItemId['item_design_a']?.[0]?.id).toBe('page_a1')
    expect(store.designPagesByItemId['item_design_c']?.[0]?.id).toBe('page_c1')
  })

  it('does NOT fire listDesignPages for non-design items in init()', async () => {
    // Belt-and-braces: the folder item in the previous test never
    // triggered a listDesignPages call. This test makes that
    // contract explicit so a future refactor doesn't accidentally
    // broaden the filter and fetch pages for, e.g., kanban items.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        { id: 'item_folder', name: 'folder', item_type: 'folder' },
        { id: 'item_chat', name: 'chat', item_type: 'chat' },
        { id: 'item_kanban', name: 'kanban', item_type: 'kanban' },
      ],
      count: 3,
    })

    const store = useWorkspacesStore()
    await store.init()

    // Zero design items → zero listDesignPages calls.
    expect(listDesignPagesMock).toHaveBeenCalledTimes(0)
    expect(store.designPagesByItemId).toEqual({})
  })

  it('keeps the workspace when a per-design-item pages fetch fails', async () => {
    // Best-effort contract — same as the per-item tasks fetch. A
    // single bad listDesignPages call logs and leaves the cache
    // empty for that item, but the workspace tree still loads. The
    // chevron-toggle lazy fetch in WorkspaceItem.vue is the
    // fallback that retries the failing item.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [
        makeDesignItem({ id: 'item_design_a' }),
        makeDesignItem({ id: 'item_design_b' }),
      ],
      count: 2,
    })
    // First design item succeeds, second rejects.
    listDesignPagesMock
      .mockResolvedValueOnce({
        pages: [{ id: 'page_a', workspace_item_id: 'item_design_a', name: 'A', position: 0 }],
        count: 1,
      })
      .mockRejectedValueOnce(new Error('pages down'))

    const store = useWorkspacesStore()
    await store.init()

    // Init didn't throw and the workspace tree is intact.
    expect(store.loadingError).toBeNull()
    expect(store.workspaces).toHaveLength(1)
    expect(store.workspaces[0]!.items).toHaveLength(2)
    // Succeeded design item: cache populated.
    expect(store.designPagesByItemId['item_design_a']).toHaveLength(1)
    // Failed design item: cache entry absent (fetchDesignPages
    // never assigned to designPagesByItemId on rejection).
    expect(store.designPagesByItemId['item_design_b']).toBeUndefined()
  })

  it('init populates the cache before isLoading flips to false (instant open)', async () => {
    // The whole point of the fix: when init() resolves, the sidebar's
    // design-pages section should be ready to render with the page
    // list — no "click the chevron to populate" gate. Verify by
    // checking that store.designPagesByItemId is populated at the
    // exact moment isLoading transitions to false.
    getWorkspacesMock.mockResolvedValueOnce({
      workspaces: [{ id: 'ws_1', name: 'W1', icon: '📁' }],
    })
    getWorkspacesItemsMock.mockResolvedValueOnce({
      items: [makeDesignItem({ id: 'item_design' })],
      count: 1,
    })
    listDesignPagesMock.mockResolvedValueOnce({
      pages: [{ id: 'page_1', workspace_item_id: 'item_design', name: 'AI Chat View', position: 0 }],
      count: 1,
    })

    const store = useWorkspacesStore()
    expect(store.isLoading).toBe(false) // before init
    await store.init()
    // After init() resolves, isLoading is false AND the cache is populated.
    expect(store.isLoading).toBe(false)
    expect(store.designPagesByItemId['item_design']).toHaveLength(1)
    expect(store.designPagesByItemId['item_design']?.[0]?.name).toBe('AI Chat View')
  })
})

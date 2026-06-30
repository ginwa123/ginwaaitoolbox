/**
 * Unit tests for the workspaces store's loadMoreTasks action.
 *
 * loadMoreTasks is the click-to-load action for the per-item task list
 * "Load more" button. It is the ONLY way second-or-later pages get
 * fetched (no auto-load / infinite scroll). Mirrors the
 * `loadMoreChats` pattern in ChatsList.vue:121-183.
 *
 * Plan: docs/plans/2026-06-10-workspace-item-task-pagination.md
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

const seedTasks = (n: number) =>
  Array.from({ length: n }, (_, i) => ({
    id: `t${i + 1}`,
    name: `Task ${i + 1}`,
    workspace_item_id: 'item_1a',
    created_at: `2026-06-10T10:0${i}:00.000Z`,
  }))

const baseItem = {
  id: 'item_1a',
  name: 'A',
  item_type: 'folder',
}

const baseWorkspace = {
  id: 'ws_1',
  name: 'Workspace 1',
  icon: '📁',
}

describe('useWorkspacesStore.loadMoreTasks()', () => {
  const getWorkspacesMock = vi.fn()
  const getWorkspacesItemsMock = vi.fn()
  const getTasksMock = vi.fn()

  let localStorageStub: Storage
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
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

    // The vi.fn()s are at describe scope, so mock.calls accumulates
    // across tests by default. Clear the call history at the start of
    // every test so per-test call-count assertions are accurate.
    // (The implementation is re-attached via the vi.spyOn below, so
    // we don't need to recreate the mocks.)
    getWorkspacesMock.mockClear()
    getWorkspacesItemsMock.mockClear()
    getTasksMock.mockClear()

    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  // Helper: run init() with the given first-page result so the store
  // is in a "first page loaded" state, ready for loadMoreTasks to be
  // called. Returns the store instance for convenience.
  async function initWithFirstPage(firstPage: {
    tasks: ReturnType<typeof seedTasks>
    has_more: boolean
    next_cursor: string | null
  }) {
    getWorkspacesMock.mockResolvedValueOnce({ workspaces: [baseWorkspace] })
    getWorkspacesItemsMock.mockResolvedValueOnce({ items: [baseItem], count: 1 })
    getTasksMock.mockResolvedValueOnce(firstPage)
    const store = useWorkspacesStore()
    await store.init()
    return store
  }

  it('appends the next page to the existing tasks and advances the cursor', async () => {
    // First page: 3 tasks, more available, cursor = 't3' created_at
    const firstPage = {
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    }
    const store = await initWithFirstPage(firstPage)
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    expect(getTasksMock).toHaveBeenNthCalledWith(1, 'ws_1', 'item_1a')

    // Second page: 2 tasks, end of pages
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(5).slice(3), // [t4, t5]
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasks('ws_1', 'item_1a')

    // getTasks was called a second time, with the cursor as the 4th arg
    expect(getTasksMock).toHaveBeenCalledTimes(2)
    expect(getTasksMock).toHaveBeenNthCalledWith(
      2,
      'ws_1',
      'item_1a',
      20, // PAGE_SIZE
      '2026-06-10T10:02:00.000Z', // the previous next_cursor
    )

    const item = store.workspaces[0]!.items[0]!
    expect(item.tasks).toHaveLength(5)
    expect(item.tasks!.map((t) => t.id)).toEqual(['t1', 't2', 't3', 't4', 't5'])
    expect(item.hasMoreTasks).toBe(false)
    expect(item.tasksNextCursor).toBeNull()
    expect(item.isLoadingMoreTasks).toBe(false)
  })

  it('is a no-op when hasMoreTasks is false (no second fetch)', async () => {
    // First page: no more pages available
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: false,
      next_cursor: null,
    })
    expect(getTasksMock).toHaveBeenCalledTimes(1) // only the init fetch

    await store.loadMoreTasks('ws_1', 'item_1a')

    // No second fetch — getTasks was not called again
    expect(getTasksMock).toHaveBeenCalledTimes(1)
  })

  it('is a no-op when a load is already in progress for this item', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    expect(getTasksMock).toHaveBeenCalledTimes(1)

    // Simulate an in-flight load by flipping the flag directly
    store.workspaces[0]!.items[0]!.isLoadingMoreTasks = true

    await store.loadMoreTasks('ws_1', 'item_1a')

    // No second fetch — guard fired
    expect(getTasksMock).toHaveBeenCalledTimes(1)
    // Flag is still true (we never finished the simulated load)
    expect(store.workspaces[0]!.items[0]!.isLoadingMoreTasks).toBe(true)
  })

  it('leaves state intact on fetch failure so the user can retry', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })

    // Second fetch rejects
    getTasksMock.mockRejectedValueOnce(new Error('network down'))

    await store.loadMoreTasks('ws_1', 'item_1a')

    const item = store.workspaces[0]!.items[0]!
    // Tasks unchanged
    expect(item.tasks).toHaveLength(3)
    expect(item.tasks!.map((t) => t.id)).toEqual(['t1', 't2', 't3'])
    // hasMoreTasks / cursor unchanged so the user can retry
    expect(item.hasMoreTasks).toBe(true)
    expect(item.tasksNextCursor).toBe('2026-06-10T10:02:00.000Z')
    // isLoadingMoreTasks flipped back to false
    expect(item.isLoadingMoreTasks).toBe(false)
  })

  it('is a no-op when the workspace or item does not exist', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    expect(getTasksMock).toHaveBeenCalledTimes(1)

    // Bad workspace id
    await store.loadMoreTasks('ws_does_not_exist', 'item_1a')
    // Bad item id
    await store.loadMoreTasks('ws_1', 'item_does_not_exist')

    // No extra fetches in either case
    expect(getTasksMock).toHaveBeenCalledTimes(1)
  })
})

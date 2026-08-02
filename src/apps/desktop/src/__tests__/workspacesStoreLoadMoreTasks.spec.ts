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

    // getTasks was called a second time, with the cursor as the 4th
    // arg + sortBy + direction + q (7 args total). When the user has
    // not picked a sort (init() loads the first page directly without
    // going through fetchKanbanTasks), the active sort maps are empty
    // — loadMoreTasks passes undefined for both sortBy and direction,
    // and the api layer's 'updated_at' / 'desc' default kicks in.
    // This is the back-compat behaviour: the cursor is in the
    // default order, the next page must use the same order.
    expect(getTasksMock).toHaveBeenCalledTimes(2)
    expect(getTasksMock).toHaveBeenNthCalledWith(
      2,
      'ws_1',
      'item_1a',
      10, // PAGE_SIZE
      '2026-06-10T10:02:00.000Z', // the previous next_cursor
      undefined, // sortBy — no active sort recorded → api default 'updated_at'
      undefined, // direction — api default 'desc'
      undefined, // q (no active search in this test)
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

  // ─── Active sort persistence (kanban-sort-by, plan
  // docs/superpowers/plans/2026-08-06-kanban-sort-by.md Chunk 3) ───
  // loadMoreTasks is the only path that paginates the kanban task
  // list. When the user has picked a per-column sort (e.g. name
  // desc), the cursor is in the sorted order — using a different
  // sort for the next page would fetch a meaningless slice. The
  // fix: loadMoreTasks reads the active sort from
  // activeSortBy / activeSortDirection (written by the most recent
  // fetchKanbanTasks call) and forwards it to api.getTasks.
  it('forwards the per-item active sort (name + desc) on loadMoreTasks', async () => {
    // Init: first page + cursor.
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    expect(getTasksMock).toHaveBeenCalledTimes(1)

    // User picks 'name' / 'desc' on the kanban view. fetchKanbanTasks
    // records the active sort in activeSortBy + activeSortDirection.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    await store.fetchKanbanTasks(
      'ws_1',
      'item_1a',
      10, // limit
      undefined, // cursor (page 1 of the sorted set)
      undefined, // q
      'name', // sortBy — the user's pick
      'desc', // direction
    )
    expect(getTasksMock).toHaveBeenCalledTimes(2)

    // User clicks "Load more" — must forward 'name' / 'desc', NOT
    // the pre-fix default of 'updated_at' / 'desc'. The cursor is
    // tied to the sort order; using a different sort here would
    // fetch a meaningless page.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(5).slice(3),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasks('ws_1', 'item_1a')

    expect(getTasksMock).toHaveBeenCalledTimes(3)
    const lastCall = getTasksMock.mock.calls[2]!
    expect(lastCall[0]).toBe('ws_1') // workspaceId
    expect(lastCall[1]).toBe('item_1a') // itemId
    expect(lastCall[2]).toBe(10) // PAGE_SIZE
    expect(lastCall[3]).toBe('2026-06-10T10:02:00.000Z') // cursor
    expect(lastCall[4]).toBe('name') // sortBy (the bug — pre-fix this is 'updated_at')
    expect(lastCall[5]).toBe('desc') // direction
    expect(lastCall[6]).toBeUndefined() // q
  })

  it('forwards the per-item active sort (created_at + asc) on loadMoreTasks', async () => {
    // Same as above but with a different field/direction combo to
    // lock in the contract that ANY active sort is forwarded (not
    // just the common name-desc case).
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    await store.fetchKanbanTasks(
      'ws_1', 'item_1a', 100, undefined, undefined,
      'created_at', 'asc',
    )
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(5).slice(3),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasks('ws_1', 'item_1a')

    const lastCall = getTasksMock.mock.calls[2]!
    expect(lastCall[4]).toBe('created_at')
    expect(lastCall[5]).toBe('asc')
  })

  it('forwards sortBy=undefined / direction=undefined to api.getTasks on loadMoreTasks when no active sort is recorded (back-compat with init)', async () => {
    // When init() loads the first page directly via api.getTasks (NOT
    // through fetchKanbanTasks), the active sort maps are empty.
    // loadMoreTasks passes undefined for BOTH sortBy and direction,
    // and the api layer's 'updated_at' / 'desc' default kicks in at
    // the URL level. The cursor is in the api-default order, the
    // next page must use the same order — using a different sort
    // would fetch a meaningless slice. This is the back-compat
    // contract for the init() path; the user-picked-sort path is
    // covered by the previous two tests.
    const store = await initWithFirstPage({
      tasks: seedTasks(3),
      has_more: true,
      next_cursor: '2026-06-10T10:02:00.000Z',
    })
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(5).slice(3),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasks('ws_1', 'item_1a')

    const lastCall = getTasksMock.mock.calls[1]!
    expect(lastCall[4]).toBeUndefined() // sortBy — empty maps → undefined → api default 'updated_at'
    expect(lastCall[5]).toBeUndefined() // direction — api default 'desc'
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

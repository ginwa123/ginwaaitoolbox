/**
 * Behavioural tests for the workspaces store's per-column pagination
 * (plan 2026-08-06-kanban-per-column-pagination.md, Task 8).
 *
 * Replaces the old board-wide `loadMoreTasks` tests with the new
 * per-column `loadMoreTasksForColumn` action. Each kanban column
 * paginates independently — `columnPagination[col.id]` holds the
 * per-column state (`cursor`, `hasMore`, `isLoading`).
 *
 * Covers:
 *  - fetchKanbanTasks populates per-column state for each column
 *    with tasks in the response.
 *  - fetchKanbanTasks resets columnPagination to a fresh map (no
 *    stale cursors from previous queries).
 *  - loadMoreTasksForColumn calls api.getTasks with column_id.
 *  - loadMoreTasksForColumn appends returned tasks to item.tasks.
 *  - loadMoreTasksForColumn updates columnPagination[colId].cursor
 *    + .hasMore.
 *  - loadMoreTasksForColumn is a no-op when hasMore=false (no
 *    second fetch).
 *  - loadMoreTasksForColumn is a no-op while isLoading=true (no
 *    double-click).
 *  - loadMoreTasksForColumn forwards the active sortBy + direction
 *    on the API call.
 *  - loadMoreTasksForColumn forwards the active q (search query) on
 *    the API call.
 *  - loadMoreTasksForColumn on error: leaves hasMore + cursor
 *    untouched (retry-by-click still works).
 *  - loadMoreTasksForColumn is a no-op when the column has no
 *    pagination state (column wasn't in the initial fetch).
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

const baseItem = {
  id: 'item_1a',
  name: 'Test Kanban',
  item_type: 'kanban',
  path: '/tmp',
  kanban_columns: [
    { id: 'col_a', name: 'todo', workspace_item_id: 'item_1a', position: 0, created_at: '2026-01-01' },
    { id: 'col_b', name: 'in_progress', workspace_item_id: 'item_1a', position: 1, created_at: '2026-01-01' },
  ],
}

const baseWorkspace = {
  id: 'ws_1',
  name: 'Workspace 1',
  icon: '📁',
}

const seedTasks = (count: number, prefix = 't', columnId?: string) =>
  Array.from({ length: count }, (_, i) => ({
    id: `${prefix}${i + 1}`,
    name: `Task ${i + 1}`,
    workspace_item_id: 'item_1a',
    task_type: 'standard',
    created_at: `2026-06-10T10:0${i}:00.000Z`,
    kanban_column_id: columnId,
    kanban_position: i,
  }))

describe('useWorkspacesStore.loadMoreTasksForColumn() — per-column pagination', () => {
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

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    getWorkspacesMock.mockClear()
    getWorkspacesItemsMock.mockClear()
    getTasksMock.mockClear()

    // Mock the column fetch so the kanban_columns are populated —
    // they're not strictly required for these tests but the store
    // may fetch them as part of init().
    vi.spyOn(api, 'getWorkspaces').mockImplementation(getWorkspacesMock)
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(getWorkspacesItemsMock)
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  // Helper: run init() with the given first-page result so the store
  // is in a "first page loaded" state. Returns the store + item.
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

  it('fetchKanbanTasks populates columnPagination for each column with tasks in the page', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [baseItem as any],
      },
    ]
    getTasksMock.mockResolvedValueOnce({
      tasks: [
        ...seedTasks(2, 'a', 'col_a'),
        ...seedTasks(2, 'b', 'col_b'),
      ],
      has_more: true,
      next_cursor: 'cursor_1',
    })

    await store.fetchKanbanTasks('ws_1', 'item_1a', 10, undefined, undefined)

    const item = store.workspaces[0]!.items[0]!
    expect(item.columnPagination).toBeDefined()
    expect(item.columnPagination!['col_a']).toBeDefined()
    expect(item.columnPagination!['col_b']).toBeDefined()
    expect(item.columnPagination!['col_a'].hasMore).toBe(true)
    expect(item.columnPagination!['col_b'].hasMore).toBe(true)
    expect(item.columnPagination!['col_a'].cursor).toBe('cursor_1')
    expect(item.columnPagination!['col_b'].cursor).toBe('cursor_1')
    expect(item.columnPagination!['col_a'].isLoading).toBe(false)
  })

  it('fetchKanbanTasks resets columnPagination (no stale cursors from a previous query)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [{ ...baseItem, columnPagination: { col_x: { cursor: 'old', hasMore: true, isLoading: false } } } as any],
      },
    ]

    // First fetch: 2 tasks in col_a only — col_a gets hasMore=true.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })
    await store.fetchKanbanTasks('ws_1', 'item_1a', 10, undefined, undefined)

    let item = store.workspaces[0]!.items[0]!
    expect(item.columnPagination!['col_a']).toBeDefined()
    expect(item.columnPagination!['col_x']).toBeUndefined() // stale from previous query — gone

    // Second fetch: 0 tasks in all columns (search returned nothing).
    getTasksMock.mockResolvedValueOnce({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })
    await store.fetchKanbanTasks('ws_1', 'item_1a', 10, undefined, undefined, 'name', 'asc')

    item = store.workspaces[0]!.items[0]!
    expect(item.columnPagination).toEqual({}) // empty map — no columns had tasks
  })

  it('loadMoreTasksForColumn calls api.getTasks with column_id=the column id', async () => {
    const store = await initWithFirstPage({
      tasks: [...seedTasks(2, 'a', 'col_a'), ...seedTasks(1, 'b', 'col_b')],
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    expect(getTasksMock).toHaveBeenCalledTimes(2)
    const lastCall = getTasksMock.mock.calls[1]!
    // Arg positions: workspaceId, itemId, limit, cursor, sortBy, direction, columnId, q
    expect(lastCall[0]).toBe('ws_1')
    expect(lastCall[1]).toBe('item_1a')
    expect(lastCall[2]).toBe(10) // PAGE_SIZE
    expect(lastCall[3]).toBe('cursor_1') // the previous next_cursor
    expect(lastCall[6]).toBe('col_a') // columnId — the new arg
  })

  it('loadMoreTasksForColumn appends returned tasks to item.tasks', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const item = store.workspaces[0]!.items[0]!
    expect(item.tasks).toHaveLength(4)
    expect(item.tasks!.map((t) => t.id)).toEqual(['a1', 'a2', 'a21', 'a22'])
  })

  it('loadMoreTasksForColumn updates columnPagination[col].cursor + .hasMore', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const item = store.workspaces[0]!.items[0]!
    expect(item.columnPagination!['col_a'].cursor).toBeNull()
    expect(item.columnPagination!['col_a'].hasMore).toBe(false)
    expect(item.columnPagination!['col_a'].isLoading).toBe(false)
  })

  it('loadMoreTasksForColumn is a no-op when hasMore=false (no second fetch)', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: false, // global: no more
      next_cursor: null,
    })

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    // Only the init fetch happened.
    expect(getTasksMock).toHaveBeenCalledTimes(1)
  })

  it('loadMoreTasksForColumn is a no-op while isLoading=true (no double-click)', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // Simulate an in-flight load.
    store.workspaces[0]!.items[0]!.columnPagination!['col_a'].isLoading = true

    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    expect(getTasksMock).toHaveBeenCalledTimes(1) // guard fired
  })

  it('loadMoreTasksForColumn forwards the per-item active sort (name + desc) on the API call', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // User picks 'name' / 'desc' on the kanban view. fetchKanbanTasks
    // records the active sort.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })
    await store.fetchKanbanTasks(
      'ws_1', 'item_1a', 10, undefined, undefined,
      'name', 'desc',
    )

    // User clicks "Load more" for col_a — must forward 'name' / 'desc'.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const lastCall = getTasksMock.mock.calls[2]!
    expect(lastCall[4]).toBe('name') // sortBy
    expect(lastCall[5]).toBe('desc') // direction
  })

  it('loadMoreTasksForColumn forwards the active q (search query) on the API call', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // User types 'login' in the search box. fetchKanbanTasks records it.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })
    await store.fetchKanbanTasks(
      'ws_1', 'item_1a', 10, undefined, 'login',
    )

    // User clicks "Load more" for col_a — must forward q='login'.
    getTasksMock.mockResolvedValueOnce({
      tasks: seedTasks(1, 'a2', 'col_a'),
      has_more: false,
      next_cursor: null,
    })
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const lastCall = getTasksMock.mock.calls[2]!
    expect(lastCall[7]).toBe('login') // q (search query) — the 8th arg
  })

  it('loadMoreTasksForColumn on error: leaves hasMore + cursor untouched (retry-by-click still works)', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    getTasksMock.mockRejectedValueOnce(new Error('network down'))
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_a')

    const item = store.workspaces[0]!.items[0]!
    // hasMore + cursor unchanged so the user can retry.
    expect(item.columnPagination!['col_a'].hasMore).toBe(true)
    expect(item.columnPagination!['col_a'].cursor).toBe('cursor_1')
    // isLoading flipped back to false (the catch block's finally resumes).
    expect(item.columnPagination!['col_a'].isLoading).toBe(false)
  })

  it('loadMoreTasksForColumn is a no-op when the column has no pagination state', async () => {
    const store = await initWithFirstPage({
      tasks: seedTasks(2, 'a', 'col_a'),
      has_more: true,
      next_cursor: 'cursor_1',
    })

    // col_unknown never appeared in the initial fetch — no pagination state.
    await store.loadMoreTasksForColumn('ws_1', 'item_1a', 'col_unknown')

    expect(getTasksMock).toHaveBeenCalledTimes(1) // guard fired
  })
})

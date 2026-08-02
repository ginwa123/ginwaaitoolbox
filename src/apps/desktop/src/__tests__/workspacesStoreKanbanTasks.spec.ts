/**
 * Tests for the workspacesStore.fetchKanbanTasks action (added by
 * docs/superpowers/plans/2026-06-27-kanban-sse-auto-move.md).
 *
 * Mirrors the existing fetchKanbanColumns test coverage in spirit:
 * the action is the bridge between the SSE event handler and the
 * Pinia store, so the contract being tested is "calling
 * fetchKanbanTasks replaces item.tasks with the backend's response".
 *
 * Mock pattern: vi.spyOn(api, 'getTasks') returns a stubbed
 * { tasks, has_more, next_cursor } shape. Tests assert the local
 * store's `item.tasks` array matches the API response.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import type { Task as ApiTask } from '../api'
import type { WorkspaceItem } from '../stores/workspaces'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_test'
const ITEM_ID = 'item_test'

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'Test Kanban',
  item_type: 'kanban',
  tasks: [],
  kanban_columns: [],
  ...overrides,
})

const makeTask = (overrides: Partial<ApiTask> = {}): ApiTask => ({
  id: 'task_1',
  name: 'Task 1',
  ...overrides,
})

describe('workspacesStore.fetchKanbanTasks', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('replaces item.tasks with the API response', async () => {
    const store = useWorkspacesStore()
    // Seed the store with the workspace + item.
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const freshTasks = [
      makeTask({ id: 'task_a', name: 'A', kanban_column_id: 'col_1', kanban_position: 0 }),
      makeTask({ id: 'task_b', name: 'B', kanban_column_id: 'col_1', kanban_position: 1 }),
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: freshTasks,
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    const item = store.workspaces[0]!.items[0]!
    expect(item.tasks).toEqual(freshTasks)
    // CONTRACT (Chunk 1 of kanban-lazy-load-tasks plan): fetchKanbanTasks
    // CONTRACT (kanban task search, Chunk 4): the 7-arg signature is
    // (workspaceId, itemId, limit, cursor, sortBy, direction, q). When
    // q is undefined, the helper layer (api.getTasks) omits the URL
    // param — server-side semantics: no filter.
    expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID, 10, undefined, undefined, undefined, undefined)
  })

  it('passes limit=10 on initial fetch (matches the page-size cap)', async () => {
    // CONTRACT: fetchKanbanTasks requests the standard page size of
    // 10 so the kanban view loads in the same-sized pages as the
    // "Load more" button. The backend's MAX_PAGE_SIZE in
    // tasks_list.zig is still 100; we use 10 to keep the
    // "Load more" affordance exercised on every kanban.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    expect(spy).toHaveBeenCalledTimes(1)
    const thirdArg = spy.mock.calls[0]![2]
    // Third arg is the `limit` parameter; must match loadMoreTasks'
    // page size so paginated pages and initial pages are uniform.
    expect(thirdArg).toBe(10)
  })

  it('does not pass a cursor on initial fetch', async () => {
    // CONTRACT (Chunk 1 of kanban-lazy-load-tasks plan):
    // fetchKanbanTasks is the INITIAL fetch — it MUST NOT carry a
    // cursor. Only loadMoreTasks passes a cursor (for pagination).
    // Regression guard: a future refactor that threads the cursor
    // through unconditionally would re-fetch the same page on every
    // SSE event instead of replacing the first page.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    expect(spy.mock.calls[0]?.[3]).toBeUndefined() // cursor = undefined (index 3)
    expect(spy.mock.calls[0]?.[4]).toBeUndefined() // sortBy (default back-compat — api layer applies 'updated_at')
    expect(spy.mock.calls[0]?.[5]).toBeUndefined() // direction (default back-compat — api layer applies 'desc')
    expect(spy.mock.calls[0]?.[6]).toBeUndefined() // q = undefined
  })

  it('is a no-op when the item is not found locally', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [] // empty store
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    // getTasks is never called — short-circuit before the HTTP request.
    expect(spy).not.toHaveBeenCalled()
  })

  it('leaves the previous tasks array untouched when the API fails', async () => {
    const store = useWorkspacesStore()
    const existingTask = makeTask({ id: 'task_old', name: 'Old' })
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [makeItem({ tasks: [existingTask] })],
      },
    ]
    vi.spyOn(api, 'getTasks').mockRejectedValue(new Error('network down'))

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    const item = store.workspaces[0]!.items[0]!
    // Silent failure: the old tasks array is preserved so the UI
    // doesn't flash to empty on a transient network blip. The next
    // SSE event will trigger another fetch.
    expect(item.tasks).toEqual([existingTask])
  })

  it('passes through pagination fields (has_more, next_cursor) to the item', async () => {
    // Mirrors the loadMoreTasks action's pattern (workspaces.ts:1051-1083):
    // the item has hasMoreTasks + tasksNextCursor fields that the
    // folder-list view uses to render the "Load more" button. We don't
    // expect kanban-view to render that button today, but the fields
    // must be set for consistency.
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [makeTask()],
      has_more: true,
      next_cursor: 'cursor_abc',
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID)

    const item = store.workspaces[0]!.items[0]!
    expect(item.hasMoreTasks).toBe(true)
    expect(item.tasksNextCursor).toBe('cursor_abc')
  })
})

/**
 * Tests for the kanban task search feature (Chunk 4 of plan
 * docs/superpowers/plans/2026-07-30-kanban-task-search.md).
 *
 * The store forwards `q` to api.getTasks AND tracks the active q
 * in `activeSearchQueries` so loadMoreTasks + SSE handlers can read
 * it. Empty / undefined q clears the map entry (no filter).
 */
describe('workspacesStore.fetchKanbanTasks with q (kanban task search)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('forwards q to api.getTasks when q is non-empty', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, 'design')

    expect(spy).toHaveBeenCalledWith(WS_ID, ITEM_ID, 100, undefined, undefined, undefined, 'design')
  })

  it('forwards q=undefined when search is cleared', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, undefined)

    expect(spy.mock.calls[0]?.[6]).toBeUndefined() // q = undefined
  })

  it('records active q in activeSearchQueries after fetch', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, 'design')

    expect(store.activeSearchQueries.get(ITEM_ID)).toBe('design')
  })

  it('removes active q from activeSearchQueries when q is undefined', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    // First: set an active q
    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, 'design')
    expect(store.activeSearchQueries.has(ITEM_ID)).toBe(true)

    // Then: clear it
    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, undefined)
    expect(store.activeSearchQueries.has(ITEM_ID)).toBe(false)
  })

  it('removes active q from activeSearchQueries when q is empty string', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'ws', icon: '📁', expanded: false, items: [makeItem()] },
    ]
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, 'design')
    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, '')
    expect(store.activeSearchQueries.has(ITEM_ID)).toBe(false)
  })

  it('loadMoreTasks forwards the per-item active q', async () => {
    const store = useWorkspacesStore()
    // Seed the store with an item that has hasMoreTasks + cursor set
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [makeItem({
          hasMoreTasks: true,
          tasksNextCursor: 'cursor_1',
        })],
      },
    ]
    // First call (from fetchKanbanTasks with q='design'): keep
    // hasMoreTasks=true so loadMoreTasks doesn't bail out. Second
    // call (from loadMoreTasks): return the next page.
    const spy = vi.spyOn(api, 'getTasks')
      .mockResolvedValueOnce({
        tasks: [makeTask({ id: 'task_1', name: 'first page' })],
        has_more: true,
        next_cursor: 'cursor_1',
      })
      .mockResolvedValueOnce({
        tasks: [makeTask({ id: 'task_2', name: 'second page' })],
        has_more: false,
        next_cursor: null,
      })

    // First: set the active q via fetchKanbanTasks
    await store.fetchKanbanTasks(WS_ID, ITEM_ID, 100, undefined, 'design')
    // (hasMoreTasks stays true because the first mock kept it true.)

    // Then: click "Load more" — should forward the stored q
    await store.loadMoreTasks(WS_ID, ITEM_ID)

    // The second mockResolvedValueOnce is what loadMoreTasks consumed.
    const loadMoreCall = spy.mock.calls[1]!
    expect(loadMoreCall[0]).toBe(WS_ID)
    expect(loadMoreCall[1]).toBe(ITEM_ID)
    expect(loadMoreCall[3]).toBe('cursor_1') // cursor forwarded
    expect(loadMoreCall[6]).toBe('design') // q forwarded
  })

  it('loadMoreTasks forwards q=undefined when no search is active', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
        name: 'ws',
        icon: '📁',
        expanded: false,
        items: [makeItem({ hasMoreTasks: true, tasksNextCursor: 'cursor_1' })],
      },
    ]
    const spy = vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    await store.loadMoreTasks(WS_ID, ITEM_ID)

    expect(spy.mock.calls[0]?.[6]).toBeUndefined()
  })
})

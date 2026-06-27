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
    expect(api.getTasks).toHaveBeenCalledWith(WS_ID, ITEM_ID)
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

/**
 * Unit tests for the kanban store actions (Chunk 5 of the
 * workspace-item-kanban plan): addKanbanItem, addKanbanColumn,
 * updateKanbanColumn, deleteKanbanColumn, moveTaskToColumn.
 *
 * Each action is mocked at the api.* boundary (the apiFetch
 * wrappers in api/index.ts) and the test asserts that the
 * store's local state is updated correctly. Mirrors the
 * workspacesStoreTaskTypes.spec.ts pattern: a top-level
 * `seedStore()` helper, vi.spyOn(api, ...) per action, and
 * `setActivePinia(createPinia())` in beforeEach.
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 5 / Task 5.1
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import {
  useWorkspacesStore,
  type KanbanColumn,
  type Task,
  type Workspace,
  type WorkspaceItem,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ws = (id: string, name: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: true,
  items,
})

const item = (
  id: string,
  name: string,
  itemType: string = 'folder',
  extras: Partial<WorkspaceItem> = {},
): WorkspaceItem => ({
  id,
  name,
  item_type: itemType,
  ...extras,
})

const column = (
  id: string,
  name: string,
  position: number,
  workspaceItemId: string = 'item_1',
): KanbanColumn => ({
  id,
  workspace_item_id: workspaceItemId,
  name,
  position,
  created_at: '2026-06-21 12:00:00',
})

const task = (
  id: string,
  name: string,
  extras: Partial<Task> = {},
): Task => ({
  id,
  name,
  ...extras,
})

describe('useWorkspacesStore — kanban actions', () => {
  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    // init()'s other API calls — defensive in case a future test
    // triggers it. Same defensive pattern as workspacesStoreTaskTypes.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seedStore(seedWs: Workspace[] = [ws('ws_1', 'W1')]) {
    const store = useWorkspacesStore()
    store.workspaces.splice(0, store.workspaces.length, ...seedWs)
    return store
  }

  // ─── addKanbanItem ──────────────────────────────────────────────────────

  describe('addKanbanItem', () => {
    it('calls api.createKanban and pushes the new item with its columns into the workspace', async () => {
      const store = seedStore()
      const createKanbanMock = vi
        .spyOn(api, 'createKanban')
        .mockResolvedValue({
          item: {
            id: 'kanban_1',
            item_type: 'kanban',
            name: 'My Sprint',
          },
          columns: [
            column('c1', 'todo', 0, 'kanban_1'),
            column('c2', 'in progress', 1, 'kanban_1'),
            column('c3', 'done', 2, 'kanban_1'),
          ],
        })

      const id = await store.addKanbanItem('ws_1', 'My Sprint')

      expect(id).toBe('kanban_1')
      expect(createKanbanMock).toHaveBeenCalledWith('ws_1', 'My Sprint')

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      expect(wsRow.items).toHaveLength(1)
      const newItem = wsRow.items[0]!
      expect(newItem.id).toBe('kanban_1')
      expect(newItem.name).toBe('My Sprint')
      expect(newItem.item_type).toBe('kanban')
      expect(newItem.tasks).toEqual([])
      expect(newItem.kanban_columns).toHaveLength(3)
      expect(newItem.kanban_columns?.map((c) => c.name)).toEqual([
        'todo',
        'in progress',
        'done',
      ])
    })

    it('returns undefined and leaves state untouched when the API call fails', async () => {
      const store = seedStore()
      vi.spyOn(api, 'createKanban').mockRejectedValue(new Error('HTTP 500'))
      // Spy on console.error to silence the expected error log.
      const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

      const id = await store.addKanbanItem('ws_1', 'My Sprint')

      expect(id).toBeUndefined()
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      expect(wsRow.items).toHaveLength(0)
      expect(errorSpy).toHaveBeenCalled()
      errorSpy.mockRestore()
    })
  })

  // ─── addKanbanColumn ────────────────────────────────────────────────────

  describe('addKanbanColumn', () => {
    it('calls api.addKanbanColumn and appends the new column sorted by position', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c3', 'done', 2, 'item_1'),
            ],
          }),
        ]),
      ])
      const addKanbanColumnMock = vi
        .spyOn(api, 'addKanbanColumn')
        .mockResolvedValue(column('c2', 'in progress', 1, 'item_1'))

      await store.addKanbanColumn('ws_1', 'item_1', 'in progress')

      expect(addKanbanColumnMock).toHaveBeenCalledWith('ws_1', 'item_1', 'in progress')
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual(['c1', 'c2', 'c3'])
    })

    it('creates kanban_columns array when the item did not have one (defensive)', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [item('item_1', 'Sprint', 'kanban')]),
      ])
      vi.spyOn(api, 'addKanbanColumn').mockResolvedValue(column('c1', 'todo', 0, 'item_1'))

      await store.addKanbanColumn('ws_1', 'item_1', 'todo')

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns).toHaveLength(1)
      expect(updatedItem.kanban_columns?.[0]?.name).toBe('todo')
    })
  })

  // ─── updateKanbanColumn ────────────────────────────────────────────────

  describe('updateKanbanColumn', () => {
    it('calls api.updateKanbanColumn and replaces the column in the local array', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
            ],
          }),
        ]),
      ])
      const updateKanbanColumnMock = vi
        .spyOn(api, 'updateKanbanColumn')
        .mockResolvedValue(column('c1', 'backlog', 0, 'item_1'))

      await store.updateKanbanColumn('ws_1', 'item_1', 'c1', { name: 'backlog' })

      expect(updateKanbanColumnMock).toHaveBeenCalledWith('ws_1', 'item_1', 'c1', {
        name: 'backlog',
      })
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      const c1 = updatedItem.kanban_columns?.find((c) => c.id === 'c1')
      expect(c1?.name).toBe('backlog')
      // Sibling column is untouched.
      const c2 = updatedItem.kanban_columns?.find((c) => c.id === 'c2')
      expect(c2?.name).toBe('in progress')
    })
  })

  // ─── deleteKanbanColumn ─────────────────────────────────────────────────

  describe('deleteKanbanColumn', () => {
    it('calls api.deleteKanbanColumn, removes the column, and unassigns tasks in that column', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
            ],
            tasks: [
              task('t1', 'Task A', { kanban_column_id: 'c1', kanban_position: 0 }),
              task('t2', 'Task B', { kanban_column_id: 'c2', kanban_position: 0 }),
              task('t3', 'Task C', { kanban_column_id: 'c1', kanban_position: 1 }),
            ],
          }),
        ]),
      ])
      const deleteKanbanColumnMock = vi
        .spyOn(api, 'deleteKanbanColumn')
        .mockResolvedValue({ success: true })

      await store.deleteKanbanColumn('ws_1', 'item_1', 'c1')

      expect(deleteKanbanColumnMock).toHaveBeenCalledWith('ws_1', 'item_1', 'c1')
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      // Column c1 is gone.
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual(['c2'])
      // Tasks that were in c1 are unassigned (null).
      const t1 = updatedItem.tasks?.find((t) => t.id === 't1')
      expect(t1?.kanban_column_id).toBeNull()
      const t3 = updatedItem.tasks?.find((t) => t.id === 't3')
      expect(t3?.kanban_column_id).toBeNull()
      // Task in the other column is untouched.
      const t2 = updatedItem.tasks?.find((t) => t.id === 't2')
      expect(t2?.kanban_column_id).toBe('c2')
    })
  })

  // ─── moveTaskToColumn ───────────────────────────────────────────────────

  describe('moveTaskToColumn', () => {
    it('calls api.moveTask and updates the local task\'s kanban_column_id and kanban_position', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
            ],
            tasks: [
              task('t1', 'Task A', { kanban_column_id: 'c1', kanban_position: 0 }),
            ],
          }),
        ]),
      ])
      const moveTaskMock = vi.spyOn(api, 'moveTask').mockResolvedValue({
        id: 't1',
        name: 'Task A',
        kanban_column_id: 'c2',
        kanban_position: 1,
      })

      await store.moveTaskToColumn('ws_1', 'item_1', 't1', 'c2', 1)

      expect(moveTaskMock).toHaveBeenCalledWith('ws_1', 'item_1', 't1', 'c2', 1)
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      const t1 = updatedItem.tasks?.find((t) => t.id === 't1')
      expect(t1?.kanban_column_id).toBe('c2')
      expect(t1?.kanban_position).toBe(1)
    })
  })
})

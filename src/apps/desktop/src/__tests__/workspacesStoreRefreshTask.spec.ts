/**
 * Unit tests for the workspaces store's `refreshTask` action.
 *
 * `refreshTask` is called from KanbanView.handleViewTaskDetail so the
 * Task details dialog opens with the LIVE `is_auto_retry_until_stop`
 * value (which lives on sessions, joined at read time) rather than
 * the value cached at workspaces store init() time. The action re-
 * fetches the parent item's task list via `api.getTasks` and patches
 * the matching task object in place — the dialog's watcher re-derives
 * its local form state from the new task via the `[show, task?.id,
 * mode]` dependency, so the toggle reflects the live DB value.
 *
 * Behaviors under test:
 *  1. Replaces the cached task with the fresh one (including the
 *     `is_auto_retry_until_stop` field that motivated this action).
 *  2. Is a no-op if the task is not present in the fresh list
 *     (e.g. server-side deletion raced with our dialog open).
 *  3. Does NOT throw on API failure — the dialog should still open
 *     with the cached value. The failure is logged but suppressed.
 *
 * Plan: docs/superpowers/plans/2026-07-17-frontend-error-logs.md
 *   (the original fix that exposed the JOIN-on-sessions gap).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.refreshTask', () => {
  const getTasksMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
    // init() never runs in these tests, but stub defensively.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    getTasksMock.mockReset()
  })

  // Seed the store with one workspace / one item / one task so we
  // can test the in-place replacement. Skipping init() keeps the
  // tests focused on refreshTask's read-then-patch logic.
  function seedStore(opts: {
    taskId: string
    cachedUnattended: '0' | '1'
    cachedName?: string
  }) {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'Test workspace',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: 'item_1',

            item_type: 'kanban',
            name: 'Sprint 2',
            path: '',
            tasks: [
              {
                id: opts.taskId,
                name: opts.cachedName ?? 'Cached name',
                description: '',
                is_auto_retry_until_stop: opts.cachedUnattended,
              },
            ],
          },
        ],
      },
    ]
  }

  it('patches the cached task with the fresh one (including is_auto_retry_until_stop)', async () => {
    seedStore({ taskId: 'task_x', cachedUnattended: '0' })
    getTasksMock.mockResolvedValue({
      tasks: [
        {
          id: 'task_x',
          name: 'Fresh name from server',

          description: 'Fresh description',
          is_auto_retry_until_stop: '1',
        },
      ],
      has_more: false,
      next_cursor: null,
    })

    const ws = useWorkspacesStore()
    await ws.refreshTask('ws_1', 'item_1', 'task_x')

    const task = ws.workspaces[0]!.items[0]!.tasks![0]!
    expect(task.id).toBe('task_x')
    expect(task.name).toBe('Fresh name from server')
    expect(task.description).toBe('Fresh description')
    expect(task.is_auto_retry_until_stop).toBe('1')
  })

  it('flips the toggle from OFF to ON when the server has it ON', async () => {
    // This is the exact bug the user reported: cached value says
    // OFF, server has ON, the dialog must show ON after refresh.
    seedStore({ taskId: 'task_x', cachedUnattended: '0' })
    getTasksMock.mockResolvedValue({
      tasks: [
        {
          id: 'task_x',
          name: 'Cached name',

          description: '',
          is_auto_retry_until_stop: '1',
        },
      ],
      has_more: false,
      next_cursor: null,
    })

    const ws = useWorkspacesStore()
    await ws.refreshTask('ws_1', 'item_1', 'task_x')

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.is_auto_retry_until_stop).toBe('1')
  })

  it('is a no-op if the fresh list does not include the task (race with deletion)', async () => {
    seedStore({ taskId: 'task_x', cachedUnattended: '0', cachedName: 'Original name' })
    getTasksMock.mockResolvedValue({
      tasks: [], // task was deleted server-side between open and fetch
      has_more: false,
      next_cursor: null,
    })

    const ws = useWorkspacesStore()
    await ws.refreshTask('ws_1', 'item_1', 'task_x')

    // Cached task is unchanged (preserved, not deleted) — the dialog
    // can still display it. The eventual delete-event SSE handler
    // will remove the task from the store on the next round trip.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original name')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.is_auto_retry_until_stop).toBe('0')
  })

  it('does NOT throw on API failure (dialog falls back to cached value)', async () => {
    seedStore({ taskId: 'task_x', cachedUnattended: '1' })
    getTasksMock.mockRejectedValue(new Error('network down'))

    const ws = useWorkspacesStore()
    // No throw — the dialog must still open even when the fetch fails.
    await expect(ws.refreshTask('ws_1', 'item_1', 'task_x')).resolves.toBeUndefined()

    // Cached task unchanged; failure is logged via console.warn.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.is_auto_retry_until_stop).toBe('1')
    // We don't assert on console.warn here — vi.restoreAllMocks() in
    // afterEach would reset a module-level spy. The "does not throw"
    // promise is the contract that matters for the dialog UX; the
    // log line is incidental observability.
  })

  it('only patches the task whose id matches (does not touch sibling tasks)', async () => {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'Test workspace',
        icon: '📁',
        expanded: false,
        items: [
          {
            id: 'item_1',

            item_type: 'kanban',
            name: 'Sprint 2',
            path: '',
            tasks: [
              { id: 'task_a', name: 'A cached', is_auto_retry_until_stop: '0' },
              { id: 'task_b', name: 'B cached', is_auto_retry_until_stop: '0' },
            ],
          },
        ],
      },
    ]
    getTasksMock.mockResolvedValue({
      tasks: [
        { id: 'task_a', name: 'A fresh', is_auto_retry_until_stop: '1' },
        // task_b deliberately omitted (e.g. hidden by another tab's
        // mutation, or the response was capped at 1 row).
      ],
      has_more: false,
      next_cursor: null,
    })

    await ws.refreshTask('ws_1', 'item_1', 'task_a')

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks[0]!.name).toBe('A fresh')
    expect(tasks[0]!.is_auto_retry_until_stop).toBe('1')
    // task_b is preserved (untouched).
    expect(tasks[1]!.name).toBe('B cached')
    expect(tasks[1]!.is_auto_retry_until_stop).toBe('0')
  })

  it('is a no-op when the workspace_id does not match any cached workspace', async () => {
    seedStore({ taskId: 'task_x', cachedUnattended: '0' })
    getTasksMock.mockResolvedValue({
      tasks: [{ id: 'task_x', name: 'Fresh', is_auto_retry_until_stop: '1' }],
      has_more: false,
      next_cursor: null,
    })

    const ws = useWorkspacesStore()
    // Different workspaceId — store has only ws_1.
    await ws.refreshTask('ws_does_not_exist', 'item_1', 'task_x')

    // Cached task unchanged.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Cached name')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.is_auto_retry_until_stop).toBe('0')
  })
})
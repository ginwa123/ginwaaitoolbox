/**
 * Tests for the Task interface extension (Chunk 5 of the task-routines
 * plan): `task_type` + `routine` fields, the new `addTask` params
 * signature, and the `runRoutine` + `updateRoutine` store actions.
 *
 * The `task_type` and `routine` fields are additive (optional on the
 * `Task` interface), so legacy task literals without them keep
 * type-checking. The new `addTask` action accepts a single params
 * object instead of `(name, description?)` and passes `taskType` +
 * `routine` through to `api.createTask`. `runRoutine` calls
 * `api.runRoutine` and returns the `{ session_id }`; `updateRoutine`
 * forwards routine fields to `api.updateTaskSimple` and updates the
 * local task name optimistically.
 *
 * Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-5.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.addTask — routine support', () => {
  const createTaskMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    vi.spyOn(api, 'createTask').mockImplementation(createTaskMock)
    // init()'s other API calls — defensive in case a future test triggers it.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    createTaskMock.mockReset()
  })

  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          { id: 'item_a', name: 'A', item_type: 'folder', tasks: [] },
        ],
      },
    ]
    return ws
  }

  it('passes taskType="routine" + routine fields through to api.createTask for a routine task', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({
      id: 'task_routine_1',
      name: 'Daily standup',
      task_type: 'routine',
      routine: {
        schedule: '0 9 * * 1-5',
        initial_prompt: 'summarize commits',
        enabled: true,
        last_run_at: null,
        next_run_at: '2099-01-01 09:00:00',
        last_status: null,
        last_error: null,
      },
    })

    const routine = {
      schedule: '0 9 * * 1-5',
      initial_prompt: 'summarize commits',
      enabled: true,
    }
    const taskId = await ws.addTask('ws_1', 'item_a', {
      name: 'Daily standup',
      taskType: 'routine',
      routine,
    })

    expect(taskId).toBe('task_routine_1')
    expect(createTaskMock).toHaveBeenCalledTimes(1)
    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Daily standup',
      description: undefined,
      taskType: 'routine',
      routine,
    })
    // The returned task is unshifted into the item's task list.
    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.task_type).toBe('routine')
    expect(tasks[0]!.routine?.schedule).toBe('0 9 * * 1-5')
  })

  it('passes taskType="standard" through for a standard task (default path)', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({
      id: 'task_std_1',
      name: 'Quick chat',
      task_type: 'standard',
    })

    await ws.addTask('ws_1', 'item_a', {
      name: 'Quick chat',
      description: 'a quick test',
      taskType: 'standard',
    })

    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Quick chat',
      description: 'a quick test',
      taskType: 'standard',
      routine: undefined,
    })
  })

  it('defaults taskType to "standard" when omitted (backwards-compat with existing call sites)', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({ id: 'task_std_2', name: 'Old way', task_type: 'standard' })

    // Existing call sites pass {name, description} and rely on the
    // legacy signature. The modified signature must accept this
    // shape and forward taskType: 'standard' + routine: undefined.
    await ws.addTask('ws_1', 'item_a', {
      name: 'Old way',
      description: 'legacy call',
    })

    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Old way',
      description: 'legacy call',
      taskType: 'standard',
      routine: undefined,
    })
  })

  it('falls back to a local-only task if the API call fails (preserves the legacy fallback contract)', async () => {
    const ws = seedStore()
    createTaskMock.mockRejectedValueOnce(new Error('network down'))

    const taskId = await ws.addTask('ws_1', 'item_a', {
      name: 'Offline',
      taskType: 'routine',
      routine: { schedule: '*/5 * * * *', initial_prompt: 'x', enabled: true },
    })

    expect(taskId).toBeDefined()
    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    // The fallback task has task_type: 'routine' + routine fields
    // so the UI still works offline.
    expect(tasks[0]!.task_type).toBe('routine')
    expect(tasks[0]!.routine?.schedule).toBe('*/5 * * * *')
  })
})

describe('useWorkspacesStore.runRoutine', () => {
  const runRoutineApiMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'runRoutine').mockImplementation(runRoutineApiMock)
    vi.spyOn(api, 'createTask').mockResolvedValue({
      id: 'task_1',
      name: 'Daily',
      task_type: 'routine',
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    runRoutineApiMock.mockReset()
  })

  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_a',
            name: 'A',
            item_type: 'folder',
            tasks: [{ id: 'task_routine_1', name: 'Daily', task_type: 'routine' }],
          },
        ],
      },
    ]
    return ws
  }

  it('calls api.runRoutine with (workspaceId, itemId, taskId) and returns the session_id', async () => {
    const ws = seedStore()
    runRoutineApiMock.mockResolvedValueOnce({ session_id: 'task_routine_1' })

    const result = await ws.runRoutine('ws_1', 'item_a', 'task_routine_1')

    expect(runRoutineApiMock).toHaveBeenCalledWith('ws_1', 'item_a', 'task_routine_1')
    expect(result).toEqual({ session_id: 'task_routine_1' })
  })

  it('returns undefined (does not throw) if the API call fails — the caller (Sidebar) handles the error toast', async () => {
    const ws = seedStore()
    runRoutineApiMock.mockRejectedValueOnce(new Error('409 conflict'))

    // We don't want a console.error to fail the test; silence it.
    const consoleErrSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const result = await ws.runRoutine('ws_1', 'item_a', 'task_routine_1')
    consoleErrSpy.mockRestore()

    expect(result).toBeUndefined()
  })
})

describe('useWorkspacesStore.updateRoutine', () => {
  const updateTaskSimpleMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'updateTaskSimple').mockImplementation(updateTaskSimpleMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    updateTaskSimpleMock.mockReset()
  })

  function seedStore(taskName: string) {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_a',
            name: 'A',
            item_type: 'folder',
            tasks: [{ id: 'task_r_1', name: taskName, task_type: 'routine' }],
          },
        ],
      },
    ]
    return ws
  }

  it('forwards routine fields + name through to api.updateTaskSimple', async () => {
    const ws = seedStore('Old')
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateRoutine('ws_1', 'item_a', 'task_r_1', {
      name: 'New name',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'updated prompt',
      enabled: false,
    })

    expect(updateTaskSimpleMock).toHaveBeenCalledTimes(1)
    expect(updateTaskSimpleMock).toHaveBeenCalledWith('task_r_1', {
      name: 'New name',
      schedule: '0 10 * * 1-5',
      initial_prompt: 'updated prompt',
      enabled: false,
    })
  })

  it('updates the task name optimistically in the local tree', async () => {
    const ws = seedStore('Old')
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateRoutine('ws_1', 'item_a', 'task_r_1', { name: 'Renamed' })
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Renamed')
  })
})

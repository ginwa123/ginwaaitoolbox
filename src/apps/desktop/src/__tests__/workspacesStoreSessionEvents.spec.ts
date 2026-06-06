/**
 * Tests for the workspaces store's session-events SSE subscription.
 *
 * The backend cascade for task rename emits a `session.updated`
 * event on /api/sessions/stream. The workspaces store subscribes
 * so the workspace-item task row updates in real time (without
 * this, the user has to refresh the page to see the new name in
 * the task list, even though the ChatsList updates correctly
 * because it has its own subscription).
 *
 * task.id == session_id (per AppLayout.vue:651
 * `:chat-id="activeTask.id"`), so the lookup is a straight
 * equality match on task.id.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.subscribeToSessionEvents', () => {
  // The SseClient factory returns this stub. We capture the
  // onEvent callback so tests can simulate SSE events by invoking
  // it directly.
  let onEventCallback: ((event: api.SessionEvent) => void) | null = null
  const sseClientStub: Partial<api.SseClient> = {
    close: vi.fn(),
  }

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    // Replace the SSE factory with a stub that records the
    // onEvent callback. We deliberately ignore onError / onConnected
    // because the subscription handler doesn't depend on them.
    vi.spyOn(api, 'createSessionsSseConnection').mockImplementation(
      (
        onEvent: (event: api.SessionEvent) => void,
        _onError?: (error: Event) => void,
        _onConnected?: () => void,
      ): api.SseClient => {
        onEventCallback = onEvent
        return sseClientStub as api.SseClient
      },
    )
  })

  afterEach(() => {
    vi.restoreAllMocks()
    onEventCallback = null
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
            tasks: [{ id: 'task_1', name: 'Original' }],
          },
        ],
      },
    ]
    return ws
  }

  function dispatch(event: api.SessionEvent) {
    expect(onEventCallback).not.toBeNull()
    onEventCallback!(event)
  }

  it('opens an SSE connection when subscribeToSessionEvents is called', () => {
    const ws = useWorkspacesStore()
    ws.subscribeToSessionEvents()
    expect(api.createSessionsSseConnection).toHaveBeenCalledTimes(1)
  })

  it('is idempotent — calling subscribe twice does not open a second connection', () => {
    const ws = useWorkspacesStore()
    ws.subscribeToSessionEvents()
    ws.subscribeToSessionEvents()
    expect(api.createSessionsSseConnection).toHaveBeenCalledTimes(1)
  })

  it('updates a matching task name on session.updated', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New Name from SSE',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('New Name from SSE')
  })

  it('keeps navigationStore.activeChatName in sync when the updated task is the active one', () => {
    const ws = seedStore()
    const nav = useNavigationStore()
    ws.setActiveTask('task_1')
    nav.setActiveChatName('Original')
    ws.subscribeToSessionEvents()

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'Renamed via SSE',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(nav.activeChatName).toBe('Renamed via SSE')
  })

  it('does NOT touch navigationStore when the updated task is not the active one', () => {
    const ws = seedStore()
    const nav = useNavigationStore()
    ws.setActiveTask('other_task')
    nav.setActiveChatName('Other Task Header')
    ws.subscribeToSessionEvents()

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'Renamed via SSE',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    // Active header stays put.
    expect(nav.activeChatName).toBe('Other Task Header')
  })

  it('leaves the task name unchanged when no task matches the event id', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    dispatch({
      action: 'updated',
      id: 'nonexistent_task',
      name: 'Irrelevant',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
  })

  it('removes a task on session.deleted', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    expect(ws.workspaces[0]!.items[0]!.tasks).toHaveLength(1)
    dispatch({
      action: 'deleted',
      id: 'task_1',
      name: '',
      status: '',
      cwd: '',
      created_at: '',
      updated_at: '',
    })
    expect(ws.workspaces[0]!.items[0]!.tasks).toHaveLength(0)
  })

  it('clears activeTaskId when the deleted task was active', () => {
    const ws = seedStore()
    ws.setActiveTask('task_1')
    ws.subscribeToSessionEvents()

    dispatch({
      action: 'deleted',
      id: 'task_1',
      name: '',
      status: '',
      cwd: '',
      created_at: '',
      updated_at: '',
    })
    expect(ws.activeTaskId).toBeNull()
  })
})

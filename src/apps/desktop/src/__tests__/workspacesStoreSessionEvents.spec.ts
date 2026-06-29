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
  // The unified factory takes a single options object. We capture
  // it so tests can simulate SSE events by invoking the `sessions`
  // channel callback directly (`capturedOpts!.channels.sessions!(event)`).
  let capturedOpts: api.UnifiedSseOptions | undefined
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

    // Replace the unified SSE factory with a stub that records the
    // captured options object. The `sessions` channel callback is
    // the only one the subscription handler depends on.
    vi.spyOn(api, 'createUnifiedSseConnection').mockImplementation(
      (opts: api.UnifiedSseOptions): api.SseClient => {
        capturedOpts = opts
        return sseClientStub as api.SseClient
      },
    )
  })

  afterEach(() => {
    vi.restoreAllMocks()
    capturedOpts = undefined
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
    expect(capturedOpts).toBeDefined()
    const onSession = capturedOpts!.channels.sessions
    expect(onSession).toBeDefined()
    onSession!(event)
  }

  it('opens an SSE connection when subscribeToSessionEvents is called', () => {
    const ws = useWorkspacesStore()
    ws.subscribeToSessionEvents()
    expect(api.createUnifiedSseConnection).toHaveBeenCalledTimes(1)
  })

  it('is idempotent — calling subscribe twice does not open a second connection', () => {
    const ws = useWorkspacesStore()
    ws.subscribeToSessionEvents()
    ws.subscribeToSessionEvents()
    expect(api.createUnifiedSseConnection).toHaveBeenCalledTimes(1)
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

  // ─── onSessionEvent fan-out (ChatsList regression fix) ───────────────────
  //
  // The internal handler mutates workspace tree state. External
  // components (ChatsList.vue's `navItems` mirror) need to be
  // notified too — they have their own shape (relativeTime,
  // processing flag, etc.) that's not derived from the workspace
  // tree. The fan-out fires AFTER the internal handler so
  // subscribers can safely re-fetch from the API.
  it('fan-outs session.updated events to onSessionEvent subscribers', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    const cb = vi.fn()
    const unsub = ws.onSessionEvent(cb)

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New Name',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'updated', id: 'task_1', name: 'New Name' }),
    )

    unsub()
  })

  it('fan-outs session.deleted events to onSessionEvent subscribers', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    const cb = vi.fn()
    ws.onSessionEvent(cb)

    dispatch({
      action: 'deleted',
      id: 'task_1',
      name: '',
      status: '',
      cwd: '',
      created_at: '',
      updated_at: '',
    })

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(expect.objectContaining({ action: 'deleted', id: 'task_1' }))
  })

  it('fan-outs session.created events to onSessionEvent subscribers', () => {
    // The internal handler deliberately ignores 'created' (tasks
    // are created via POST /tasks, not via session.created) — but
    // external subscribers like ChatsList still need to see the
    // event so the new session appears in their list.
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    const cb = vi.fn()
    ws.onSessionEvent(cb)

    dispatch({
      action: 'created',
      id: 'task_new',
      name: 'Brand New Session',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-01T00:00:00Z',
    })

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'created', id: 'task_new' }),
    )
  })

  it('onSessionEvent returns an unsubscribe function that detaches the callback', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    const cb = vi.fn()
    const unsub = ws.onSessionEvent(cb)
    unsub()

    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    expect(cb).not.toHaveBeenCalled()
  })

  it('swallows errors thrown by subscribers without breaking the SSE stream', () => {
    const ws = seedStore()
    ws.subscribeToSessionEvents()

    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const goodCb = vi.fn()
    ws.onSessionEvent(() => {
      throw new Error('subscriber bug')
    })
    ws.onSessionEvent(goodCb)

    // Should NOT throw out of the dispatch path.
    dispatch({
      action: 'updated',
      id: 'task_1',
      name: 'New',
      status: 'active',
      cwd: '/tmp',
      created_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-02T00:00:00Z',
    })

    // Both subscribers got called (the throwing one threw, was
    // caught + logged, and the next subscriber still ran).
    expect(consoleSpy).toHaveBeenCalled()
    expect(goodCb).toHaveBeenCalledTimes(1)
    consoleSpy.mockRestore()
  })
})

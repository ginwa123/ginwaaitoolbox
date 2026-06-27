/**
 * Unit tests for the kanbanSse Pinia store (Chunk 4 of
 * docs/superpowers/plans/2026-06-26-fix-kanban-list-empty-add-sse.md).
 *
 * The store owns ONE kanban SSE connection for the app's lifetime,
 * mirroring the workersSse pattern in App.vue. Tests verify:
 *   - initKanbanSse opens a connection via createKanbanSseConnection
 *   - subsequent initKanbanSse calls tear down + reopen (no stacking)
 *   - closeKanbanSse tears down the connection
 *   - workspace filter: events for other workspaces are dropped
 *   - kanban_column / kanban_task events both trigger
 *     workspacesStore.fetchKanbanColumns
 *
 * Mock pattern: vi.spyOn(api, 'createKanbanSseConnection') captures
 * the onEvent callback so tests can simulate SSE events by invoking
 * it directly. The factory now uses the 3-callback positional API
 * (onEvent, onError, onConnected) — matching createWorkersSseConnection.
 * Each test runs in isolation: beforeEach installs a fresh Pinia
 * instance and resets the mock capture arrays, so connections from
 * prior tests don't leak.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import type { KanbanColumnEvent, KanbanTaskEvent } from '../api'
import { useKanbanSseStore } from '../stores/kanbanSse'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

describe('useKanbanSseStore', () => {
  // Captured by the mock below. Tests invoke `dispatch(...)` to
  // simulate an SSE event arriving on the connection.
  let onEventCallback:
    | ((event: KanbanColumnEvent | KanbanTaskEvent) => void)
    | null = null
  let sseClientStub: Partial<api.SseClient>

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Fresh stub per test — `close` is a fresh vi.fn so call counts
    // don't leak across tests (the prior test's close would otherwise
    // be reflected in the next test's assertion).
    sseClientStub = { close: vi.fn() }
    onEventCallback = null

    // Replace the SSE factory with a stub that records the onEvent
    // callback. The factory now uses the 3-callback positional API
    // (matching createWorkersSseConnection), so the spy signature is
    // (onEvent, onError, onConnected).
    vi.spyOn(api, 'createKanbanSseConnection').mockImplementation(
      (onEvent): api.SseClient => {
        onEventCallback = onEvent
        return sseClientStub as api.SseClient
      },
    )
  })

  afterEach(() => {
    vi.restoreAllMocks()
    onEventCallback = null
  })

  function dispatch(event: KanbanColumnEvent | KanbanTaskEvent): void {
    expect(onEventCallback).not.toBeNull()
    onEventCallback!(event)
  }

  it('initKanbanSse opens one connection for a workspace', () => {
    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')
    expect(api.createKanbanSseConnection).toHaveBeenCalledTimes(1)
  })

  it('initKanbanSse tears down + reopens when called twice (no stacking)', () => {
    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')
    store.initKanbanSse('ws_2')
    // Two init calls → two connection opens; the first was closed
    // before the second opened (no stacking).
    expect(api.createKanbanSseConnection).toHaveBeenCalledTimes(2)
    expect(sseClientStub.close).toHaveBeenCalledTimes(1)
  })

  it('closeKanbanSse tears down the connection', () => {
    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')
    store.closeKanbanSse()
    expect(sseClientStub.close).toHaveBeenCalledTimes(1)
  })

  it('closeKanbanSse is a no-op when no connection is open', () => {
    const store = useKanbanSseStore()
    store.closeKanbanSse()
    expect(sseClientStub.close).not.toHaveBeenCalled()
  })

  it('triggers fetchKanbanColumns on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanTasks on kanban_task events (moved action)', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    // Task events refresh TASKS, not columns. fetchKanbanColumns must
    // NOT be called — that would be wasted HTTP traffic (and would mask
    // a future bug where the column handler accidentally picks up task
    // events).
    expect(fetchColumnsSpy).not.toHaveBeenCalled()
    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanTasks on kanban_task events (assigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'assigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_new',
      new_column_id: 'col_1',
      new_position: 0,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanTasks on kanban_task events (unassigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'unassigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: null,
      new_position: null,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanColumns (NOT fetchKanbanTasks) on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchColumnsSpy).toHaveBeenCalledWith('ws_1', 'item_1')
    // Column events must NOT trigger task fetches — they're a
    // different shape of mutation (rename / reorder / add / delete
    // columns don't change task positions).
    expect(fetchTasksSpy).not.toHaveBeenCalled()
  })

  it('ignores events for other workspaces (filter is per-connection)', () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')

    // Event for a DIFFERENT workspace — must be dropped before reaching
    // the workspacesStore fetch call. The backend's kanban_column
    // routing key is global, so any connected client receives every
    // kanban event; the client-side filter (set at init time) is what
    // keeps each workspace's kanban state scoped.
    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_OTHER',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(event)

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('setActiveWorkspaceId updates the filter without reopening the connection', () => {
    const store = useKanbanSseStore()
    store.initKanbanSse('ws_1')
    store.setActiveWorkspaceId('ws_2')

    // No reopen — setActiveWorkspaceId just updates the filter.
    expect(api.createKanbanSseConnection).toHaveBeenCalledTimes(1)
    expect(sseClientStub.close).not.toHaveBeenCalled()
  })
})
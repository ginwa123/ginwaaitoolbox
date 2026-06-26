/**
 * Unit tests for the kanbanSse Pinia store (Chunk 4 of
 * docs/superpowers/plans/2026-06-26-fix-kanban-list-empty-add-sse.md).
 *
 * The store owns ONE SSE connection per workspace, ref-counted across
 * subscribers. On `kanban_column` and `kanban_task` events, it
 * dispatches `workspacesStore.fetchKanbanColumns(event.workspace_id,
 * event.item_id)` so the local kanban state stays in sync without a
 * manual reload.
 *
 * Mock pattern: vi.spyOn(api, 'createKanbanSseConnection') captures
 * the onEvent callback so tests can simulate SSE events by invoking
 * it directly. This mirrors `workspacesStoreSessionEvents.spec.ts`
 * (the canonical ref-count / dispatch test for the sessions SSE
 * stream) and avoids needing a real EventSource.
 *
 * Each test runs in isolation: beforeEach installs a fresh Pinia
 * instance and resets the mock capture array, so subscriptions from
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
  // The SseClient factory returns this stub. We capture the
  // onEvent callback so tests can simulate SSE events by invoking
  // it directly. The sseClientStub.close is a vi.fn so tests can
  // assert it was called when the last unsubscribe fires.
  let onEventCallback: ((raw: string, eventType: string) => void) | null = null
  let sseClientStub: Partial<api.SseClient>

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Fresh stub per test — `close` is a fresh vi.fn so call counts
    // don't leak across tests (the prior test's last unsubscribe would
    // otherwise be reflected in the next test's assertion).
    sseClientStub = { close: vi.fn() }

    // Replace the SSE factory with a stub that records the
    // onEvent callback. onError is ignored because the store
    // only logs on it — no test asserts the error path.
    vi.spyOn(api, 'createKanbanSseConnection').mockImplementation(
      (opts): api.SseClient => {
        onEventCallback = opts.onEvent
        return sseClientStub as api.SseClient
      },
    )
  })

  afterEach(() => {
    vi.restoreAllMocks()
    onEventCallback = null
  })

  function dispatch(raw: string, eventType: string): void {
    expect(onEventCallback).not.toBeNull()
    onEventCallback!(raw, eventType)
  }

  it('subscribes once per workspace (ref-counts)', () => {
    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')
    store.subscribeKanbanSse('ws_1')
    store.subscribeKanbanSse('ws_1')
    // 3 subscriptions to the same workspace → 1 SSE connection.
    expect(api.createKanbanSseConnection).toHaveBeenCalledTimes(1)

    // First two unsubscribes don't close the connection (still
    // ref-counted at 1).
    store.unsubscribeKanbanSse('ws_1')
    store.unsubscribeKanbanSse('ws_1')
    expect(sseClientStub.close).not.toHaveBeenCalled()

    // Last unsubscribe drops ref-count to 0 → close.
    store.unsubscribeKanbanSse('ws_1')
    expect(sseClientStub.close).toHaveBeenCalledTimes(1)
  })

  it('opens separate connections for different workspaces', () => {
    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')
    store.subscribeKanbanSse('ws_2')
    expect(api.createKanbanSseConnection).toHaveBeenCalledTimes(2)
  })

  it('triggers fetchKanbanColumns on kanban_column.* events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')

    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(JSON.stringify(event), 'kanban_column')

    expect(fetchSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('triggers fetchKanbanColumns on kanban_task.* events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(JSON.stringify(event), 'kanban_task')

    expect(fetchSpy).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('ignores events for other workspaces (refcount still owns the connection)', () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    store.subscribeKanbanSse('ws_1')

    // Event for a DIFFERENT workspace — must be dropped before
    // reaching the workspacesStore fetch call. The backend's
    // kanban_column routing key is global, so any connected client
    // receives every kanban event; the client-side filter is
    // what keeps each workspace's kanban state scoped.
    const event: KanbanColumnEvent = {
      action: 'updated',
      workspace_id: 'ws_OTHER',
      item_id: 'item_1',
      column_id: 'col_1',
    }
    dispatch(JSON.stringify(event), 'kanban_column')

    expect(fetchSpy).not.toHaveBeenCalled()
    // Sanity: the connection is still owned by the ref-counted
    // subscription to ws_1, so close() was not called either.
    expect(sseClientStub.close).not.toHaveBeenCalled()
  })
})

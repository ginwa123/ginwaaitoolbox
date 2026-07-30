/**
 * Unit tests for the bus-backed kanbanSse Pinia store (Chunk 10 of
 * docs/superpowers/plans/2026-06-30-unify-frontend-sse.md).
 *
 * The store no longer opens its own EventSource — it subscribes via
 * `useSseBus().on('kanban', ...)`. Tests:
 *   - install the bus via `installSseBus` + swap in a stub global
 *     client (so we never touch the network in tests)
 *   - drive kanban events via `__dispatchSseBus('kanban', event)` —
 *     the bus test injection point routes the event through the
 *     same `dispatch()` function production uses
 *   - assert the workspace-id filter drops events for other workspaces
 *   - assert the kanban_column / kanban_task dispatch logic calls
 *     `workspacesStore.fetchKanbanColumns` / `fetchKanbanTasks`
 *   - assert `closeKanbanSse` detaches the listener so events after
 *     close are NOT delivered
 *   - assert `setActiveWorkspaceId` updates the filter (without
 *     re-subscribing) — a 2nd call with a different workspaceId
 *     changes the filter on subsequent events
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'

import {
  installSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import type { KanbanColumnEvent, KanbanTaskEvent } from '../api'
import { useKanbanSseStore } from '../stores/kanbanSse'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

/**
 * Test-only stub SseClient. Tracks state-listener callbacks so tests
 * can drive the bus's `state` ShallowRef transitions to exercise
 * the `onConnected → fetchInitialKanban` watcher.
 */
function makeStubClient(initial: SseState): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function emitStubState(c: SseClient, s: SseState): void {
  const listeners = (c as any).__stateListeners as
    | Array<(s: SseState, info: SseStateInfo) => void>
    | undefined
  if (listeners) {
    for (const cb of listeners) cb(s, {} as SseStateInfo)
  }
}

describe('useKanbanSseStore (bus-backed)', () => {
  let app: VueApp
  let stubClient: SseClient

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    // Install the bus BEFORE initKanbanSse runs — kanbanSseStore calls
    // `useSseBus()` inside initKanbanSse, which throws if the bus
    // hasn't been installed. Replace the underlying SseClient with a
    // stub so we never open a network EventSource in tests.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    stubClient = makeStubClient('connecting')
    __setSseBusGlobalClient(stubClient)
  })

  afterEach(() => {
    // Detach the bus listener so events don't fire into a store whose
    // Pinia is gone — `__resetSseBus` closes the global client which
    // also tears down internal state, but explicit closeKanbanSse
    // covers the case where a test crashed before reaching close.
    try {
      useKanbanSseStore().closeKanbanSse()
    } catch {
      // store not activated in this test → no-op
    }
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatch(event: KanbanColumnEvent | KanbanTaskEvent): void {
    __dispatchSseBus('kanban', event)
  }

  it('initKanbanSse subscribes to bus.on(kanban) without opening its own EventSource', async () => {
    // Spy on the global SseClient's close call so we can assert no
    // NEW EventSource was opened by the kanbanSse store. The bus
    // already opened one (in installSseBus, replaced by the stub in
    // beforeEach) — we just verify the store didn't open another.
    const stubCloseSpy = vi.spyOn(stubClient, 'close')

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // The store must NOT close the bus's global client on init.
    expect(stubCloseSpy).not.toHaveBeenCalled()
  })

  it('initKanbanSse is idempotent — second call does NOT add a second listener', async () => {
    // Spy on workspacesStore.fetchKanbanColumns and count how many
    // times it fires per dispatched event. If initKanbanSse added a
    // second listener, the count would double.
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')
    await store.initKanbanSse('ws_1') // 2nd call — should NOT re-subscribe

    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)

    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closeKanbanSse detaches the bus listener — events after close are dropped', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // First event — listener is wired up, fetch fires.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)
    expect(fetchSpy).toHaveBeenCalledTimes(1)

    store.closeKanbanSse()

    // Second event — listener detached, fetch must NOT fire again.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_2',
    } as KanbanColumnEvent)
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it('closeKanbanSse is a no-op when no subscription is active', () => {
    // Activating the store alone (no init) must not throw.
    const store = useKanbanSseStore()
    expect(() => store.closeKanbanSse()).not.toThrow()
  })

  it('triggers fetchKanbanColumns on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

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
    await store.initKanbanSse('ws_1')

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
    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, undefined)
  })

  it('triggers fetchKanbanTasks on kanban_task events (assigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'assigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_new',
      new_column_id: 'col_1',
      new_position: 0,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, undefined)
  })

  it('triggers fetchKanbanTasks on kanban_task events (unassigned action)', async () => {
    const ws = useWorkspacesStore()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'unassigned',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: null,
      new_position: null,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, undefined)
  })

  it('forwards the active q to fetchKanbanTasks on kanban_task events (Chunk 7)', async () => {
    // CONTRACT (kanban task search, plan
    // docs/superpowers/plans/2026-07-30-kanban-task-search.md Chunk 7):
    // When the SSE handler triggers a task refetch, it MUST forward
    // the active q from activeSearchQueries so a remote move/edit
    // during a search doesn't reset the user's narrowed view to the
    // unfiltered list.
    const ws = useWorkspacesStore()
    // Seed the activeSearchQueries for item_1.
    ws.activeSearchQueries.set('item_1', 'design')

    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    expect(fetchTasksSpy).toHaveBeenCalledWith('ws_1', 'item_1', 100, undefined, 'design')
  })

  it('forwards q=undefined to fetchKanbanTasks when no search active (Chunk 7)', async () => {
    const ws = useWorkspacesStore()
    // No q set in activeSearchQueries.
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    const event: KanbanTaskEvent = {
      action: 'moved',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      task_id: 'task_1',
      new_column_id: 'col_done',
      new_position: 0,
    }
    dispatch(event)

    const lastCall = fetchTasksSpy.mock.calls[fetchTasksSpy.mock.calls.length - 1]!
    expect(lastCall[4]).toBeUndefined() // q = undefined
  })

  it('triggers fetchKanbanColumns (NOT fetchKanbanTasks) on kanban_column events', async () => {
    const ws = useWorkspacesStore()
    const fetchColumnsSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()
    const fetchTasksSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

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

  it('ignores events for other workspaces (filter is per-store)', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // Event for a DIFFERENT workspace — the store's filter drops it
    // before reaching the workspacesStore fetch call. The bus's
    // kanban channel is global (the backend fans out kanban events
    // to every connected client), so the client-side filter is what
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

  it('setActiveWorkspaceId updates the filter without re-subscribing', async () => {
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // Switch to ws_2 — the same bus listener now filters by 'ws_2'.
    // Calling setActiveWorkspaceId is idempotent w.r.t. the listener
    // (it updates the ref'd filter, doesn't detach/re-attach).
    await store.setActiveWorkspaceId('ws_2')

    // ws_1 event — must be dropped (filter is now 'ws_2').
    dispatch({
      action: 'updated',
      workspace_id: 'ws_1',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)
    expect(fetchSpy).not.toHaveBeenCalled()

    // ws_2 event — must trigger the fetch.
    dispatch({
      action: 'updated',
      workspace_id: 'ws_2',
      item_id: 'item_1',
      column_id: 'col_1',
    } as KanbanColumnEvent)
    expect(fetchSpy).toHaveBeenCalledWith('ws_2', 'item_1')
  })

  it('fetches initial kanban columns on bus state transition to "open"', async () => {
    // The bus's global stub is in 'connecting' state at the start of
    // the test (set in beforeEach). initKanbanSse watches bus state
    // and triggers fetchInitialKanban on 'open' (with immediate: true
    // covering the fast path where the bus is already 'open' at
    // registration time).
    const ws = useWorkspacesStore()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanColumns').mockResolvedValue()

    // Seed the workspaces store with a kanban item so the fetch
    // passes the "active item is kanban in the active workspace"
    // guard in fetchInitialKanban.
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_1',
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [],
          },
        ],
      },
    ]
    ws.setActiveWorkspaceItem('item_1')

    const store = useKanbanSseStore()
    await store.initKanbanSse('ws_1')

    // Drive the state transition to 'open'.
    emitStubState(stubClient, 'open')

    // The watch is async (Vue default) so we need to drain a
    // microtask before asserting on the call count.
    await nextTick()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })
})
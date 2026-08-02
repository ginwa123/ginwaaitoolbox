/**
 * Tests for the SSE kanban_task mirror fix.
 *
 * Background (bug task_1785688388584, plan
 * docs/superpowers/plans/2026-08-06-sse-kanban-move-duplicate-task.md):
 *
 * When an agent (or any non-UI client) moves a kanban task via
 * `kanban_move_task`, the backend emits a `kanban_task` SSE event with
 * `action: 'moved'`, `new_column_id: <dest>`. The frontend handler in
 * `kanbanSse.ts` calls `fetchKanbanTasks(destCol, 100, ...)` which
 * merges the fresh wire response into `item.tasks` via:
 *
 *   otherTasks = item.tasks.filter(t => t.kanban_column_id !== destCol)
 *   item.tasks = [...otherTasks, ...normalized]
 *
 * If the local task's `kanban_column_id` is still the SOURCE column
 * (because nothing locally mirrored the move), the filter keeps the
 * stale copy AND `normalized` adds the fresh dest copy — producing a
 * visible duplicate in the user's UI. User-initiated moves don't hit
 * this because `moveTaskToColumn` mutates the local column id BEFORE
 * the SSE round-trip.
 *
 * Fix: the SSE handler mirrors the local task's column_id (and
 * position) to match the event payload BEFORE the refetch. These
 * tests verify the mirror contract end-to-end.
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
import type { SseClient, SseState } from '../helpers/sseClient'
import type { KanbanTaskEvent } from '../api'
import * as api from '../api'
import { useKanbanSseStore } from '../stores/kanbanSse'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeStubClient(initial: SseState): SseClient {
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

describe('kanbanSse — mirror local task on move/assign/unassign (fix duplicate-task bug)', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    try {
      useKanbanSseStore().closeKanbanSse()
    } catch {
      // store not activated in this test → no-op
    }
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatch(event: KanbanTaskEvent): void {
    __dispatchSseBus('kanban', event)
  }

  /** Seed the workspaces store with a kanban item that has one task in colA. */
  function seedKanbanWithTask(opts: {
    workspaceId?: string
    itemId?: string
    taskId?: string
    sourceColumnId?: string
    destColumnId?: string
    extraTasks?: Array<{ id: string; columnId: string; name?: string }>
  }) {
    const ws = useWorkspacesStore()
    const wsId = opts.workspaceId ?? 'ws_1'
    const itemId = opts.itemId ?? 'item_1'
    const taskId = opts.taskId ?? 'task_1'
    const sourceCol = opts.sourceColumnId ?? 'colA'
    const destCol = opts.destColumnId ?? 'colB'
    ws.workspaces = [
      {
        id: wsId,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: itemId,
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [
              {
                id: taskId,
                name: 'cli',
                kanban_column_id: sourceCol,
                kanban_position: 5,
              },
              ...(opts.extraTasks ?? []).map((t) => ({
                id: t.id,
                name: t.name ?? 'extra',
                kanban_column_id: t.columnId,
                kanban_position: 0,
              })),
            ],
            kanban_columns: [
              {
                id: sourceCol,
                workspace_item_id: itemId,
                name: 'colA',
                position: 0,
                created_at: '2026-08-06T00:00:00Z',
              },
              {
                id: destCol,
                workspace_item_id: itemId,
                name: 'colB',
                position: 1,
                created_at: '2026-08-06T00:00:00Z',
              },
            ],
          },
        ],
      },
    ]
    return { ws, wsId, itemId, taskId }
  }

  it('moved event: mirrors local task column_id to the destination BEFORE fetch resolves', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // Spy on fetchKanbanTasks but DON'T resolve immediately so we can
    // observe the local state between dispatch and fetch resolution.
    // Definite-assignment assertion on the resolve callback because
    // the inner closure assigns before the outer code reads it.
    let resolveFetch!: () => void
    const fetchSpy = vi
      .spyOn(ws, 'fetchKanbanTasks')
      .mockImplementation(
        () =>
          new Promise<void>((resolve) => {
            resolveFetch = resolve
          }),
      )

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'moved',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    })

    // Fetch was triggered for the destination column.
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(fetchSpy).toHaveBeenCalledWith(
      wsId,
      itemId,
      'colB',
      100,
      undefined,
      undefined,
      undefined,
      undefined,
    )

    // The local task's column_id was mirrored to 'colB' BEFORE the
    // awaited fetch resolves — this is the fix. Pre-fix this would
    // still be 'colA' and the subsequent merge would duplicate the
    // task.
    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find(
      (t) => t.id === taskId,
    )!
    expect(localTask.kanban_column_id).toBe('colB')
    expect(localTask.kanban_position).toBe(0)

    // Drain the pending fetch so afterEach's cleanup doesn't hang.
    resolveFetch()
    await nextTick()
  })

  it('moved event (full integration): merge produces NO duplicate after wire response', async () => {
    // End-to-end: local task in colA, agent moves it to colB, the SSE
    // event arrives, the mirror updates local state, the fetch returns
    // the fresh colB list, the merge lands exactly 1 copy of the task
    // in colB and 0 in colA.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // Mock api.getTasks to return the moved task in colB (the
    // post-move wire shape).
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [
        {
          id: taskId,
          name: 'cli',
          kanban_column_id: 'colB',
          kanban_position: 0,
        },
      ],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'moved',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    })

    // Drain microtasks: the SSE handler calls fetchKanbanTasks
    // (void, no await) but the mock api.getTasks returns a resolved
    // promise, so the merge lands in the same task queue.
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    const inColA = tasks.filter((t) => t.kanban_column_id === 'colA')
    const inColB = tasks.filter((t) => t.kanban_column_id === 'colB')

    // Exactly one copy of the task, in colB.
    expect(tasks).toHaveLength(1)
    expect(inColA).toHaveLength(0)
    expect(inColB).toHaveLength(1)
    expect(inColB[0]!.id).toBe(taskId)
  })

  it('unassigned event: mirrors local task column_id to null BEFORE fetch', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // Spy on fetchKanbanTasksForAllColumns (the path the unassigned
    // branch takes). Don't resolve immediately.
    let resolveFetch!: () => void
    const fetchAllSpy = vi
      .spyOn(ws, 'fetchKanbanTasksForAllColumns')
      .mockImplementation(
        () =>
          new Promise<void>((resolve) => {
            resolveFetch = resolve
          }),
      )

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'unassigned',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: null,
      new_position: null,
    })

    expect(fetchAllSpy).toHaveBeenCalledTimes(1)

    // Local task's column_id is null (unassigned) BEFORE the fetch
    // resolves. Pre-fix this would still be 'colA' and the source-
    // column refetch would leave the stale copy.
    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find(
      (t) => t.id === taskId,
    )!
    expect(localTask.kanban_column_id).toBeNull()

    resolveFetch()
    await nextTick()
  })

  it('unassigned event (full integration): task preserved as unassigned after wire response', async () => {
    // After unassign: task stays in item.tasks with kanban_column_id
    // = null (the "unassigned limbo" state). The UI hides it from all
    // columns because no column matches null, but the task itself is
    // not deleted — the user can re-assign it. Pre-fix the local
    // task was stuck in the SOURCE column's `kanban_column_id`, so
    // after `fetchKanbanTasks(colA)`'s merge the task was kept in BOTH
    // the unassigned state AND the source column (visible duplicate).
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // The unassigned branch fires fetchKanbanTasksForAllColumns which
    // iterates each column and re-fetches. Mock api.getTasks to return
    // an empty list for every column — the task is unassigned, so the
    // server returns it nowhere.
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'unassigned',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: null,
      new_position: null,
    })

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    // Exactly one copy of the task (preserved as unassigned limbo),
    // with column_id set to null — not the source column (colA).
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.id).toBe(taskId)
    expect(tasks[0]!.kanban_column_id).toBeNull()

    // Specifically: NO copy left in the source column (the original
    // bug — the stale colA entry visible in the UI).
    const inColA = tasks.filter((t) => t.kanban_column_id === 'colA')
    expect(inColA).toHaveLength(0)
  })

  it('assigned event: mirrors local task column_id when it changes (no duplicate)', async () => {
    // Agent creates a new task that auto-assigns to colB. The local
    // store has the task in colA (stale). After the SSE event, the
    // local task should move to colB.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [
        {
          id: taskId,
          name: 'cli',
          kanban_column_id: 'colB',
          kanban_position: 0,
        },
      ],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'assigned',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    })

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.kanban_column_id).toBe('colB')
  })

  it('event for a task not in local store: no-op, no throw', async () => {
    // SSE event arrives for a task the local store doesn't know
    // about (e.g. another tab's task, or event fired before initial
    // load completed). The mirror must silently no-op.
    const { ws, wsId, itemId } = seedKanbanWithTask({ taskId: 'task_1' })

    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    expect(() =>
      dispatch({
        action: 'moved',
        workspace_id: wsId,
        item_id: itemId,
        task_id: 'task_UNKNOWN',
        new_column_id: 'colB',
        new_position: 0,
      }),
    ).not.toThrow()

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    // The known task is untouched.
    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find(
      (t) => t.id === 'task_1',
    )!
    expect(localTask.kanban_column_id).toBe('colA')
  })

  it('human_touched event: no column change (the SSE payload carries null), local untouched', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // human_touched has new_column_id: null. The mirror should set
    // kanban_column_id = null, BUT the user's interaction was NOT a
    // move — the agent's kanban_card UI listens to this event and
    // re-fetches the task list. Setting column_id to null here would
    // be wrong: the task didn't actually move.
    //
    // The fix's mirror only fires for `moved` / `assigned` (with a
    // non-null new_column_id) and `unassigned`. `human_touched`
    // bypasses the mirror because the event payload signals "no
    // position change". Assert this contract: column_id is preserved.
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [
        {
          id: taskId,
          name: 'cli',
          kanban_column_id: 'colA',
          kanban_position: 5,
        },
      ],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'human_touched',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: null,
      new_position: null,
    })

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find(
      (t) => t.id === taskId,
    )!
    expect(localTask.kanban_column_id).toBe('colA')
    expect(localTask.kanban_position).toBe(5)
  })

  it('idempotent mirror: dispatching the same moved event twice is safe', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [
        {
          id: taskId,
          name: 'cli',
          kanban_column_id: 'colB',
          kanban_position: 0,
        },
      ],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    const event = {
      action: 'moved' as const,
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    }
    dispatch(event)
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    dispatch(event)
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.kanban_column_id).toBe('colB')
    expect(tasks[0]!.kanban_position).toBe(0)
  })
})
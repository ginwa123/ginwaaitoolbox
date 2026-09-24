import { describe, expect, it, vi } from 'vitest'
import {
  TaskEngineDb,
  taskContextKey,
  taskSortKey,
  toTaskRow,
  type TaskRequest,
} from '../TaskEngineDb'
import type { Task } from '../../api'

const task = (over: Partial<Task> & Record<string, unknown> = {}): Task =>
  ({
    id: 'task_1',
    name: 'Fix login',
    workspace_item_id: 'item_1',
    updated_at: '2026-09-24 10:00:00',
    ...over,
  }) as Task

const response = (tasks: Task[], over: Record<string, unknown> = {}) => ({
  tasks,
  has_more: false,
  next_cursor: null,
  ...over,
})

const request = (over: Partial<TaskRequest> = {}): TaskRequest => ({
  workspaceId: 'ws_1',
  itemId: 'item_1',
  ...over,
})

describe('TaskEngineDb mapping', () => {
  it('uses the wire updated_at value as the local sort key', () => {
    expect(taskSortKey(task({ updated_at: '2026-09-24 10:00:00' }))).toBe('2026-09-24 10:00:00')
    expect(taskSortKey(task({ updated_at: undefined }))).toBe('')
  })

  it('falls back to the normalized updatedAt Date when wire updated_at is absent', () => {
    expect(
      taskSortKey(task({ updated_at: undefined, updatedAt: new Date('2026-09-24T10:00:00Z') })),
    ).toBe('2026-09-24T10:00:00.000Z')
  })

  it('keeps the complete task row in raw', () => {
    const raw = task({ id: 'task_42', name: 'Keep all fields', tags: ['auth'] })
    const row = toTaskRow(raw)
    expect(row.id).toBe('task_42')
    expect(row.sortKey).toBe('2026-09-24 10:00:00')
    expect(row.raw).toEqual(raw)
  })

  it('isolates workspace, item, column, query, and sort contexts', () => {
    const base = request()
    const keys = new Set([
      taskContextKey(base),
      taskContextKey(request({ workspaceId: 'ws_2' })),
      taskContextKey(request({ itemId: 'item_2' })),
      taskContextKey(request({ columnId: 'col_a' })),
      taskContextKey(request({ q: 'login' })),
      taskContextKey(request({ sortBy: 'name', direction: 'asc' })),
    ])
    expect(keys.size).toBe(6)
  })
})

describe('TaskEngineDb cache-first revalidation', () => {
  it('fetches a cold first page with the existing default call shape', async () => {
    const fetchFn = vi.fn(async () =>
      response([task({ id: 'new', updated_at: '2026-09-24 10:01:00' })]),
    )
    const engine = new TaskEngineDb(fetchFn as never)

    const result = await engine.syncOnMount(request(), 10)

    expect(result.fromCache).toBe(false)
    expect(result.items.map((row) => row.id)).toEqual(['new'])
    expect(fetchFn).toHaveBeenCalledWith('ws_1', 'item_1')
    expect(await engine.primeFromCache(request(), 10)).toHaveLength(1)
  })

  it('paints a warm cache and revalidates the same request shape', async () => {
    const fetchFn = vi.fn(async () =>
      response([task({ id: 'new', updated_at: '2026-09-24 10:01:00' })]),
    )
    const engine = new TaskEngineDb(fetchFn as never)
    const ctx = request()
    await engine.putLocal(ctx, [toTaskRow(task({ id: 'old', updated_at: '2026-09-24 10:00:00' }))])

    const result = await engine.syncOnMount(ctx, 10)

    expect(result.fromCache).toBe(true)
    expect(result.items.map((row) => row.id).sort()).toEqual(['new', 'old'])
    expect(fetchFn).toHaveBeenCalledWith('ws_1', 'item_1')
  })

  it('replaces a same-id row on mount, then evicts rows a complete empty page omits', async () => {
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(
        response([task({ id: 'same', name: 'server version', updated_at: '2026-09-24 10:01:00' })]),
      )
      .mockResolvedValueOnce(response([]))
    const engine = new TaskEngineDb(fetchFn as never)
    const ctx = request()
    await engine.putLocal(ctx, [toTaskRow(task({ id: 'same', name: 'cached version' }))])

    const first = await engine.syncOnMount(ctx, 10)
    expect(first.items[0]?.raw.name).toBe('server version')

    const empty = await engine.loadDelta(ctx, 10)
    expect(empty?.items).toEqual([])
    // A complete page lists every row in the context — 'same' is gone
    // server-side, so the next offline prime must not resurrect it.
    expect(await engine.primeFromCache(ctx, 10)).toEqual([])
  })

  it('keeps cached rows when the revalidation page is partial (has_more=true)', async () => {
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(
        response([task({ id: 'new' })], { has_more: true, next_cursor: 'c1' }),
      )
    const engine = new TaskEngineDb(fetchFn as never)
    const ctx = request()
    await engine.putLocal(ctx, [toTaskRow(task({ id: 'old' }))])

    const delta = await engine.loadDelta(ctx, 10)

    expect(delta?.hasMore).toBe(true)
    expect((await engine.primeFromCache(ctx, 10)).map((row) => row.id).sort()).toEqual([
      'new',
      'old',
    ])
  })

  it('evicts a deleted row from a complete page but keeps the survivors', async () => {
    const fetchFn = vi.fn(async () => response([task({ id: 'keep' })]))
    const engine = new TaskEngineDb(fetchFn as never)
    const ctx = request()
    await engine.putLocal(ctx, [toTaskRow(task({ id: 'keep' })), toTaskRow(task({ id: 'gone' }))])

    await engine.loadDelta(ctx, 10)

    expect((await engine.primeFromCache(ctx, 10)).map((row) => row.id)).toEqual(['keep'])
  })

  it('removes a single row from its context via removeTask', async () => {
    const fetchFn = vi.fn(async () => response([]))
    const engine = new TaskEngineDb(fetchFn as never)
    const ctx = request()
    await engine.putLocal(ctx, [toTaskRow(task({ id: 'a' })), toTaskRow(task({ id: 'b' }))])

    await engine.removeTask(ctx, 'a')

    expect((await engine.primeFromCache(ctx, 10)).map((row) => row.id)).toEqual(['b'])
  })

  it('keeps cached rows when the network fails', async () => {
    const fetchFn = vi.fn().mockRejectedValue(new Error('offline'))
    const engine = new TaskEngineDb(fetchFn as never)
    const ctx = request()
    await engine.putLocal(ctx, [toTaskRow(task({ id: 'keep' }))])

    const result = await engine.syncOnMount(ctx, 10)

    expect(result.fromCache).toBe(true)
    expect(result.items.map((row) => row.id)).toEqual(['keep'])
  })
})

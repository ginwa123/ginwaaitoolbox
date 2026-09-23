import { describe, it, expect, vi } from 'vitest'
import { SessionEngineDb, toSessionRow, sessionSortKey } from '../SessionEngineDb'
import type { Chat } from '../../api'

const session = (over: Partial<Chat> = {}): Chat =>
  ({
    session_id: 's1',
    session_name: 'Hello',
    status: 'active',
    updated_at: '2026-09-20 10:00:00',
    last_human_touched_at: '',
    ...over,
  }) as Chat

const fetchOk = (sessions: Chat[], extra: object = {}) =>
  vi.fn(async () => ({
    sessions,
    has_more: false,
    next_cursor: null,
    total: sessions.length,
    ...extra,
  }))

describe('SessionEngineDb mapping', () => {
  it('sortKey tracks updated_at (backend sort_by) with empty fallback', () => {
    expect(sessionSortKey(session({ updated_at: '2026-09-20 10:00:00' }))).toBe(
      '2026-09-20 10:00:00',
    )
    expect(sessionSortKey(session({ updated_at: '' }))).toBe('')
    expect(sessionSortKey(session({ updated_at: undefined }))).toBe('')
  })

  it('toSessionRow keeps the full server row in raw', () => {
    const row = toSessionRow(
      session({ session_id: 'abc', git_branch: 'feat/x', sub_agent_name: 'helper' }),
    )
    expect(row.id).toBe('abc')
    expect(row.sortKey).toBe('2026-09-20 10:00:00')
    expect(row.raw.git_branch).toBe('feat/x')
    expect(row.raw.sub_agent_name).toBe('helper')
  })

  it('compareFn sorts newest-first (ISO strings compare lexicographically)', () => {
    const eng = new SessionEngineDb(fetchOk([]) as never)
    const a = toSessionRow(session({ session_id: 'a', updated_at: '2026-09-19 10:00:00' }))
    const b = toSessionRow(session({ session_id: 'b', updated_at: '2026-09-21 10:00:00' }))
    expect([a, b].sort((x, y) => eng.compareFn(x, y)).map((r) => r.id)).toEqual(['b', 'a'])
  })
})

describe('SessionEngineDb delta', () => {
  it('fetchDeltaPage asks for page 1 desc (backend cursor only pages older)', async () => {
    const fetchFn = fetchOk([session()])
    const eng = new SessionEngineDb(fetchFn as never)
    const delta = await eng.fetchDeltaPage('ignored-cursor', 30, 'ws-1')
    expect(fetchFn).toHaveBeenCalledTimes(1)
    expect(fetchFn.mock.calls[0]).toEqual(['updated_at', 'desc', 30, undefined, 'ws-1'])
    expect(delta.items).toHaveLength(1)
    expect(delta.items[0]!.id).toBe('s1')
    expect(delta.total).toBe(1)
  })

  it("ctx 'all' fetches unscoped (workspaceId undefined)", async () => {
    const fetchFn = fetchOk([])
    const eng = new SessionEngineDb(fetchFn as never)
    await eng.fetchDeltaPage(null, 30, 'all')
    expect(fetchFn.mock.calls[0]).toEqual(['updated_at', 'desc', 30, undefined, undefined])
  })

  it('loadDelta persists rows so primeFromCache paints them (in-memory path)', async () => {
    const eng = new SessionEngineDb(
      fetchOk([session({ session_id: 'n1' }), session({ session_id: 'n2' })]) as never,
    )
    expect(await eng.primeFromCache('ws-cache', 30)).toHaveLength(0)
    const delta = await eng.loadDelta('ws-cache', 30)
    expect(delta).not.toBeNull()
    const cached = await eng.primeFromCache('ws-cache', 30)
    expect(cached.map((r) => r.id).sort()).toEqual(['n1', 'n2'])
  })

  it('loadDelta failure returns null and keeps the painted cache', async () => {
    const eng = new SessionEngineDb(fetchOk([session({ session_id: 'keep' })]) as never)
    await eng.loadDelta('ws-fail', 30)
    // Swap in a failing fetcher on the same ctx via a fresh engine sharing
    // nothing — instead simulate failure through the engine's own path by
    // calling loadDelta on an engine whose fetch rejects.
    const failing = new SessionEngineDb(
      vi.fn(async () => {
        throw new Error('offline')
      }) as never,
    )
    // Seed the failing engine's cache first, then watch it survive.
    await failing.putLocal('ws-fail', [toSessionRow(session({ session_id: 'keep' }))])
    expect(await failing.loadDelta('ws-fail', 30)).toBeNull()
    expect((await failing.primeFromCache('ws-fail', 30)).map((r) => r.id)).toEqual(['keep'])
  })

  it('removeSession evicts one row and leaves the rest', async () => {
    const eng = new SessionEngineDb(fetchOk([]) as never)
    await eng.putLocal('ws-evict', [
      toSessionRow(session({ session_id: 'gone' })),
      toSessionRow(session({ session_id: 'stays' })),
    ])
    await eng.removeSession('ws-evict', 'gone')
    expect((await eng.primeFromCache('ws-evict', 30)).map((r) => r.id)).toEqual(['stays'])
  })

  it('caches are partitioned by workspace ctx', async () => {
    const eng = new SessionEngineDb(fetchOk([]) as never)
    await eng.putLocal('ws-a', [toSessionRow(session({ session_id: 'only-a' }))])
    expect(await eng.primeFromCache('ws-b', 30)).toHaveLength(0)
    expect((await eng.primeFromCache('ws-a', 30)).map((r) => r.id)).toEqual(['only-a'])
  })
})

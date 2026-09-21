import { describe, it, expect, vi } from 'vitest'
import { BaseSyncEngine, type SyncDelta, type SyncStore, type Syncable } from '../SyncEngine'

interface Item extends Syncable {
  id: string
  sortKey: number
}

const mk = (id: string, sortKey: number): Item => ({ id, sortKey })

class FakeStore implements SyncStore<Item> {
  items = new Map<string, Item[]>()
  cursors = new Map<string, string | null>()
  async getAll(key: string, limit: number) {
    return (this.items.get(key) ?? []).slice(0, limit)
  }
  async putAll(key: string, items: Item[]) {
    const cur = this.items.get(key) ?? []
    const seen = new Set(cur.map((m) => m.id))
    this.items.set(key, [...cur, ...items.filter((m) => !seen.has(m.id))])
  }
  async getOlder(key: string, before: string | number, limit: number) {
    return (this.items.get(key) ?? []).filter((m) => m.sortKey < (before as number)).slice(-limit)
  }
  async getCursor(key: string) {
    return this.cursors.get(key) ?? null
  }
  async setCursor(key: string, cursor: string | null) {
    this.cursors.set(key, cursor)
  }
  async clear(key: string) {
    this.items.delete(key)
    this.cursors.delete(key)
  }
}

class TestEngine extends BaseSyncEngine<Item, string> {
  constructor(
    private s: SyncStore<Item> | null,
    private fetcher: (
      cursor: string | null,
      limit: number,
      ctx: string,
    ) => Promise<SyncDelta<Item>>,
  ) {
    super()
  }
  protected storeOrNull() {
    return this.s
  }
  protected fetchDelta(cursor: string | null, limit: number, ctx: string) {
    return this.fetcher(cursor, limit, ctx)
  }
  protected cursorOf(item: Item) {
    return item.id
  }
  protected compareFn(a: Item, b: Item) {
    return b.sortKey - a.sortKey
  }
}

describe('BaseSyncEngine orchestration', () => {
  it('cache-then-delta merges, dedupes, and advances the cursor', async () => {
    const store = new FakeStore()
    store.items.set('s1', [mk('a', 3), mk('b', 2)])
    store.cursors.set('s1', 'cur-0')
    const fetch = vi.fn(async () => ({
      items: [mk('b', 2), mk('c', 1)],
      nextCursor: 'cur-1',
      hasMore: false,
      cursorToSave: 'cur-1',
    }))
    const eng = new TestEngine(store, fetch)
    const res = await eng.syncOnMount('s1', 50)
    expect(res.fromCache).toBe(true)
    expect(res.items.map((m) => m.id)).toEqual(['a', 'b', 'c'])
    expect(fetch).toHaveBeenCalledWith('cur-0', 50, 's1')
    expect(await eng.getCursor('s1')).toBe('cur-1')
    // Persisted without dupes.
    expect((await store.getAll('s1', 50)).map((m) => m.id).sort()).toEqual(['a', 'b', 'c'])
  })

  it('falls back to cache when the network fails', async () => {
    const store = new FakeStore()
    store.items.set('s1', [mk('a', 3)])
    const eng = new TestEngine(store, async () => {
      throw new Error('offline')
    })
    const res = await eng.syncOnMount('s1', 50)
    expect(res.items.map((m) => m.id)).toEqual(['a'])
    expect(res.delta).toBeNull()
  })

  it('putLocal never throws and loadOlderFromCache reads older rows', async () => {
    const eng = new TestEngine(null, async () => ({
      items: [],
      nextCursor: null,
      hasMore: false,
      cursorToSave: null,
    }))
    await eng.putLocal('s1', [mk('a', 3), mk('b', 2), mk('c', 1)])
    const older = await eng.loadOlderFromCache('s1', 2, 10)
    expect(older.map((m) => m.id)).toEqual(['c'])
    await eng.clear('s1')
    expect(await eng.primeFromCache('s1', 10)).toEqual([])
  })
})

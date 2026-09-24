/**
 * Generic IndexedDB wrapper for the sync engine.
 *
 * Uses a dynamic `import('idb')` so SSR/tests without IndexedDB fall back to
 * an in-memory Map instead of crashing at module load. All methods are
 * best-effort safe: IDB failures reject and the engine catches them.
 */
import type { Syncable, SyncStore } from './SyncEngine'

const DB_NAME = 'nalar-sync'
// v2 adds the `sessions` store (sidebar local-first). v1 only had
// `messages` + `sync_state` — the upgrade path creates any missing
// store so existing v1 users keep their message cache.
const DB_VERSION = 2

// Every store the app owns. The upgrade callback creates ALL of them
// (not just the opener's own storeName): two engine instances open
// the same DB, and whichever opens first must leave a complete schema
// behind — otherwise the second opener sees its version already
// current, gets no upgrade, and silently falls back to memory.
const KNOWN_STORES = ['messages', 'sessions']

type IdbModule = typeof import('idb')

export class IndexedDbStore<T extends Syncable> implements SyncStore<T> {
  private dbPromise: Promise<import('idb').IDBPDatabase> | null = null
  private mem = new Map<string, T[]>()
  private memCursors = new Map<string, string | null>()
  private idbFailed = false

  constructor(
    private storeName: string,
    private sortKeyPath: string = 'sortKey',
  ) {}

  private async idb(): Promise<IdbModule | null> {
    if (typeof indexedDB === 'undefined') return null
    try {
      return await import('idb')
    } catch {
      return null
    }
  }

  private async db(): Promise<import('idb').IDBPDatabase | null> {
    if (this.idbFailed || typeof indexedDB === 'undefined') return null
    if (!this.dbPromise) {
      const mod = await this.idb()
      if (!mod) return null
      const sortKeyPath = this.sortKeyPath
      this.dbPromise = mod.openDB(DB_NAME, DB_VERSION, {
        upgrade(db) {
          for (const name of KNOWN_STORES) {
            if (!db.objectStoreNames.contains(name)) {
              const s = db.createObjectStore(name, { keyPath: 'id' })
              s.createIndex('by_ctx_sort', ['ctx', sortKeyPath])
            }
          }
          if (!db.objectStoreNames.contains('sync_state')) {
            db.createObjectStore('sync_state', { keyPath: 'key' })
          }
        },
      })
      this.dbPromise.catch(() => {
        this.idbFailed = true
        this.dbPromise = null
      })
    }
    try {
      return await this.dbPromise
    } catch {
      this.idbFailed = true
      this.dbPromise = null
      return null
    }
  }

  async getAll(key: string, limit: number): Promise<T[]> {
    const memRows = (this.mem.get(key) ?? []).slice()
    if (typeof indexedDB === 'undefined') {
      return this.sortNewestFirst(memRows).slice(0, limit)
    }
    const db = await this.db()
    if (!db) return this.sortNewestFirst(memRows).slice(0, limit)
    try {
      const tx = db.transaction(this.storeName, 'readonly')
      const idx = tx.store.index('by_ctx_sort')
      // Compound index [ctx, sortKey] with numeric sortKey: string bounds
      // ('', '\uffff') would EXCLUDE all numbers (IDB ordering: numbers <
      // strings). Use numeric bounds and sort newest-first in JS.
      const rows = await idx.getAll(IDBKeyRange.bound([key, -Infinity], [key, Infinity]))
      return this.sortNewestFirst(rows as T[]).slice(0, limit)
    } catch {
      return this.sortNewestFirst(memRows).slice(0, limit)
    }
  }

  async putAll(storeKey: string, items: T[]): Promise<void> {
    const stamped = items.map((i) => ({ ...i, ctx: storeKey }))
    const byId = new Map((this.mem.get(storeKey) ?? []).map((item) => [item.id, item]))
    for (const item of stamped) byId.set(item.id, item as T)
    this.mem.set(storeKey, [...byId.values()])
    const db = await this.db()
    if (!db) return
    const tx = db.transaction(this.storeName, 'readwrite')
    for (const item of stamped) {
      await tx.store.put(item)
    }
    await tx.done
  }

  async remove(storeKey: string, id: string): Promise<void> {
    const cur = this.mem.get(storeKey) ?? []
    this.mem.set(
      storeKey,
      cur.filter((m) => m.id !== id),
    )
    const db = await this.db()
    if (!db) return
    try {
      await db.delete(this.storeName, id)
    } catch {
      // Memory copy already updated.
    }
  }

  async getOlder(storeKey: string, beforeSortKey: string | number, limit: number): Promise<T[]> {
    const db = await this.db()
    if (!db) {
      return this.sortNewestFirst(
        (this.mem.get(storeKey) ?? []).filter(
          (m) => (m.sortKey as string | number) < beforeSortKey,
        ),
      ).slice(0, limit)
    }
    try {
      const tx = db.transaction(this.storeName, 'readonly')
      const idx = tx.store.index('by_ctx_sort')
      // Numeric bounds: upper open so `beforeSortKey` itself is excluded.
      // Handles sortKey string|number — bound values just need to match the
      // stored type; IDB compares within the same type correctly.
      const rows = await idx.getAll(
        IDBKeyRange.bound([storeKey, -Infinity], [storeKey, beforeSortKey as never], false, true),
      )
      // IDB returns ascending; newest-first = take the tail, reversed.
      const typed = this.sortNewestFirst(rows as T[])
      return typed.slice(0, limit)
    } catch {
      return []
    }
  }

  async getCursor(key: string): Promise<string | null> {
    const db = await this.db()
    if (!db) return this.memCursors.get(key) ?? null
    try {
      const row = await db.get('sync_state', `${this.storeName}:${key}`)
      return ((row as { cursor?: string | null } | undefined)?.cursor ?? null) as string | null
    } catch {
      return this.memCursors.get(key) ?? null
    }
  }

  async setCursor(key: string, cursor: string | null): Promise<void> {
    this.memCursors.set(key, cursor)
    const db = await this.db()
    if (!db) return
    try {
      await db.put('sync_state', { key: `${this.storeName}:${key}`, cursor })
    } catch {
      // Memory copy already updated.
    }
  }

  async clear(key: string): Promise<void> {
    this.mem.delete(key)
    this.memCursors.delete(key)
    const db = await this.db()
    if (!db) return
    try {
      const tx = db.transaction(this.storeName, 'readwrite')
      const idx = tx.store.index('by_ctx_sort')
      let cursor = await idx.openCursor(IDBKeyRange.bound([key, -Infinity], [key, Infinity]))
      while (cursor) {
        await cursor.delete()
        cursor = await cursor.continue()
      }
      await tx.done
      await db.delete('sync_state', `${this.storeName}:${key}`)
    } catch {
      // Best-effort.
    }
  }

  /** Newest-first by sortKey desc; handles string|number sortKeys. */
  private sortNewestFirst(rows: T[]): T[] {
    return rows.slice().sort((a, b) => {
      const ak = a.sortKey as string | number
      const bk = b.sortKey as string | number
      if (typeof ak === 'number' && typeof bk === 'number') return bk - ak
      return String(bk) < String(ak) ? -1 : String(bk) > String(ak) ? 1 : 0
    })
  }
}

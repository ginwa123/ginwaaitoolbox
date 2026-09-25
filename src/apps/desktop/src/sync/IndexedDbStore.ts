/**
 * Generic IndexedDB wrapper for the sync engine.
 *
 * Uses a dynamic `import('idb')` so SSR/tests without IndexedDB fall back to
 * an in-memory Map instead of crashing at module load. All methods are
 * best-effort safe: IDB failures reject and the engine catches them.
 */
import type { Syncable, SyncStore } from './SyncEngine'
import { getCurrentUserId } from '../helpers/userScope'

const DB_NAME = 'nalar-sync'

/**
 * Per-user database name (plan 2026-09-25, W5).
 *
 * The sync cache holds full message bodies, so one shared database means B
 * inherits A's cached chats. Splitting the DATABASE (rather than adding a
 * `userId` to every key path) needs no schema or key migration and makes a
 * cross-user read impossible by construction — the other user's rows are in
 * a different database.
 *
 * No identity (auth off, or `/api/auth/me` unresolved) keeps the legacy
 * `nalar-sync` name, so the auth-off path is unchanged.
 */
function dbName(): string {
  const userId = getCurrentUserId()
  return userId ? `${DB_NAME}:${userId}` : DB_NAME
}
// v2 added sessions; v3 adds the task-list cache.
const DB_VERSION = 3
const KNOWN_STORES = ['messages', 'sessions', 'tasks']
const TASK_STORE_KEY_PATH: string[] = ['ctx', 'id']

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
      this.dbPromise = mod.openDB(dbName(), DB_VERSION, {
        upgrade(db) {
          for (const name of KNOWN_STORES) {
            if (db.objectStoreNames.contains(name)) continue
            const keyPath = name === 'tasks' ? TASK_STORE_KEY_PATH : 'id'
            const store = db.createObjectStore(name, { keyPath })
            store.createIndex('by_ctx_sort', ['ctx', sortKeyPath])
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
      const index = tx.store.index('by_ctx_sort')
      const rows = await index.getAll(IDBKeyRange.bound([key, -Infinity], [key, Infinity]))
      return this.sortNewestFirst(rows as T[]).slice(0, limit)
    } catch {
      return this.sortNewestFirst(memRows).slice(0, limit)
    }
  }

  async putAll(storeKey: string, items: T[]): Promise<void> {
    const stamped = items.map((item) => ({ ...item, ctx: storeKey }))
    const byId = new Map((this.mem.get(storeKey) ?? []).map((item) => [item.id, item]))
    for (const item of stamped) byId.set(item.id, item as T)
    this.mem.set(storeKey, [...byId.values()])

    const db = await this.db()
    if (!db) return
    const tx = db.transaction(this.storeName, 'readwrite')
    for (const item of stamped) await tx.store.put(item)
    await tx.done
  }

  async remove(storeKey: string, id: string): Promise<void> {
    const key = this.storeName === 'tasks' ? [storeKey, id] : id
    const current = this.mem.get(storeKey) ?? []
    this.mem.set(
      storeKey,
      current.filter((item) => item.id !== id),
    )
    const db = await this.db()
    if (!db) return
    try {
      await db.delete(this.storeName, key)
    } catch {
      // Memory copy already updated.
    }
  }

  async getOlder(storeKey: string, beforeSortKey: string | number, limit: number): Promise<T[]> {
    const db = await this.db()
    if (!db) {
      return this.sortNewestFirst(
        (this.mem.get(storeKey) ?? []).filter(
          (item) => (item.sortKey as string | number) < beforeSortKey,
        ),
      ).slice(0, limit)
    }
    try {
      const tx = db.transaction(this.storeName, 'readonly')
      const index = tx.store.index('by_ctx_sort')
      const rows = await index.getAll(
        IDBKeyRange.bound([storeKey, -Infinity], [storeKey, beforeSortKey as never], false, true),
      )
      return this.sortNewestFirst(rows as T[]).slice(0, limit)
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
      const index = tx.store.index('by_ctx_sort')
      let cursor = await index.openCursor(IDBKeyRange.bound([key, -Infinity], [key, Infinity]))
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

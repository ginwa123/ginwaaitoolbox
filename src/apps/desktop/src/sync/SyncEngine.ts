/**
 * Generic local-first sync engine (Phase 1).
 *
 * Storage-agnostic orchestration: cache-then-delta reads, cursor tracking,
 * write-through, and older-page loads from cache. Knows nothing about chat —
 * concrete children (e.g. ChatEngineDb) wire the store name, cursor, compare
 * function, and network fetcher.
 *
 * Concrete persistence plugs in via the protected abstract methods, which
 * IndexedDbStore implements. An in-memory Map fallback covers SSR/tests where
 * IndexedDB is unavailable.
 */

export interface Syncable {
  id: string
  /** Monotonic sort key used for older-page queries (e.g. created_at_nano). */
  sortKey: string | number
}

export interface SyncPage<T> {
  items: T[]
  nextCursor: string | null
  hasMore: boolean
}

export interface SyncDelta<T> extends SyncPage<T> {
  /** Cursor to persist after a successful delta (usually nextCursor). */
  cursorToSave: string | null
}

export interface SyncFetcher<T, C> {
  (cursor: string | null, limit: number, ctx: C): Promise<SyncDelta<T>>
}

/** Minimal store surface the engine needs. Implemented by IndexedDbStore. */
export interface SyncStore<T extends Syncable> {
  getAll(key: string, limit: number): Promise<T[]>
  putAll(key: string, items: T[]): Promise<void>
  getOlder(key: string, beforeSortKey: string | number, limit: number): Promise<T[]>
  getCursor(key: string): Promise<string | null>
  setCursor(key: string, cursor: string | null): Promise<void>
  clear(key: string): Promise<void>
}

export abstract class BaseSyncEngine<T extends Syncable, C = string> {
  /** In-memory fallback when IndexedDB is unavailable (SSR/tests). */
  private memItems = new Map<string, T[]>()
  private memCursors = new Map<string, string | null>()

  protected abstract storeOrNull(): SyncStore<T> | null
  protected abstract fetchDelta(cursor: string | null, limit: number, ctx: C): Promise<SyncDelta<T>>
  protected abstract cursorOf(item: T): string | null
  protected abstract compareFn(a: T, b: T): number

  protected memKey(ctx: C): string {
    return String(ctx)
  }

  private memGet(key: string): T[] {
    return this.memItems.get(key) ?? []
  }

  async getCursor(ctx: C): Promise<string | null> {
    const store = this.storeOrNull()
    const key = this.memKey(ctx)
    if (!store) return this.memCursors.get(key) ?? null
    try {
      return await store.getCursor(key)
    } catch {
      return this.memCursors.get(key) ?? null
    }
  }

  async setCursor(ctx: C, cursor: string | null): Promise<void> {
    const key = this.memKey(ctx)
    this.memCursors.set(key, cursor)
    const store = this.storeOrNull()
    if (!store) return
    try {
      await store.setCursor(key, cursor)
    } catch {
      // Best-effort: memory copy already updated.
    }
  }

  async clear(ctx: C): Promise<void> {
    const key = this.memKey(ctx)
    this.memItems.delete(key)
    this.memCursors.delete(key)
    const store = this.storeOrNull()
    if (!store) return
    try {
      await store.clear(key)
    } catch {
      // Best-effort.
    }
  }

  /** Cache-first read for mount: newest `limit` rows, already sorted. */
  async primeFromCache(ctx: C, limit: number): Promise<T[]> {
    const key = this.memKey(ctx)
    const store = this.storeOrNull()
    if (!store) return this.memGet(key).slice().sort(this.compareFn.bind(this)).slice(0, limit)
    try {
      const rows = await store.getAll(key, limit)
      // IDB returns ascending — ensure newest-first via compareFn.
      const sorted = rows.slice().sort(this.compareFn.bind(this))
      if (sorted.length > 0) this.memItems.set(key, sorted)
      return sorted
    } catch {
      return this.memGet(key).slice().sort(this.compareFn.bind(this)).slice(0, limit)
    }
  }

  /**
   * Cache-then-delta: return cached rows immediately when present, then fetch
   * the network delta, merge (dedupe by id), persist, and advance the cursor.
   * Returns the merged list plus whether the cache supplied the first paint.
   */
  async syncOnMount(
    ctx: C,
    limit: number,
  ): Promise<{ items: T[]; fromCache: boolean; delta: SyncDelta<T> | null }> {
    const cached = await this.primeFromCache(ctx, limit)
    let delta: SyncDelta<T> | null = null
    try {
      const cursor = await this.getCursor(ctx)
      delta = await this.fetchDelta(cursor, limit, ctx)
      const merged = this.merge(cached, delta.items)
      await this.putLocal(ctx, delta.items)
      if (delta.cursorToSave !== undefined) {
        await this.setCursor(ctx, delta.cursorToSave)
      }
      return { items: merged, fromCache: cached.length > 0, delta }
    } catch {
      return { items: cached, fromCache: cached.length > 0, delta }
    }
  }

  /** Best-effort write-through (e.g. SSE `full` handler). Never throws. */
  async putLocal(ctx: C, items: T[]): Promise<void> {
    if (items.length === 0) return
    const key = this.memKey(ctx)
    const merged = this.merge(this.memGet(key), items)
    this.memItems.set(key, merged)
    const store = this.storeOrNull()
    if (!store) return
    try {
      await store.putAll(key, items)
      this.memItems.set(key, await store.getAll(key, Math.max(merged.length, items.length)))
    } catch {
      // Memory copy already updated; IDB failure must not break the UI.
    }
  }

  /** Older-page read for scroll-back: cache first, empty miss = caller fetches. */
  async loadOlderFromCache(ctx: C, beforeSortKey: string | number, limit: number): Promise<T[]> {
    const key = this.memKey(ctx)
    const store = this.storeOrNull()
    if (!store) {
      return this.memGet(key)
        .filter((m) => this.sortKeyOf(m) < beforeSortKey)
        .sort(this.compareFn.bind(this))
        .slice(-limit)
    }
    try {
      return await store.getOlder(key, beforeSortKey, limit)
    } catch {
      return []
    }
  }

  protected sortKeyOf(item: T): string | number {
    return item.sortKey
  }

  /** Newest-first merge with id dedupe; order via compareFn. */
  protected merge(cached: T[], incoming: T[]): T[] {
    const seen = new Set(cached.map((m) => m.id))
    const fresh = incoming.filter((m) => !seen.has(m.id))
    return [...cached, ...fresh].sort(this.compareFn.bind(this))
  }
}

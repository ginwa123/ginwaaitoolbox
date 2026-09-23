/**
 * Session-list child of the generic sync engine (sidebar local-first).
 *
 * Mirrors ChatEngineDb: cache-then-revalidate over api.getChats, each row
 * keeping the full server object in `raw` so cached mounts render through
 * the single ChatsList mapper with no shape drift. The cache is
 * partitioned by workspace (`ctx` = workspace id, `'all'` when unscoped),
 * matching ChatsList's `scopedWorkspaceId` refetch boundary.
 *
 * Cursor note: the backend paginates with an opaque cursor pointing at
 * the last item's sort value (session_list.zig) — it pages *older*, so
 * it cannot serve as a "newer tail" delta cursor the way ChatEngineDb's
 * created_at_nano does. loadDelta therefore re-fetches page 1 (desc)
 * and merges by id (30 rows, cheap, always correct). Infinite-scroll
 * cursors stay component-local (chatsNextCursor); no sync cursor is
 * persisted.
 */
import * as api from '../api'
import type { Chat } from '../api'
import { BaseSyncEngine, type SyncDelta } from './SyncEngine'
import { IndexedDbStore } from './IndexedDbStore'

/** Full server row for one session (branch, timestamps, model...). */
export type SessionRawRow = Chat

export interface SessionRow {
  id: string
  /** `updated_at` wall-clock string — matches the backend `sort_by=updated_at` order. */
  sortKey: string
  /** Complete server object, so cached renders match the network shape. */
  raw: SessionRawRow
}

/** Workspace partition key: workspace id, or `'all'` when unscoped. */
export type SessionCtx = string

export function sessionSortKey(m: Chat): string {
  return m.updated_at || ''
}

export function toSessionRow(m: Chat): SessionRow {
  return {
    id: m.session_id,
    sortKey: sessionSortKey(m),
    raw: m,
  }
}

export interface SessionDelta extends SyncDelta<SessionRow> {
  total: number
}

export class SessionEngineDb extends BaseSyncEngine<SessionRow, SessionCtx> {
  private store: IndexedDbStore<SessionRow> | null = null

  constructor(
    // Namespace indirection (NOT a bare `getChats` import): the property
    // is read at call time so `vi.spyOn(api, 'getChats')` — the seam
    // every ChatsList spec uses — intercepts engine fetches too.
    private fetchFn: typeof api.getChats = (...args) => api.getChats(...args),
    storeName = 'sessions',
  ) {
    super()
    try {
      this.store = new IndexedDbStore<SessionRow>(storeName, 'sortKey')
    } catch {
      this.store = null
    }
  }

  protected storeOrNull(): IndexedDbStore<SessionRow> | null {
    return this.store
  }

  /** Newest-first: larger `updated_at` sorts earlier (ISO strings compare lexicographically). */
  compareFn(a: SessionRow, b: SessionRow): number {
    if (a.sortKey === b.sortKey) return 0
    return a.sortKey < b.sortKey ? 1 : -1
  }

  cursorOf(item: SessionRow): string | null {
    return item.sortKey || null
  }

  protected async fetchDelta(
    cursor: string | null,
    limit: number,
    ctx: SessionCtx,
  ): Promise<SyncDelta<SessionRow>> {
    const delta = await this.fetchDeltaPage(cursor, limit, ctx)
    return delta
  }

  /**
   * Page-1 revalidate: the backend cursor only pages older, so a stored
   * cursor is useless for "what's new" — always fetch the head of the
   * list desc and let the caller merge by id. `_cursor` is accepted for
   * the base-class contract and ignored.
   */
  async fetchDeltaPage(
    _cursor: string | null,
    limit: number,
    ctx: SessionCtx,
  ): Promise<SessionDelta> {
    const workspaceId = ctx === 'all' ? undefined : ctx
    const data = await this.fetchFn('updated_at', 'desc', limit, undefined, workspaceId)
    const items: SessionRow[] = (data.sessions ?? []).map(toSessionRow)
    return {
      items,
      nextCursor: data.next_cursor ?? null,
      hasMore: data.has_more ?? false,
      cursorToSave: data.next_cursor ?? null,
      total: data.total ?? items.length,
    }
  }

  /**
   * Background refresh for a cached mount: fetch page 1, persist it.
   * Never throws — IDB/network failure keeps the painted cache.
   */
  async loadDelta(ctx: SessionCtx, limit: number): Promise<SessionDelta | null> {
    try {
      const delta = await this.fetchDeltaPage(null, limit, ctx)
      await this.putLocal(ctx, delta.items)
      return delta
    } catch {
      return null
    }
  }

  /** Evict one session (SSE `deleted` / removeChat). Never throws. */
  async removeSession(ctx: SessionCtx, id: string): Promise<void> {
    try {
      await this.removeLocal(ctx, id)
    } catch {
      // Best-effort.
    }
  }
}

/** App-wide singleton used by ChatsList. */
export const sessionEngineDb = new SessionEngineDb()

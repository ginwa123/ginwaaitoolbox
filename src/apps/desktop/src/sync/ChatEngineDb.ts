/**
 * Chat child of the generic sync engine (Phase 2: cached mount + delta).
 *
 * Wires storeName='messages', cursorOf/compareFn over created_at_nano, and
 * fetchDelta over api.getChatHistory. Each row keeps the full server object
 * in `raw` so ChatView can render cached mounts through its single
 * toChatMessages mapper with no shape drift; sortKey stays created_at_nano
 * (created_at*1e9 fallback) for older-page queries.
 */
import { getChatHistory } from '../api'
import { BaseSyncEngine, type SyncDelta } from './SyncEngine'
import { IndexedDbStore } from './IndexedDbStore'

/** Full server row for one chat message (tool calls, images, reasoning...). */
export type ChatRawRow = Awaited<ReturnType<typeof getChatHistory>>['messages'][number]

export interface ChatMessage {
  id: string
  sortKey: number
  session_id: string
  created_at_nano: number
  created_at: number
  role: string
  content: string
  /** Complete server object, so cached renders match the network shape. */
  raw: ChatRawRow
}

export type ChatCtx = string

/**
 * Sync cursor for the next delta: the newest row seen so far.
 *
 * The backend only returns `next_cursor` when `has_more` is true, so it
 * cannot serve as the sync cursor — persisting it wipes a good cursor to
 * null after every small delta (and points at the oldest row on a full
 * page), forcing a full desc reload on the next mount. Advance to the
 * newest received row instead and never regress past the incoming cursor;
 * an empty delta keeps the previous cursor.
 */
export function newestCursor(
  items: ChatMessage[],
  nextCursor: string | null,
  prevCursor: string | null,
): string | null {
  let best: number | null = null
  const prev = prevCursor !== null ? Number(prevCursor) : NaN
  if (Number.isFinite(prev)) best = prev as number
  for (const m of items) {
    if (Number.isFinite(m.sortKey) && (best === null || m.sortKey > best)) best = m.sortKey
  }
  if (best !== null) return String(best)
  return nextCursor ?? prevCursor
}

/** Session metadata piggybacked on the messages endpoint (not cached). */
export interface ChatDeltaExtra {
  cwd?: string
  git_worktree_cwd?: string
  pr_url?: string
  pr_provider?: string
  selected_profile_model?: string
  max_total_tokens?: number
  max_capacity_total_tokens?: number
  skills?: Awaited<ReturnType<typeof getChatHistory>>['skills']
}

export interface ChatDelta extends SyncDelta<ChatMessage> {
  extra: ChatDeltaExtra
}

export function toChatMessage(ctx: ChatCtx, m: ChatRawRow): ChatMessage {
  const rawNano = (m as unknown as { created_at_nano?: number | string }).created_at_nano
  const nano =
    typeof rawNano === 'string'
      ? parseInt(rawNano, 10)
      : (rawNano ?? Math.floor(Number(m.created_at ?? 0) * 1e9))
  const safeNano = Number.isFinite(nano as number) ? (nano as number) : 0
  return {
    id: m.id,
    sortKey: safeNano,
    session_id: ctx,
    created_at_nano: safeNano,
    created_at: Number(m.created_at ?? 0),
    role: (m as { role?: string }).role ?? '',
    content: (m as { content?: string }).content ?? '',
    raw: m,
  }
}

export class ChatEngineDb extends BaseSyncEngine<ChatMessage, ChatCtx> {
  private store: IndexedDbStore<ChatMessage> | null = null

  constructor(
    private fetchFn: typeof getChatHistory = getChatHistory,
    storeName = 'messages',
  ) {
    super()
    try {
      this.store = new IndexedDbStore<ChatMessage>(storeName, 'sortKey')
    } catch {
      this.store = null
    }
  }

  protected storeOrNull(): IndexedDbStore<ChatMessage> | null {
    return this.store
  }

  /** Newest-first: larger created_at_nano sorts earlier. */
  compareFn(a: ChatMessage, b: ChatMessage): number {
    return b.sortKey - a.sortKey
  }

  cursorOf(item: ChatMessage): string | null {
    if (Number.isFinite(item.created_at_nano)) return String(item.created_at_nano)
    return String(item.sortKey)
  }

  protected async fetchDelta(
    cursor: string | null,
    limit: number,
    ctx: ChatCtx,
  ): Promise<SyncDelta<ChatMessage>> {
    const delta = await this.fetchDeltaPage(cursor, limit, ctx)
    return delta
  }

  /**
   * Newer-than-cursor fetch plus the session metadata the endpoint
   * piggybacks. A stored cursor means the cache already holds everything
   * before it, so ask ascending for just the tail; cold start (no cursor)
   * keeps the desc full load.
   */
  async fetchDeltaPage(cursor: string | null, limit: number, ctx: ChatCtx): Promise<ChatDelta> {
    const data = cursor
      ? await this.fetchFn(ctx, limit, cursor, 'asc')
      : await this.fetchFn(ctx, limit, undefined)
    const items: ChatMessage[] = (data.messages ?? []).map((m) => toChatMessage(ctx, m))
    return {
      items,
      nextCursor: data.next_cursor ?? null,
      hasMore: data.has_more ?? false,
      cursorToSave: newestCursor(items, data.next_cursor ?? null, cursor),
      extra: {
        cwd: data.cwd,
        git_worktree_cwd: data.git_worktree_cwd,
        pr_url: data.pr_url,
        pr_provider: data.pr_provider,
        selected_profile_model: data.selected_profile_model,
        max_total_tokens: data.max_total_tokens,
        max_capacity_total_tokens: data.max_capacity_total_tokens,
        skills: data.skills,
      },
    }
  }

  /**
   * Background refresh for a cached mount: fetch the tail, persist it,
   * advance the cursor. `preserveIds` prevents a response that started
   * before a live SSE update from overwriting that newer row. Never throws —
   * IDB/network failure keeps the painted cache.
   */
  async loadDelta(
    ctx: ChatCtx,
    limit: number,
    preserveIds: ReadonlySet<string> = new Set(),
  ): Promise<ChatDelta | null> {
    try {
      const cursor = await this.getCursor(ctx)
      const delta = await this.fetchDeltaPage(cursor, limit, ctx)
      const persistableItems = delta.items.filter((item) => !preserveIds.has(item.id))
      await this.putLocal(ctx, persistableItems)
      if (delta.cursorToSave !== undefined && persistableItems.length === delta.items.length) {
        await this.setCursor(ctx, delta.cursorToSave)
      }
      return delta
    } catch {
      return null
    }
  }
}

/** App-wide singleton used by ChatView. */
export const chatEngineDb = new ChatEngineDb()

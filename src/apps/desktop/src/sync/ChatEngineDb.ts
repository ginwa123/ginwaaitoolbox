/**
 * Chat child of the generic sync engine (Phase 1).
 *
 * Wires storeName='messages', cursorOf/compareFn over created_at_nano, and
 * fetchDelta over api.getChatHistory. ChatView keeps its own Message mapping
 * (toChatMessages); this module only persists the minimal fields needed for
 * cache-then-delta and older-page reads.
 */
import { getChatHistory } from '../api'
import { BaseSyncEngine, type SyncDelta } from './SyncEngine'
import { IndexedDbStore } from './IndexedDbStore'

export interface ChatMessage {
  id: string
  sortKey: number
  session_id: string
  created_at_nano: number
  created_at: number
  role: string
  content: string
}

export type ChatCtx = string

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
    const data = await this.fetchFn(ctx, limit, cursor ?? undefined)
    const items: ChatMessage[] = (data.messages ?? []).map((m) => {
      const nano =
        typeof (m as { created_at_nano?: number | string }).created_at_nano === 'string'
          ? parseInt((m as { created_at_nano?: string }).created_at_nano as string, 10)
          : ((m as { created_at_nano?: number }).created_at_nano ??
            Math.floor(Number(m.created_at ?? 0) * 1e9))
      return {
        id: m.id,
        sortKey: Number.isFinite(nano) ? (nano as number) : 0,
        session_id: ctx,
        created_at_nano: Number.isFinite(nano) ? (nano as number) : 0,
        created_at: Number(m.created_at ?? 0),
        role: (m as { role?: string }).role ?? '',
        content: (m as { content?: string }).content ?? '',
      }
    })
    return {
      items,
      nextCursor: data.next_cursor ?? null,
      hasMore: data.has_more ?? false,
      cursorToSave: data.next_cursor ?? null,
    }
  }
}

/** App-wide singleton used by ChatView. */
export const chatEngineDb = new ChatEngineDb()

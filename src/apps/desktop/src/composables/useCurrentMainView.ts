// src/apps/desktop/src/composables/useCurrentMainView.ts
import { computed, type ComputedRef } from 'vue'
import { useRoute } from 'vue-router'
import { parseItemIdWithChat } from '../helpers/buildItemIdWithChat'

/**
 * The single source of truth for "what is the main content area
 * currently showing?". Derived from the URL — never from store
 * flags that can drift.
 *
 * The sidebar components consume this to decide which row (if any)
 * is "active". Exactly one row in the sidebar should be active at
 * any time, and that row must match the kind + id below.
 *
 * ## URL contract (simplify-url-browser, 2026-08-15)
 *
 * The legacy `kind: 'task'` variant is gone. The chat-open state
 * is now encoded as a `/chat/<taskId>` suffix on the `itemId` query
 * value when `view=workspace`. Legacy `?view=task&task=X` URLs are
 * silently rewritten to the new shape in `AppLayout.onMounted`
 * before this composable is consulted — the composable itself
 * doesn't handle the legacy shape.
 *
 * Specs:
 *   - docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md
 *   - docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md
 */
export type CurrentMainView =
  | { kind: 'chat'; sessionId: string }
  | {
      kind: 'workspace'
      workspaceId?: string
      itemId: string
      pageId?: string
      chatTaskId?: string
    }
  | { kind: 'none' }

export function useCurrentMainView(): ComputedRef<CurrentMainView> {
  const route = useRoute()
  return computed<CurrentMainView>(() => {
    // Defensive: `useRoute()` returns undefined when called outside a
    // router context (some tests mount the component without mocking
    // vue-router). Treat that as an empty query → `kind: 'none'`.
    const q = (route?.query ?? {}) as Record<string, string>
    const view = q.view
    if (view === 'chat') {
      if (typeof q.session === 'string' && q.session.length > 0) {
        return { kind: 'chat', sessionId: q.session }
      }
      return { kind: 'none' }
    }
    if (view === 'workspace') {
      if (typeof q.itemId === 'string' && q.itemId.length > 0) {
        // Parse the wire-shape itemId (may carry `/chat/<taskId>`
        // suffix when the chat dialog is open). The bare id is
        // exposed as `itemId`; the optional chat task id is exposed
        // as `chatTaskId`. Consumers that need the raw wire value
        // should read `route.query.itemId` directly.
        const parsed = parseItemIdWithChat(q.itemId)
        return {
          kind: 'workspace',
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: parsed.itemId,
          pageId: typeof q.pageId === 'string' && q.pageId.length > 0 ? q.pageId : undefined,
          chatTaskId: parsed.chatTaskId ?? undefined,
        }
      }
      return { kind: 'none' }
    }
    return { kind: 'none' }
  })
}

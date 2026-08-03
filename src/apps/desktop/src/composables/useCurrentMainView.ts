// src/apps/desktop/src/composables/useCurrentMainView.ts
import { computed, type ComputedRef } from 'vue'
import { useRoute } from 'vue-router'

/**
 * The single source of truth for "what is the main content area
 * currently showing?". Derived from the URL — never from store
 * flags that can drift.
 *
 * The sidebar components consume this to decide which row (if any)
 * is "active". Exactly one row in the sidebar should be active at
 * any time, and that row must match the kind + id below.
 *
 * Why the URL and not the store?
 *   - The URL is the only state that survives a page refresh, a
 *     deep link, and the browser back/forward buttons. If the
 *     sidebar's active state is derived from the URL, the active
 *     row is always consistent with the main content area — no
 *     store flag can drift.
 *   - Multiple store flags (activeTaskId, activeWorkspaceItemId,
 *     activeDesignPageId, navigationStore.sessionId) are
 *     nearly-always-mutually-exclusive in practice but not
 *     enforced. Deriving from the URL guarantees mutual exclusivity.
 *
 * Spec: docs/superpowers/specs/2026-08-06-sidebar-single-active-state-design.md
 */
export type CurrentMainView =
  | { kind: 'chat'; sessionId: string }
  | { kind: 'task'; taskId: string; workspaceId?: string; itemId?: string }
  | { kind: 'workspace'; workspaceId?: string; itemId: string; pageId?: string }
  | { kind: 'none' }

export function useCurrentMainView(): ComputedRef<CurrentMainView> {
  const route = useRoute()
  return computed<CurrentMainView>(() => {
    const q = route.query as Record<string, string>
    const view = q.view
    if (view === 'chat') {
      if (typeof q.session === 'string' && q.session.length > 0) {
        return { kind: 'chat', sessionId: q.session }
      }
      return { kind: 'none' }
    }
    if (view === 'task') {
      if (typeof q.task === 'string' && q.task.length > 0) {
        return {
          kind: 'task',
          taskId: q.task,
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: typeof q.itemId === 'string' ? q.itemId : undefined,
        }
      }
      return { kind: 'none' }
    }
    if (view === 'workspace') {
      if (typeof q.itemId === 'string' && q.itemId.length > 0) {
        return {
          kind: 'workspace',
          workspaceId: typeof q.workspaceId === 'string' ? q.workspaceId : undefined,
          itemId: q.itemId,
          pageId: typeof q.pageId === 'string' && q.pageId.length > 0 ? q.pageId : undefined,
        }
      }
      return { kind: 'none' }
    }
    return { kind: 'none' }
  })
}
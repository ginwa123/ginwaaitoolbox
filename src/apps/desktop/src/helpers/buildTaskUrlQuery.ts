/**
 * buildTaskUrlQuery — helper that builds the URL query object for
 * `view=task` navigation. Ensures the URL always carries the
 * workspaceId (and itemId + pageId when applicable) so the user can
 * share / bookmark / refresh a task URL and land back on the
 * correct kanban or design page.
 *
 * Plan: docs/superpowers/plans/2026-08-06-add-workspace-id-params.md
 *
 * ## Why this exists (the bug)
 *
 * Before this helper, several Vue call sites wrote `view=task` URLs
 * with only `task` (and sometimes `itemId`), never `workspaceId`.
 * The user reported (task_1785774094183): *"add workspace_id params
 * when view the task, like in kanban mode or design mode"* — the
 * URL `?view=task&task=X&itemId=Y` was missing `workspaceId`, which
 * made the URL ambiguous (no workspace context visible in the bar)
 * and broke URL-based persistence for deep-link / refresh / share.
 *
 * The seven buggy call sites:
 *
 *   1. `Sidebar.handleSelectTask` — kanban/design → task navigation
 *   2. `Sidebar.handleAddTaskPick` — auto-create "Standard Chat" path
 *   3. `Sidebar.handleRunRoutine` — run a routine task
 *   4. `AppLayout.handleNavigate('task')` — dead branch (kept for
 *      symmetry with the workspace branch; covered for future
 *      re-enable)
 *   5. `AppLayout.closeGitViewer` else branch
 *   6. `AppLayout.closeSkillViewer` else branch
 *   7. `AppLayout.closeCodeEditor` else branch
 *
 * ## Algorithm
 *
 * Resolution order for workspaceId / itemId / pageId (first non-empty
 * wins, with gating rules):
 *
 *   1. Active store state (`activeWorkspaceId`, `activeWorkspaceItemId`,
 *      `activeDesignPageId`). This is the AUTHORITATIVE source — the
 *      user is actively viewing the kanban/design when they click the
 *      task, so the URL must reflect the current workspace context.
 *   2. Current URL breadcrumb (`route.query.workspaceId` etc.) — used
 *      as a fallback when no active store state exists (e.g. user
 *      landed on a deep-link task URL and we need to round-trip the
 *      breadcrumb to a new view transition).
 *
 * `pageId` is gated on the active item type being `'design'` to
 * avoid leaking a stale design page id into a kanban URL
 * (cross-leak bug fixed in `url-pageid-leak-design-to-non-design`,
 * 2026-08-06).
 *
 * `session` is included when the caller passes `sessionId` (used
 * by the routine-run path which historically included both `task`
 * and `session` — the `task.id == session_id` convention makes them
 * equal, but we keep the symmetric shape for backwards compatibility).
 *
 * ## Pure function
 *
 * No Vue / Pinia / vue-router imports — the caller passes in the
 * active state. This makes the helper trivially testable without
 * mounting components.
 */
import type { LocationQuery } from 'vue-router'

/** Subset of vue-router LocationQuery that we accept. */
export type UrlQueryInput = LocationQuery | Record<string, unknown>

export interface TaskUrlContext {
  /** The task id to put in `task=...` (required). */
  taskId: string
  /** Optional session id — used by the routine-run path (back-compat). */
  sessionId?: string
  /** Active workspace id from the store, or null if none. */
  activeWorkspaceId?: string | null | undefined
  /** Active workspace item id from the store, or null if none. */
  activeWorkspaceItemId?: string | null | undefined
  /** Active design page id from the store, or null if none. */
  activeDesignPageId?: string | null | undefined
  /**
   * Active workspace item's `item_type` from the store. Required to
   * gate `pageId` (design-only). Pass `undefined` to omit pageId
   * regardless of `activeDesignPageId`.
   */
  activeItemType?: string | null | undefined
  /**
   * Fallback current URL query (e.g. `route.query`). Used when no
   * active store state is available — preserves the breadcrumb
   * across a view transition so a refresh / share / back-button
   * still lands on the same context.
   */
  currentQuery?: UrlQueryInput | null | undefined
}

/**
 * Pick the breadcrumb params (`workspaceId`, `itemId`, `pageId`,
 * `sorts`) from a vue-router LocationQuery and return them as a
 * plain `Record<string, string>`. Used to preserve context when
 * APPENDing the URL on task click.
 *
 * Originally inlined in `Sidebar.vue::pickBreadcrumbFromQuery`
 * (better-url-browser plan, 2026-08-06). Now centralised so the
 * auto-create / routine-run / close-viewer paths share the same
 * extraction logic.
 *
 * Returns an empty object when the source query has no relevant
 * breadcrumb fields (e.g. user landed via deep link with no
 * workspace context).
 */
export function pickBreadcrumbFromQuery(
  query: Record<string, unknown>,
): Record<string, string> {
  const out: Record<string, string> = {}
  for (const key of ['workspaceId', 'itemId', 'pageId', 'sorts']) {
    const v = query[key]
    if (typeof v === 'string' && v.length > 0) out[key] = v
  }
  return out
}

/**
 * Build a URL query object for `view=task` navigation. Always
 * includes `task` and, when determinable, `workspaceId` / `itemId`
 * / `pageId` / `session`.
 *
 * See file header for the resolution algorithm and motivation.
 */
export function buildTaskUrlQuery(input: TaskUrlContext): Record<string, string> {
  const query: Record<string, string> = {
    view: 'task',
    task: input.taskId,
  }

  // Normalise inputs to strings (Vue refs can be string | null).
  const wsId = (input.activeWorkspaceId ?? '').toString().trim()
  const itemId = (input.activeWorkspaceItemId ?? '').toString().trim()
  const storePageId = (input.activeDesignPageId ?? '').toString().trim()
  const activeItemType = (input.activeItemType ?? '').toString()

  // Breadcrumb from current URL (used for fallback + for view-specific
  // params like sorts/pageId that live in the URL but not the store).
  const urlBreadcrumb = input.currentQuery
    ? pickBreadcrumbFromQuery(input.currentQuery as Record<string, unknown>)
    : {}

  // ─── workspaceId + itemId ────────────────────────────────────────
  // Resolution: active store state (authoritative) → URL fallback
  // (deep-link refresh / share-link round-trip). Both must be
  // present; otherwise omit (chat-only / unbound session).
  if (wsId && itemId) {
    query.workspaceId = wsId
    query.itemId = itemId
  } else if (urlBreadcrumb.workspaceId && urlBreadcrumb.itemId) {
    query.workspaceId = urlBreadcrumb.workspaceId
    query.itemId = urlBreadcrumb.itemId
  }

  // ─── pageId (design-only) ────────────────────────────────────────
  // Gate on active item type to avoid leaking a stale design page
  // id into a kanban URL (cross-leak bug fixed in
  // `url-pageid-leak-design-to-non-design`, 2026-08-06). Prefer
  // the store's `activeDesignPageId` when the active item is a
  // design; fall back to the URL's `pageId` for deep-link design
  // URLs where the store hasn't yet restored the page.
  const isActiveDesign = activeItemType === 'design'
  const urlPageId = urlBreadcrumb.pageId ?? ''
  if (isActiveDesign) {
    if (storePageId) {
      query.pageId = storePageId
    } else if (urlPageId) {
      query.pageId = urlPageId
    }
  }

  // ─── sorts (kanban view-specific, lives in URL only) ─────────────
  // The kanban per-column sort state (`?sorts=col_X:name:asc,...`)
  // lives in the URL and is NOT tracked by the workspaces store.
  // The user expects it to survive the workspace → task → workspace
  // round-trip (the close-restore flow in
  // AppLayout.handleCloseTaskView reads savedSortsParam, which is
  // snapshot from route.query.sorts at handleSelectTask time).
  // Preserve it in the new task URL so the URL stays self-describing
  // ("I'm on kanban X with sort S, viewing task Y").
  if (urlBreadcrumb.sorts) {
    query.sorts = urlBreadcrumb.sorts
  }

  // ─── session (routine-run path, back-compat) ─────────────────────
  // session is the chat session id (task.id == session_id
  // convention). The routine-run path historically included both
  // `task` and `session`; preserve the symmetric shape.
  if (input.sessionId) {
    query.session = input.sessionId
  }

  return query
}
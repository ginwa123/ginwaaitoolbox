/**
 * appUrl — the single builder / parser for the app's path-based URL
 * contract (plan: 2026-09-22-revamp-ui-chats-workspace-scoped).
 *
 * ## Contract
 *
 *   /app                                            landing (creates a workspace)
 *   /app/{workspaceId}                              workspace selected
 *   /app/{workspaceId}/chat/{sessionId}             chat open
 *   /app/{workspaceId}/projects/{projectId}         project open
 *   /app/{workspaceId}/projects/{projectId}/chat/{taskId}
 *                                                   task chat over a project
 *                                                   (path suffix — mirrors the
 *                                                   old `itemId/chat/T` suffix)
 *
 * Project sub-state stays in the query string: `?pageId=…&detail=…&sorts=…`.
 * Canonical form has NO trailing slash (the router accepts `/…/` and the
 * AppLayout rewrite strips it via `router.replace`).
 *
 * Unchanged: `/app/settings`, `/app/kanban/:itemId/settings`.
 * Legacy (rewritten once at boot to the shapes above, never emitted):
 * `/app/chat/:sid`, `/app/task/:tid`, and every `?view=…` query URL.
 *
 * ## Why this exists
 *
 * Before this helper, every navigation call site hand-built
 * `{ path: '/app', query: { view: 'workspace', … } }` objects inline
 * (~193 `view:` matches across src + specs). The path migration would
 * have scattered string concat everywhere; instead every writer goes
 * through `buildAppUrl` and every reader through `parseAppPath`, so
 * the contract lives in exactly one file.
 *
 * Pure functions — no Vue / Pinia / vue-router imports. Trivially testable.
 */

export interface AppUrlTarget {
  /** Workspace id. Absent → landing (`/app`). */
  workspaceId?: string | null | undefined
  /** Standalone chat session id (sidebar CHATS row). */
  chatSessionId?: string | null | undefined
  /** Project id (= workspace item id). */
  projectId?: string | null | undefined
  /** Task chat id open over a project (requires projectId). */
  chatTaskId?: string | null | undefined
  /** Project sub-state (pageId / detail / sorts / panel …). Passed through. */
  query?: Record<string, string> | null | undefined
}

export interface AppUrlLocation {
  path: string
  query: Record<string, string>
}

export type ParsedAppPath =
  | { kind: 'landing' }
  | { kind: 'workspace'; workspaceId: string }
  | { kind: 'chat'; workspaceId: string; sessionId: string }
  | { kind: 'project'; workspaceId: string; projectId: string }
  | { kind: 'projectChat'; workspaceId: string; projectId: string; chatTaskId: string }
  | { kind: 'other'; path: string }

/**
 * First path segments that are route keywords, never workspace ids.
 * Without this, `/app/chat/sess_9` would parse as workspace `chat` —
 * the legacy routes must stay `{ kind: 'other' }` so the boot rewrite
 * (not the normal view derivation) handles them.
 */
const RESERVED_FIRST_SEGMENTS = new Set(['chat', 'task', 'settings', 'kanban', 'projects'])

const nonEmpty = (v: string | null | undefined): v is string =>
  typeof v === 'string' && v.length > 0

/**
 * Build a router location for the given target. Always emits the
 * canonical no-trailing-slash path. Throws when the combination is
 * incoherent (chatTaskId without projectId, chatSessionId without
 * workspaceId, or a chatSessionId alongside a project).
 */
export function buildAppUrl(input: AppUrlTarget): AppUrlLocation {
  const workspaceId = (input.workspaceId ?? '').toString().trim()
  const chatSessionId = (input.chatSessionId ?? '').toString().trim()
  const projectId = (input.projectId ?? '').toString().trim()
  const chatTaskId = (input.chatTaskId ?? '').toString().trim()
  const query: Record<string, string> = { ...input.query }

  if (!workspaceId) {
    if (chatSessionId || projectId || chatTaskId) {
      throw new Error('buildAppUrl: workspaceId is required for chat/project targets')
    }
    return { path: '/app', query }
  }
  if (chatSessionId && (projectId || chatTaskId)) {
    throw new Error('buildAppUrl: chatSessionId cannot combine with a project target')
  }
  if (chatTaskId && !projectId) {
    throw new Error('buildAppUrl: chatTaskId requires projectId')
  }

  let path = `/app/${workspaceId}`
  if (chatSessionId) {
    path += `/chat/${chatSessionId}`
  } else if (projectId) {
    path += `/projects/${projectId}`
    if (chatTaskId) path += `/chat/${chatTaskId}`
  }
  return { path, query }
}

/**
 * Parse an app path into its kind + ids. Trailing slashes are ignored
 * (canonical form has none). Anything that is not one of the five app
 * shapes — settings, kanban-settings, legacy routes, unknown — comes
 * back as `{ kind: 'other', path }` so callers can fall through.
 */
export function parseAppPath(rawPath: string): ParsedAppPath {
  const path = normalizeAppPath(rawPath)
  if (path === '/app') return { kind: 'landing' }
  let m = /^\/app\/([^/]+)\/chat\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'chat', workspaceId: m[1], sessionId: m[2] }
  m = /^\/app\/([^/]+)\/projects\/([^/]+)\/chat\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2] && m[3]) {
    return { kind: 'projectChat', workspaceId: m[1], projectId: m[2], chatTaskId: m[3] }
  }
  m = /^\/app\/([^/]+)\/projects\/([^/]+)$/.exec(path)
  if (m?.[1] && m[2]) return { kind: 'project', workspaceId: m[1], projectId: m[2] }
  m = /^\/app\/([^/]+)$/.exec(path)
  if (m?.[1] && !RESERVED_FIRST_SEGMENTS.has(m[1])) return { kind: 'workspace', workspaceId: m[1] }
  return { kind: 'other', path }
}

/**
 * Canonicalize a path: strip trailing slashes (root `/` is kept).
 * `/app/ws_1/` → `/app/ws_1`. Ids never contain slashes in this
 * codebase, so a trailing slash is always noise, never content.
 */
export function normalizeAppPath(rawPath: string): string {
  if (typeof rawPath !== 'string' || rawPath.length === 0) return '/app'
  if (rawPath === '/') return '/'
  return rawPath.replace(/\/+$/, '') || '/'
}

/** True when the path is one of the five app shapes (landing included). */
export function isAppPath(rawPath: string): boolean {
  return parseAppPath(rawPath).kind !== 'other'
}

export interface LegacyAppUrl {
  /** The path-shape rewrite target, when the path alone decides it. */
  path: string | null
  /** Query params the rewrite must preserve (sorts/detail/pageId/tab…). */
  query: Record<string, string>
}

/**
 * Detect a legacy URL that needs the one-time boot rewrite to the path
 * contract. Returns null when the URL is already canonical.
 *
 * Legacy shapes:
 * - `/app/chat/:sid` → `/app/{ws}/chat/:sid` (ws resolved via session detail)
 * - `/app/task/:tid` → `/app/{ws}/projects/{item}/chat/:tid` (ws+item via task lookup)
 * - `?view=chat&session=X`, `?view=task&task=X…`, `?view=workspace&…` on `/app`
 * - any trailing-slash path (normalize only — no workspace lookup needed)
 *
 * The caller fills in the workspace-dependent path: this function reports
 * WHAT kind of legacy URL it is and carries the preservable query through.
 * Session/task → workspace resolution lives in AppLayout (it owns the
 * store + the session-detail `workspace_id` fetch), not here.
 */
export function detectLegacyAppUrl(
  rawPath: string,
  rawQuery: Record<string, unknown> | null | undefined,
): LegacyAppUrl | null {
  const path = typeof rawPath === 'string' ? rawPath : '/app'
  const query: Record<string, string> = {}
  if (rawQuery) {
    for (const [k, v] of Object.entries(rawQuery)) {
      if (typeof v === 'string' && v.length > 0) query[k] = v
    }
  }

  // Trailing slash on an otherwise-canonical path: normalize only.
  if (path !== normalizeAppPath(path) && isAppPath(path)) {
    return { path: normalizeAppPath(path), query }
  }

  // Legacy path routes (kept registered so AppLayout mounts for the rewrite).
  let m = /^\/app\/chat\/([^/]+)\/?$/.exec(path)
  if (m?.[1]) return { path: null, query: { ...query, __legacy: `chat:${m[1]}` } }
  m = /^\/app\/task\/([^/]+)\/?$/.exec(path)
  if (m?.[1]) return { path: null, query: { ...query, __legacy: `task:${m[1]}` } }

  // Legacy query URLs on /app.
  if (normalizeAppPath(path) === '/app' && nonEmpty(query.view)) {
    const view = query.view
    if (view === 'chat' || view === 'task' || view === 'workspace') {
      const { view: _dropped, ...rest } = query
      void _dropped
      return { path: null, query: { ...rest, __legacy: `view:${view}` } }
    }
  }
  return null
}

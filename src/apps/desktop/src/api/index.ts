// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls

import { createSseClient, type SseClient } from '../helpers/sseClient'

export const API_BASE = '/api'

import { useNotificationStore } from '../stores/notifications'

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly statusText: string,
    public readonly body: string,
  ) {
    super(`HTTP ${status} ${statusText}`)
    this.name = 'ApiError'
  }
}

export interface ApiFetchOptions extends Omit<RequestInit, 'body'> {
  body?: unknown
  /** When true, skip the error notification (caller handles UI inline). */
  silent?: boolean
}

/**
 * Centralized HTTP wrapper. Auto-fires a toast notification on 4xx/5xx
 * responses (unless `silent: true`). Throws `ApiError` on non-OK so
 * callers can still implement fallback UI.
 *
 * Network failures (fetch rejects) propagate WITHOUT a notification —
 * those are covered by SseStatusBadge for SSE, and a global offline
 * toast is out of scope for v1.
 */
export async function apiFetch<T = unknown>(
  url: string,
  opts: ApiFetchOptions = {},
): Promise<T> {
  const { body, silent, ...init } = opts

  const fetchInit: RequestInit = {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init.headers as Record<string, string> | undefined),
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  }

  const response = await fetch(`${API_BASE}${url}`, fetchInit)

  if (!response.ok) {
    const responseBody = await response.text().catch(() => '')

    if (!silent) {
      const parsedError = tryParseJsonErrorField(responseBody)
      const message = parsedError ?? `HTTP ${response.status} ${response.statusText}`
      const details = parsedError ? responseBody : responseBody || undefined
      useNotificationStore().notifyError(message, details)
    }

    throw new ApiError(response.status, response.statusText, responseBody)
  }

  // 204 No Content — return undefined cast to T
  if (response.status === 204) {
    return undefined as T
  }

  return (await response.json()) as T
}

function tryParseJsonErrorField(body: string): string | null {
  if (!body) return null
  try {
    const obj = JSON.parse(body)
    if (obj && typeof obj === 'object' && typeof obj.error === 'string') {
      return obj.error
    }
    return null
  } catch {
    return null
  }
}

// Re-export SseClient so call sites that hold a reference
// (e.g. `const workersSse: api.SseClient | null = null`) can
// import it from the same place they import the factory
// functions.
export type { SseClient } from '../helpers/sseClient'

// Types matching backend responses
export interface FolderEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

export interface FolderInfo {
  path: string
  absolute: string
  home: string
  parent?: string
  entries: FolderEntry[]
}

export interface Workspace {
  id: string
  name: string
  icon: string
  items: WorkspaceItem[]
  expanded: boolean
}

export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /**
   * Free-text description of the column's meaning (e.g. "Awaiting
   * code review — tasks here must pass CI before merge"). Empty
   * string when no description has been set. The Settings UI
   * renders an "Add a description..." placeholder for empty
   * values. Optional for backwards compat with legacy column
   * literals in test files (see nalar-frontend-task-literal-typing-rule).
   */
  description?: string | null
  position: number
  created_at: string
}

/**
 * Wire shape for `GET /api/workspaces/:wsId/items/:itemId/design/pages`
 * (list envelope) and `POST .../design/pages` (single page response).
 *
 * The numeric fields are `number` here even though the backend uses
 * `i64` — JSON has no integer/float distinction on the wire, so a
 * loose `number` keeps call sites that do arithmetic (e.g. position
 * comparisons) from fighting the type system. The backend's
 * `http_response.DesignPageResponse` (see src/ai_workflow/tui/http_handlers/
 * http_response.zig) is the canonical wire contract.
 *
 * Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
 *   (Chunk 5, Task 5.1)
 */
export interface DesignPage {
  id: string
  workspace_item_id: string
  name: string
  /**
   * 1:1 FK to `workspace_item_tasks.id`. Set at page-create time
   * by the backend; the frontend uses this directly to resolve the
   * page's chat task via `workspacesStore.setActiveTask(page.workspace_item_task_id)`
   * — no name matching, no legacy migration, no `taskHasMessages` probe.
   *
   * Story: introduced 2026-07-28 (plan:
   * docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md).
   * The previous design pattern-matched `"Design Chat: <page_name>"` against
   * `item.tasks` — fragile, silently broke on page renames, and left
   * orphan chat tasks when a page was deleted. The FK is the row-level
   * binding we're after.
   */
  workspace_item_task_id: string
  width: number
  height: number
  position: number
  created_at: string
  updated_at: string
}

/**
 * Element types emitted by the backend's `ElementType` enum
 * (src/ai_workflow/tui/design_model.zig). Wire form is the lowercase
 * `tagName` string; the backend maps it back to the enum at the
 * handler boundary.
 */
/**
 * Normalize the `type` field on a design element from the wire.
 *
 * The `GET /design/pages/:page_id` endpoint emits `type` (matches the
 * frontend contract). The `POST .../elements/move-batch` endpoint
 * historically emitted `elem_type` (a Zig struct field name — see
 * the `makeDesignElementResponse` doc in
 * `http_handlers/http_response.zig`). After a single move-batch the
 * local store was mirrored with elements missing `type`, so
 * `props.element.type === undefined` on every subsequent drag →
 * `isGroupLike = false` → `triggerGroupDrag = false` → the cascade
 * path silently switched to the single-element translate path.
 *
 * This function accepts BOTH shapes: `type` wins when present,
 * `elem_type` falls back. Once the backend lands the
 * `makeDesignElementResponse` change for move-batch, the
 * `elem_type` branch is dead code — but we keep it as defense in
 * depth so legacy backends (e.g. an old build that didn't get
 * the fix) can't break the canvas again.
 */
export const normalizeDesignElementType = <
  T extends { type?: DesignElementType; elem_type?: string },
>(
  e: T,
): T & { type: DesignElementType } => {
  const fallback: DesignElementType =
    (e.elem_type as DesignElementType) ?? 'rectangle'
  return { ...e, type: e.type ?? fallback }
}

export type DesignElementType =
  | 'rectangle'
  | 'ellipse'
  | 'text'
  | 'image'
  | 'frame'
  | 'group'

/**
 * Wire shape for design elements (the rows in
 * `design_page_elements`). Mirrors the backend's
 * `http_response.DesignElementResponse` struct — see
 * src/ai_workflow/tui/http_handlers/http_response.zig:709-734.
 *
 * Numeric fields are typed as `number` (not `i64`) because JSON has
 * no integer/float distinction; the backend serializes i64 values
 * as unquoted integers. `rotation` and `opacity` are f64 on the
 * backend; typed as `number` for the same reason.
 *
 * Optional string fields default to `''` on the backend (NOT NULL
 * DEFAULT ''), so an empty string is the "no value" sentinel for
 * `fill`, `stroke`, `text_content`, `text_style`, `image_url`,
 * `file_path`. The UI can therefore read these as truthy-or-empty
 * without nullability checks.
 */
export interface DesignElement {
  id: string
  page_id: string
  name: string
  type: DesignElementType
  x: number
  y: number
  width: number
  height: number
  rotation: number
  fill: string
  stroke: string
  stroke_width: number
  corner_radius: number
  opacity: number
  text_content: string
  text_style: string
  image_url: string
  file_path: string
  // NEW (Chunk 5 of grouped-layers plan): FK to a `group`/`frame`
  // element on the same page. Empty string `""` (NOT `null`) is the
  // wire form for NULL (matches the backend's empty-slice convention).
  // Optional because legacy elements returned by the API before this
  // field existed won't have it; the LayersPanel tree builder treats
  // `undefined` the same as `""` (top-level).
  parent_id?: string | null
  z_index: number
  position: number
  created_at: string
  updated_at: string
}

/**
 * Geometry-only patch payload for
 * `PATCH .../design/pages/:page_id/elements/:element_id/geometry`.
 * Every field is optional — the backend applies a sparse merge and
 * leaves omitted fields untouched. Used by the drag/resize
 * affordances in the canvas component (Chunk 7+).
 */
export interface DesignElementGeometry {
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/**
 * Wire shape for design-mode SSE events (the payload of
 * `design_element_created` / `design_element_updated` /
 * `design_element_deleted`).
 *
 * The backend emits all three with the same payload struct (see
 * `on_event_design.zig` — `DesignElement{Created,Updated,Deleted}Data`
 * are structurally identical). The `action` discriminator lets the
 * frontend route without needing separate interfaces.
 *
 * Field names match the backend's JSON keys: snake_case for ids
 * (matches the SSE wire format), `action` is the lowercase
 * discriminator string.
 */
export interface DesignElementEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  page_id: string
  element_id: string
  /**
   * Batch event variant (design_elements_geometry_batch_updated,
   * Chunk 3 of design-drag-debounce-batch). When set, the SSE
   * handler reads `element_ids` instead of `element_id` to drive
   * the local-mutation dedupe. Optional for backward compat with
   * existing single-element events.
   */
  element_ids?: string[]
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // The on-disk cwd for kanban items. Optional because:
  //   (a) legacy kanbans created before this field existed have no path
  //       (the API returns `null` from the DB, not `undefined`);
  //   (b) folder items (item_type = 'folder') never have a path here
  //       (their `path` lives on each FolderEntry child, not the item);
  //   (c) test fixtures in 5+ test files omit the field entirely.
  // Allow `null` so API responses with `path: null` (the SQLite NULL →
  // JSON null round-trip) type-check; the runtime `v-if="!item.path"`
  // already treats null AND undefined AND "" the same way.
  path?: string | null
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // `item_type === 'kanban'`; omitted for folder/chat/memory items.
  // Optional so legacy workspace-item literals (5+ test files
  // construct WorkspaceItem without this field) keep type-checking —
  // see the nalar-frontend-task-literal-typing-rule memory.
  kanban_columns?: KanbanColumn[]
}

export interface RoutineMeta {
  schedule: string
  initial_prompt: string
  enabled: boolean
  last_run_at: string | null
  next_run_at: string
  last_status: 'success' | 'failed' | 'running' | null
  last_error: string | null
}

export interface Task {
  id: string
  name: string
  description?: string
  // NEW (Chunk 5 of task-routines plan). Optional for backwards
  // compat with legacy task literals.
  task_type?: 'standard' | 'routine'
  // NEW: present iff task_type === 'routine'.
  routine?: RoutineMeta
  completed?: boolean
  createdAt?: Date
  // ISO datetime string from the backend; present for tasks returned by
  // getTasks() and used to sort/filter on the frontend. Backend stamps this
  // on every update (rename, complete, etc.).
  updatedAt?: Date
  // NEW (pinned-tasks feature, plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md).
  // Both optional so legacy task literals (8+ test files construct Task
  // without these fields) keep type-checking — see the
  // nalar-frontend-task-literal-typing-rule memory.
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // tasks under `item_type === 'kanban'` parents. `kanban_column_id`
  // is `null` (not undefined) when the task is unassigned (e.g. its
  // column was deleted). Both optional so legacy task literals keep
  // type-checking.
  kanban_column_id?: string | null
  kanban_position?: number
  // NEW (kanban task tags, Migration 067). Array of free-form tag
  // strings. Empty array = no tags. Optional so legacy task
  // literals in tests keep type-checking. On the wire the field is
  // a JSON-encoded array string; the store normalizes via
  // `normalizeTaskTags` at every fetch site.
  tags?: string[]
}

// Health check
export async function healthCheck(): Promise<{
  status: string
  timestamp: number
}> {
  return await apiFetch<{ status: string; timestamp: number }>('/health')
}

// System Folder API
export async function getSystemFolder(): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>('/system/folder?action=list')
}

export async function listFolder(path: string): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>(
    `/system/folder?path=${encodeURIComponent(path)}&action=list`,
  )
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  // Items are loaded separately via getWorkspacesItems(workspace_id) —
  // this keeps the workspaces list small and lets us fetch items lazily.
  return await apiFetch<{ workspaces: Workspace[] }>('/workspaces?is_include_items=false')
}

export async function getWorkspacesItems(
  workspace_id: string,
): Promise<{ items: WorkspaceItem[]; count: number }> {
  return await apiFetch<{ items: WorkspaceItem[]; count: number }>(
    `/workspaces/${workspace_id}/items`,
  )
}

export async function createWorkspace(name: string, icon: string = '📁'): Promise<Workspace> {
  return await apiFetch<Workspace>('/workspaces', {
    method: 'POST',
    body: { name },
  })
}

export async function getWorkspace(id: string): Promise<Workspace> {
  return await apiFetch<Workspace>(`/workspaces/${id}`)
}

export async function deleteWorkspace(id: string): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/${id}`, {
    method: 'DELETE',
  })
}

export async function updateWorkspace(id: string, data: Partial<Workspace>): Promise<Workspace> {
  return await apiFetch<Workspace>(`/workspaces/${id}`, {
    method: 'PUT',
    body: data,
  })
}

/**
 * Persist a new top-to-bottom display order for workspaces.
 * POST /api/workspaces/reorder with body `{ordered_ids: [...]}`. The
 * server reverses the array when assigning position values (top of
 * list = highest position). On any non-2xx response, throws
 * `new Error("HTTP <status>")` so the caller can roll back its
 * optimistic update.
 *
 * The list shape is the *full* ordered set, not a delta. Reordering
 * two adjacent rows means re-sending ALL workspace IDs in their new
 * order. The backend is idempotent — a second call with the same
 * array leaves the data unchanged.
 *
 * Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md
 */
export async function reorderWorkspaces(
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>('/workspaces/reorder', {
    method: 'POST',
    body: { ordered_ids: orderedIds },
  })
}

/**
 * Persist a new top-to-bottom display order for the items of a single
 * workspace. POST /api/workspaces/:workspace_id/items/reorder with
 * body `{ordered_ids: [...]}`. The server reverses the array when
 * assigning position values (top of list = highest position). On any
 * non-2xx response, throws `new Error("HTTP <status>")` so the caller
 * can roll back its optimistic update.
 *
 * Mirrors `reorderWorkspaces` but scoped to a single workspace's
 * items. The list shape is the *full* ordered set for that
 * workspace, not a delta.
 *
 * Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
 */
export async function reorderWorkspaceItems(
  workspaceId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/items/reorder`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}

// Task API
/**
 * Fetch tasks for a workspace item, with optional cursor pagination.
 *
 * @param workspaceId  - owning workspace
 * @param itemId       - workspace item (e.g. a project folder)
 * @param limit        - page size (default 20; backend clamps at 100)
 * @param cursor       - the encoded "<sort_value>|<id>" from the
 *                       previous page's `next_cursor`; pass undefined
 *                       for the first page
 * @param sortBy       - field to sort by: 'created_at' | 'updated_at'
 *                       | 'name'. Default: 'updated_at' (most recently
 *                       renamed task first). The backend uses this for
 *                       both ORDER BY and the cursor value.
 * @param direction    - 'asc' | 'desc'. Default: 'desc'.
 * @param q            - optional case-insensitive substring filter
 *                       applied at the SQL level against `name`,
 *                       `description`, and `tags`. Pass undefined or
 *                       '' to disable the filter. The backend escapes
 *                       `%`/`_`/`\` in the input before binding, so a
 *                       user typing `%` matches a literal `%` in the
 *                       data (not every row). Pagination advances
 *                       through the filtered set, not the unfiltered
 *                       set, when q is set.
 * @returns `{ tasks, has_more, next_cursor }`. `next_cursor` is null
 *          when there are no more pages.
 */
export async function getTasks(
  workspaceId: string,
  itemId: string,
  limit = 20,
  cursor?: string,
  sortBy: 'created_at' | 'updated_at' | 'name' = 'updated_at',
  direction: 'asc' | 'desc' = 'desc',
  q?: string,
): Promise<{
  tasks: Task[]
  has_more: boolean
  next_cursor: string | null
}> {
  const params = new URLSearchParams()
  params.set('limit', String(limit))
  params.set('sort_by', sortBy)
  params.set('direction', direction)
  if (cursor) {
    params.set('cursor', cursor)
  }
  if (q && q.length > 0) {
    params.set('q', q)
  }
  const data = await apiFetch<{
    tasks: Task[]
    has_more: boolean
    next_cursor: string | null
  }>(`/workspaces/${workspaceId}/items/${itemId}/tasks?${params.toString()}`)
  return {
    tasks: data.tasks ?? [],
    has_more: data.has_more ?? false,
    next_cursor: data.next_cursor ?? null,
  }
}

/**
 * Stamp `workspace_item_tasks.last_human_touched_at` so the kanban
 * card flips from the orange "AI finished — awaiting review" dot
 * to the green "reviewed" checkmark. Fire-and-forget: the caller
 * does NOT await this — failures log a warning but don't surface
 * as toasts (the user's primary action has already succeeded).
 *
 * Idempotent on the server side (re-stamping is harmless — the
 * column is just a monotonic timestamp). The backend also emits
 * a `kanban_task.human_touched` SSE event so other connected
 * clients refresh without a manual round-trip.
 *
 * Plan: docs/plans/2026-07-26-kanban-task-notification-icon.md
 *   (Chunk 7 — frontend open-task stamp).
 */
export async function markTaskHumanTouched(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  return apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/touched`,
    { method: 'PUT' },
  )
}

/**
 * Create a task under a workspace item.
 *
 * The third arg is a single params object. For a standard task
 * (the default), pass `{ name, description?, taskType: 'standard' }`.
 * For a routine, pass `{ name, taskType: 'routine', routine: { schedule, initial_prompt, enabled? } }`.
 * For a memory, pass `{ name, taskType: 'memory', memory: { name, content } }`.
 *
 * The backend stores `task_type` on `workspace_item_tasks` and
 * (for routines) creates a row in the `routines` table inside the
 * same transaction. For memories, the backend creates the .md file
 * at `<workspace_item.path>/.nalar/memories/<name>.md` AND inserts
 * the task row pointing at it. On a bad cron expression, the
 * backend returns 400 and the error surfaces as a thrown
 * `Error('HTTP 400')`.
 */
export async function createTask(
  workspaceId: string,
  itemId: string,
  params: {
    name: string
    description?: string
    taskType?: 'standard' | 'routine' | 'memory'
    routine?: {
      schedule: string
      initial_prompt: string
      enabled?: boolean
    }
    memory?: {
      name: string
      content: string
    }
    // Auto-retry-until-stop (Migration 063, Option A fix): when the
    // caller passes `'1'`, the backend ALSO inserts a `sessions`
    // row (task.id == session.id per the project convention) so the
    // unattended-mode flag has somewhere to land at create time.
    // Only meaningful for `taskType: 'standard'` — routine and
    // memory tasks manage their own session lifecycle elsewhere.
    // `'0'` and undefined/empty are treated equivalently (no
    // session INSERT).
    isAutoRetryUntilStop?: string
    // Kanban task tags (Migration 067 — kanban task tags feature).
    // Array of free-form tag strings. Empty array / undefined = no
    // tags. Forwarded as a JSON-encoded array string on the wire.
    // The backend validates (char whitelist [a-zA-Z0-9_-], length
    // cap 50 chars per tag, case-insensitive dedupe). Plan:
    // docs/superpowers/plans/2026-07-28-kanban-task-tags.md.
    tags?: string[]
  },
): Promise<Task> {
  const taskType = params.taskType ?? 'standard'
  const body: Record<string, unknown> = {
    name: params.name,
    description: params.description,
    task_type: taskType,
  }
  if (taskType === 'routine' && params.routine) {
    body.schedule = params.routine.schedule
    body.initial_prompt = params.routine.initial_prompt
    if (params.routine.enabled !== undefined) {
      body.enabled = params.routine.enabled
    }
  }
  if (taskType === 'memory' && params.memory) {
    body.memory_name = params.memory.name
    body.memory_content = params.memory.content
  }
  // Only forward the unattended flag when the user actually flipped
  // it ON. Default '0' is the no-op default — sending it would
  // trigger an unnecessary session INSERT (a new row per task).
  if (params.isAutoRetryUntilStop === '1' && taskType === 'standard') {
    body.is_auto_retry_until_stop = '1'
  }
  // Forward tags as a JSON-encoded array string (Migration 067).
  // The backend's tags_validation.validateAndNormalizeTags parses
  // and re-encodes the array, so the wire shape is a JSON string,
  // not an array — single source of truth for JSON shape.
  if (params.tags && params.tags.length > 0) {
    body.tags = JSON.stringify(params.tags)
  }
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks`, {
    method: 'POST',
    body,
  })
}

export async function updateTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  data: Partial<Task>,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    {
      method: 'PUT',
      body: data,
    },
  )
}

// Task API - Simple version (just task_id + optional fields)
//
// The backend's PUT /api/workspaces/tasks/:task_id accepts a
// subset of fields. Routine fields (`schedule`, `initial_prompt`,
// `enabled`) are accepted alongside the standard name/session_id.
// The server cascades any name change to the linked session and
// re-broadcasts via SSE.
export async function updateTaskSimple(
  taskId: string,
  data: {
    name?: string
    session_id?: string
    // NEW (kanban-task-detail-dialog plan): the per-task description
    // shown in the detail dialog. Empty string = clear (the
    // dialog's "Clear description" path sends `''`).
    description?: string
    // NEW (Chunk 5 of task-routines plan): routine-edit fields,
    // forwarded verbatim to the backend's PUT handler. The server
    // applies them to the routines row in the same transaction.
    schedule?: string
    initial_prompt?: string
    enabled?: boolean
    // NEW (kanban task tags, Migration 067): array of tag strings.
    // Forwarded as JSON-encoded string. Empty array = clear tags.
    tags?: string[]
  },
): Promise<{ success: boolean }> {
  const body: Record<string, unknown> = { ...data }
  // Encode tags array as a JSON string for the wire (Migration 067).
  if (data.tags !== undefined) {
    body.tags = JSON.stringify(data.tags)
  }
  return await apiFetch<{ success: boolean }>(`/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    body,
  })
}

export async function deleteTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: 'DELETE' },
  )
}

/**
 * Pin or unpin a task. The backend bumps the row's
 * `pinned_position` to MAX+1 (when pinning) so a newly-pinned task
 * lands at the BOTTOM of the pinned region; the user can drag it
 * to a different position afterwards. Returns the new
 * `pinned_position` so the store can confirm the row landed where
 * the user expects.
 *
 * 404: task not found
 * 500: DB write failed
 */
export async function pinTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
): Promise<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }> {
  return await apiFetch<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/pin`,
    {
      method: 'POST',
      body: { is_pinned: isPinned },
    },
  )
}

/**
 * Reorder the pinned subset of a single workspace item. The
 * `orderedIds` array is the full top-to-bottom display order of
 * the pinned rows. The backend assigns `pinned_position =
 * count - 1 - i` so the rows render in the user's chosen order.
 *
 * Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md
 */
export async function reorderPinnedTasks(
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/reorder_pinned`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}

/**
 * Manually fire a routine. Returns the session_id (which equals
 * the task_id per the codebase invariant task.id == session_id)
 * the routine will run in. The backend responds 200 + body as
 * soon as the sub-process is spawned — the actual LLM call
 * happens asynchronously.
 *
 * 404: task is not a routine (or doesn't exist)
 * 409: routine is disabled or another fire is in progress
 * 500: spawn failed
 */
export async function runRoutine(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ session_id: string }> {
  return await apiFetch<{ session_id: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/run`,
    { method: 'POST' },
  )
}

// Chat API - Zig Backend Integration (Zig backend calls LLM backend internally)
export interface Chat {
  session_id: string
  session_name?: string
  status?: string
  selected_profile_model?: string
  /// Migration 063 — "0" / "1" opt-in for unattended mode. Always
  /// present in the GET /api/sessions response (ChatsList uses this
  /// to render the `🔁 unattended` badge).
  is_auto_retry_until_stop?: string
}

export interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  created_at: number
  tool_name?: string
  tool_call_id?: string
  diffview_before?: string
  diffview_after?: string
  image_url?: string
  tool_calls_json?: any
  finish_reason?: string,
  is_input?: boolean,
  is_output?: boolean
}

export interface SkillInfo {
  skill_name: string
  content: string
  loaded_at?: number
}

// All chat endpoints go through Zig backend at /api/llm/*
// Zig backend internally calls LLM backend

// Parse timestamp - backend sends nanoseconds as string, convert to seconds
function parseTimestamp(ts: number | string): number {
  const num = typeof ts === 'string' ? parseInt(ts, 10) : ts
  // If timestamp looks like nanoseconds (> 1e12), convert to seconds
  return num > 1e12 ? Math.floor(num / 1e9) : num
}
export async function getChatHistory(
  sessionId: string,
  limit = 50,
  cursor?: string,
): Promise<{
  messages: Message[]
  has_more: boolean
  next_cursor: string | null
  cwd?: string
  git_worktree_cwd?: string
  /// Session's selected profile name (empty/missing = "Default", i.e.
  /// no profile selected). Mirrors the backend `sessions.selected_profile_model`
  /// column. Populated by the backend's `GET /api/llm/session/:id/messages`
  /// handler so the chatview's profile chip survives a page refresh
  /// (fixes "profiles in chatview not persistent" — the chatview
  /// dropdown writes via PUT /api/llm/session/:id but the read endpoint
  /// never returned the value, so the chip reset to "Default" on
  /// refresh).
  selected_profile_model?: string
  max_total_tokens?: number
  max_capacity_total_tokens?: number
  total_count?: number
  skills?: SkillInfo[]
}> {
  try {
    const params = new URLSearchParams({
      sort_by: 'created_at',
      direction: 'desc',
      limit: limit.toString(),
    })
    if (cursor) {
      params.set('cursor', cursor)
    }
    // silent: true — AppLayout.fetchChatSessionCwd swallows this
    // error to fall back to a message-derived cwd, so a toast on
    // 404/5xx would be noise.
    const data = await apiFetch<any>(
      `/llm/session/${sessionId}/messages?${params}`,
      { silent: true },
    )
    return {
      messages: data.messages.map(
        (msg: {
          id: string
          role: string
          content: string
          created_at: number | string
          tool_name?: string
          diffview_before?: string
          diffview_after?: string
          image_url?: string
          tool_calls_json?: any
        }) => ({
          ...msg,
          content: msg.content,
          created_at: parseTimestamp(msg.created_at),
          tool_name: msg.tool_name,
          diffview_before: msg.diffview_before,
          diffview_after: msg.diffview_after,
          image_url: msg.image_url,
          tool_calls_json: msg.tool_calls_json,
        }),
      ),
      has_more: data.has_more,
      next_cursor: data.next_cursor,
      cwd: data.cwd,
      git_worktree_cwd: data.git_worktree_cwd,
      // 2026-08-07-profile-persist-read — read the per-session
      // selected profile name so the chatview chip can show the
      // persisted selection on page refresh. Empty string from the
      // backend (= "no profile set") is preserved here; ChatView
      // coerces empty → null before assigning to selectedProfile.
      selected_profile_model: data.selected_profile_model,
      max_total_tokens: data.max_total_tokens,
      max_capacity_total_tokens: data.max_capacity_total_tokens,
      total_count: data.total_count,
      skills: data.skills,
    }
  } catch (error) {
    // Return empty messages when LLM backend unavailable
    console.log(error)
    return {
      messages: [],
      has_more: false,
      next_cursor: null,
      cwd: undefined,
      git_worktree_cwd: undefined,
      // 2026-08-07-profile-persist-read — preserve the field shape on
      // the error path so ChatView's `loadChatHistory` branch can
      // safely read `data.selected_profile_model` (it'll be
      // `undefined`, which ChatView coerces to `null`).
      selected_profile_model: undefined,
      max_total_tokens: undefined,
      max_capacity_total_tokens: undefined,
      total_count: undefined,
    }
  }
}

// Send a message to LLM
//
// Migration 063 — adds the optional `isAutoRetryUntilStop` flag.
// "1" opts into unattended mode (the workflow re-reads this column
// on entry and soft-bails past retry_count > 10). Default undefined
// = today's behavior.
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,
  isAutoRetryUntilStop?: string,
): Promise<{ status: string }> {
  // Join image URLs with pipe separator (same format as other parts of the system)
  const imageUrlsStr = imageUrls?.join('|') || ''

  try {
    // silent: true — ChatView already surfaces these failures inline
    // (e.g. the LLM-not-configured banner) and the new global
    // notification system would duplicate the message.
    return await apiFetch<{ status: string }>(
      '/llm/session',
      {
        method: 'POST',
        body: {
          session_id: sessionId,
          queue_message: message,
          allowed_tools: 'all',
          cwd_session: cwdSession,
          image_urls: imageUrlsStr,
          selected_profile_model: selectedProfile || '',
          // Migration 063 — pass through to POST /api/session. Empty
          // / undefined => the backend's default ("0" = off).
          is_auto_retry_until_stop: isAutoRetryUntilStop ?? '',
        },
        silent: true,
      },
    )
  } catch (err) {
    // Preserve the original return-shape semantics so ChatView can
    // branch on `status` for user-facing messages:
    //   'bad_request'         — backend 400
    //   'unprocessable_entity'— backend 422
    //   'http_error'          — backend 4xx/5xx other than the above
    //   'offline'             — network failure / fetch rejected
    if (err instanceof ApiError) {
      if (err.status === 400) return { status: 'bad_request' }
      if (err.status === 422) return { status: 'unprocessable_entity' }
      return { status: 'http_error' }
    }
    return { status: 'offline' }
  }
}

// Update an existing session (selectedProfile, name, isAutoRetryUntilStop).
//
// Migration 063 — extends the update shape to carry the unattended-
// mode flag. Pass `isAutoRetryUntilStop: '0'` to disable, '1' to
// enable, or omit to leave unchanged (matches the backend's
// `len > 0` guard).
export async function updateSession(
  sessionId: string,
  updates: {
    selectedProfile?: string | null
    name?: string
    isAutoRetryUntilStop?: string
  },
): Promise<{ id: string; name: string; status: string; selected_profile_model: string; is_auto_retry_until_stop: string }> {
  return await apiFetch<{
    id: string
    name: string
    status: string
    selected_profile_model: string
    is_auto_retry_until_stop: string
  }>(
    `/llm/session/${sessionId}`,
    {
      method: 'PUT',
      body: {
        selected_profile_model: updates.selectedProfile ?? '',
        name: updates.name ?? '',
        is_auto_retry_until_stop: updates.isAutoRetryUntilStop ?? '',
      },
    },
  )
}

// SSE event types matching the backend
// Note: Backend sends events without explicit 'type' field in data.
// The 'finish_reason' field indicates message completion.
export interface SseEvent {
  session_id: string
  id?: string
  content?: string
  role?: string
  finish_reason?: string
  reasoning_content?: string
  tool_calls?: any
  tool_call_id?: string
  tool_name?: string
  agent_name?: string
  loop_index?: number
  temperature?: number
  is_thinking?: boolean
  is_input?: boolean,
  is_output?: boolean,
  parent_session_id?: string
  parent_id?: string
  created_at?: number
  // Legacy type field for compatibility (not used by backend)
  type?: 'chunk' | 'reasoning_chunk' | 'chunk_final' | 'tool_call_delta' | 'connected' | 'full'
  index?: number
  total_tokens?: number
  // Diff view data for text_replace tool
  diffview_before?: string
  diffview_after?: string
  // Pipe-separated image URLs (matches the REST SessionMessageResponse
  // shape and the backend onEventSendLLMHistory payload). Frontend
  // splits on '|' to populate Message.image_urls. Null for messages
  // without attached images (most assistant responses, error paths,
  // tool results that don't carry image data).
  image_url?: string
}

// List all chat sessions with pagination
export async function getChats(
  sortBy: 'created_at' | 'updated_at' | 'session_name' | 'agent' = 'created_at',
  direction: 'asc' | 'desc' = 'desc',
  limit: number = 10,
  cursor?: string,
): Promise<{
  sessions: Chat[]
  has_more: boolean
  next_cursor: string | null
  total: number
}> {
  try {
    const params = new URLSearchParams({
      sort_by: sortBy,
      direction: direction,
      limit: limit.toString(),
    })
    if (cursor) {
      params.set('cursor', cursor)
    }
    const data = await apiFetch<{
      sessions: any[]
      has_more?: boolean
      next_cursor?: string | null
      total?: number
    }>(`/llm/session?${params}`)

    // Fix: handle "undefined" or missing session_id in each session
    if (data.sessions && Array.isArray(data.sessions)) {
      data.sessions = data.sessions.map((session: any) => {
        const sessionId = session.session_id || session.id
        if (!sessionId || sessionId === 'undefined' || sessionId === 'null') {
          // Generate proper session ID for invalid entries
          const timestamp = new Date()
            .toISOString()
            .replace(/[:-]/g, '')
            .replace('T', '_')
            .replace(/\.\d{3}Z$/, '')
          return {
            session_id: `session_${timestamp}`,
            session_name: session.session_name || session.name || 'New Session',
            status: session.status || 'active',
            created_at: session.created_at || null,
            updated_at: session.updated_at || null,
            cwd: session.cwd || '',
          }
        }
        return {
          session_id: sessionId,
          session_name: session.session_name || session.name || 'New Session',
          status: session.status || 'active',
          created_at: session.created_at || null,
          updated_at: session.updated_at || null,
          cwd: session.cwd || '',
          // Migration 063 — default to "0" (off) when omitted so the
          // ChatsList badge condition `=== '1'` is a defined check.
          // Matches the SQL COALESCE default in llm_history.zig.
          is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
        }
      })
    }

    return {
      sessions: data.sessions || [],
      has_more: data.has_more || false,
      next_cursor: data.next_cursor || null,
      total: data.total || 0,
    }
  } catch (error) {
    // Return empty sessions when LLM backend unavailable (apiFetch
    // also fires a toast notification on non-2xx; the empty-array
    // fallback ensures the UI doesn't crash while the user sees
    // the error).
    return { sessions: [], has_more: false, next_cursor: null, total: 0 }
  }
}

// Legacy chat functions (kept for compatibility)
export interface ChatLegacy {
  id: string
  label: string
  icon: string
  active?: boolean
}

export async function getChatsLegacy(): Promise<{ chats: ChatLegacy[] }> {
  return await apiFetch<{ chats: ChatLegacy[] }>('/chats')
}

export async function createChat(name: string, icon: string = '💬'): Promise<ChatLegacy> {
  return await apiFetch<ChatLegacy>('/chats', {
    method: 'POST',
    body: { name, icon },
  })
}

export async function deleteChat(id: string): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/chats/${id}`, { method: 'DELETE' })
}

// Session API - Fetch session info including cwd
export interface Session {
  sessionId: string
  cwd: string
  createdAt: string
  agent: string
  sessionName: string
  selectedProfile?: string
  // Bound git worktree path (empty string when no worktree is bound;
  // optional because older sessions predate the set_git_worktree tool).
  git_worktree_cwd?: string
}

export async function getSession(sessionId: string): Promise<Session | null> {
  try {
    // Use the same endpoint as getChatHistory - it returns session info including cwd
    // silent: true — AppLayout.fetchChatSessionCwd swallows this
    // error to fall back to a message-derived cwd, so a toast on
    // 404/5xx would be noise.
    const data = await apiFetch<{
      cwd?: string
      messages?: { session_name?: string }[]
      // 2026-08-07-profile-persist-read — extract the per-session
      // selected profile name. Without this, the watch in ChatView
      // that loads `selectedProfile` from `getSession()` would always
      // see undefined and clobber any value loaded earlier from
      // `getChatHistory()`. The backend's GET messages endpoint
      // returns it via `SessionMessageResponse.selected_profile_model`.
      selected_profile_model?: string
    }>(`/llm/session/${sessionId}/messages?limit=1`, { silent: true })
    // The session info is in the cwd field - construct session object
    return {
      sessionId: sessionId,
      cwd: data.cwd || '',
      createdAt: '',
      agent: '',
      sessionName: data.messages?.[0]?.session_name || '',
      // 2026-08-07-profile-persist-read — pass through the persisted
      // profile name. Empty string (= "no profile set" from the
      // backend's COALESCE-on-NULL) is preserved here; ChatView
      // coerces empty → null.
      selectedProfile: data.selected_profile_model,
    }
  } catch (error) {
    console.error('Failed to get session:', error)
    return null
  }
}

// Compact chat session history
export async function compactSession(
  sessionId: string,
): Promise<{ success: boolean; message?: string }> {
  try {
    return await apiFetch<{ success: boolean; message?: string }>(
      `/session/${sessionId}/compact`,
      { method: 'POST' },
    )
  } catch (error) {
    console.error('Failed to compact session:', error)
    return { success: false, message: 'Failed to compact session' }
  }
}

// Worker API
export interface Worker {
  id: string
  session_id: string
  working_directory: string | null
  last_activity: string | null
  last_activity_description: string | null
  created_at: string | null
  status: string
  is_running: boolean
  queue_count: number
}

export async function getWorkers(
  status?: string,
  limit = 50,
  sessionId?: string,
): Promise<{ workers: Worker[]; count: number }> {
  const params = new URLSearchParams({ limit: limit.toString() })
  if (status) params.set('status', status)
  if (sessionId) params.set('session_id', sessionId)
  return await apiFetch<{ workers: Worker[]; count: number }>(`/workers?${params}`)
}

// Workspace Item API
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path: string,
  itemType: string = 'folder',
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items`, {
    method: 'POST',
    body: { name, path, item_type: itemType },
  })
}

/**
 * Create a new design workspace item (`item_type='design'`). The
 * `path` is REQUIRED because design elements live as HTML files
 * under `<path>/.nalar/design/...` (the model layer rejects
 * element-add with `ItemPathMissing` if path is NULL — see
 * design_model.zig).
 *
 * Mirrors `createKanban(workspaceId, name, path)` but requires the
 * path (no cwd-less design). Returns the new `WorkspaceItem`.
 *
 * POST /api/workspaces/:workspaceId/items/design
 */
export async function createDesign(
  workspaceId: string,
  name: string,
  path: string,
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(
    `/workspaces/${workspaceId}/items/design`,
    {
      method: 'POST',
      body: { name, path },
    },
  )
}

export async function deleteWorkspaceItem(
  workspaceId: string,
  itemId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}`,
    { method: 'DELETE' },
  )
}

// Kanban API
//
// Backend endpoints (Chunk 3 of the workspace-item-kanban plan):
//   POST   /api/workspaces/:wsId/items/kanban                 → 201
//   GET    /api/workspaces/:wsId/items/:itemId/kanban/columns → 200
//   POST   /api/workspaces/:wsId/items/:itemId/kanban/columns → 201
//   PATCH  /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId → 200
//   DELETE /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId → 200
//   PATCH  /api/workspaces/:wsId/items/:itemId/tasks/:taskId/move        → 200
//
// All wrappers route through `apiFetch` (NOT raw `fetch`) so the
// error-toast-on-non-2xx contract is consistent with the rest of the
// app. On 4xx/5xx the call throws `ApiError`; the toast is fired
// before the throw so the user sees the message inline.

/**
 * Create a new kanban workspace item. The backend seeds three default
 * columns (todo / in progress / done) and returns the item plus the
 * freshly-created columns so the caller can render the board without
 * a second round-trip.
 *
 * POST /api/workspaces/:workspaceId/items/kanban
 */
export async function createKanban(
  workspaceId: string,
  name: string,
  path?: string,
): Promise<{ item: WorkspaceItem; columns: KanbanColumn[] }> {
  return await apiFetch<{ item: WorkspaceItem; columns: KanbanColumn[] }>(
    `/workspaces/${workspaceId}/items/kanban`,
    {
      method: 'POST',
      body: { name, path: path ?? '' },
    },
  )
}

/**
 * Update a workspace item. Supports partial updates — pass only
 * the fields you want to change.
 *
 * Fields:
 *   - `item_type`: new type (kanban / folder / chat / memory). The
 *     caller historically always sent this; current callers may
 *     omit it when only `name`/`path` change (the backend treats a
 *     missing `item_type` as "leave unchanged" since the rename
 *     branch doesn't read it).
 *   - `path`: new on-disk path (kanban cwd) or `null` to clear.
 *     Presence-detected by the backend (omitted → leave unchanged,
 *     `null` or `""` → clear, non-empty string → set).
 *   - `name`: new display name (used by the Kanban Settings rename
 *     pencil and the KanbanView header pencil). Presence-detected
 *     and rejected with 400 if empty/null.
 *
 * PUT /api/workspaces/:workspaceId/items/:itemId
 *
 * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
 */
export async function updateWorkspaceItem(
  workspaceId: string,
  itemId: string,
  data: {
    item_type?: string
    path?: string | null
    name?: string
  },
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(
    `/workspaces/${workspaceId}/items/${itemId}`,
    {
      method: 'PUT',
      body: data,
    },
  )
}

/**
 * List the kanban columns for a single workspace item, ordered by
 * `position` ASC.
 *
 * GET /api/workspaces/:workspaceId/items/:itemId/kanban/columns
 */
export async function listKanbanColumns(
  workspaceId: string,
  itemId: string,
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
  )
}

/**
 * Add a new column to a kanban. `position` is optional — when omitted
 * the backend appends at the end of the existing sequence
 * (max(position)+1). Returns the newly-created column (with its
 * server-assigned `id` and `position`).
 *
 * POST /api/workspaces/:workspaceId/items/:itemId/kanban/columns
 */
export async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  description?: string,
  position?: number,
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
    {
      method: 'POST',
      body: { name, description: description ?? '', position },
    },
  )
}

/**
 * Copy a kanban's column spec (names + descriptions, preserving
 * order) from a source kanban to a target kanban. Tasks are NOT
 * copied — only the column "template". Destructive for the target:
 * in `replace` mode, the target's existing columns are deleted
 * (with task unassignment) and replaced with copies of the
 * source's. In `append` mode, the source's columns are appended
 * after the target's existing MAX(position).
 *
 * Returns the target's new full column list `{columns, count}`
 * (same envelope as `listKanbanColumns`). The frontend replaces
 * its local `kanban_columns` array with this list in one round
 * trip — backend's atomic emit/replace pattern matches every
 * other kanban mutation endpoint.
 *
 * POST /api/workspaces/:workspaceId/items/:itemId/kanban/copy_spec_from/:sourceItemId
 *
 * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
 *   (Chunk 3, Task 3.1)
 */
export async function copyKanbanSpec(
  workspaceId: string,
  targetItemId: string,
  sourceItemId: string,
  mode: 'replace' | 'append' = 'replace',
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${targetItemId}/kanban/copy_spec_from/${sourceItemId}`,
    {
      method: 'POST',
      body: { mode },
    },
  )
}

/**
 * Patch a kanban column. Both `name` and `position` are optional;
 * pass only the fields you want to change. The backend applies the
 * patch and re-numbers sibling positions when `position` changes.
 *
 * Returns the FULL updated board (`{columns, count}`) — same envelope
 * as `listKanbanColumns`. The backend emits the full board on every
 * successful PATCH so the frontend never needs a follow-up GET to see
 * the post-rename ordering or sibling positions. The store replaces
 * its local `kanban_columns` array with the backend's returned list
 * (defensively re-sorted by position), so sibling columns (which the
 * backend may have renumbered when `position` changed) are mirrored
 * in the same round-trip.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/kanban/columns/:columnId
 */
export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; description?: string; position?: number },
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    {
      method: 'PATCH',
      body: patch,
    },
  )
}

/**
 * Delete a kanban column. Tasks in the column are unassigned
 * (kanban_column_id set to NULL) — they remain visible in the
 * folder-list view as "Unassigned". Idempotent: a 200 is returned
 * whether the column existed or not (handled by the backend).
 *
 * DELETE /api/workspaces/:workspaceId/items/:itemId/kanban/columns/:columnId
 */
export async function deleteKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    { method: 'DELETE' },
  )
}

/**
 * Move a task to a new column and position within that column. The
 * backend's `moveTask` does the move + sibling re-numbering in a
 * single transaction. Returns the updated task with the new
 * `kanban_column_id` and `kanban_position` so the caller can confirm
 * the move landed where expected.
 *
 * PATCH /api/workspaces/:workspaceId/items/:itemId/tasks/:taskId/move
 */
export async function moveTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  columnId: string,
  position: number,
): Promise<Task> {
  return await apiFetch<Task>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/move`,
    {
      method: 'PATCH',
      body: { column_id: columnId, position },
    },
  )
}

/** Plan: docs/superpowers/plans/2026-07-30-kanban-task-tags-autocomplete.md */

export interface KanbanTagSuggestion {
  name: string
  count: number
  last_used_at: string | null
}

export interface KanbanTagSuggestionsResponse {
  tags: KanbanTagSuggestion[]
  has_more: boolean
}

export interface GetKanbanTagSuggestionsOptions {
  limit?: number
  offset?: number
}

export async function getKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: GetKanbanTagSuggestionsOptions,
): Promise<KanbanTagSuggestionsResponse> {
  const limit = options?.limit ?? 8
  const offset = options?.offset ?? 0
  // Defensive: empty args = no-op (returns empty + has_more=false).
  // Prevents 400s when the caller passes placeholder values during
  // the render tick (e.g. dialog opens before column is resolved).
  if (!workspaceId || !itemId) {
    return { tags: [], has_more: false }
  }
  const url = `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/kanban/tags?limit=${limit}&offset=${offset}`
  // Graceful degradation: a 5xx returns empty + has_more=false so a
  // broken server doesn't block the user from typing tags.
  try {
    const res = await apiFetch<KanbanTagSuggestionsResponse>(url, { method: 'GET' })
    return {
      tags: res.tags ?? [],
      has_more: res.has_more ?? false,
    }
  } catch {
    return { tags: [], has_more: false }
  }
}

// =====================================================================
// Design Mode API (v6 — Figma-lite, file-backed HTML model)
// =====================================================================
//
// 9 endpoints for the new design-mode surface, replacing the v5
// panzoom-canvas API. The backend (src/ai_workflow/tui/http_handlers/
// design_*.zig + src/ai_workflow/tui/design_model.zig) is fully
// implemented and tested; this section is the thin TypeScript wrapper.
//
// Every endpoint routes through the per-request arena on the backend,
// so the responses are built via `std.json.Stringify.valueAlloc` and
// are guaranteed to be valid JSON with all user-provided content
// (HTML bodies, names) properly escaped.
//
// Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
//   (Chunk 5, Task 5.1 + 5.2)

/**
 * GET /api/workspaces/:workspaceId/items/:itemId/design/pages
 *
 * List all pages in a design workspace item, ordered by `position`
 * ascending. Returns `{ pages, count }` envelope.
 */
export async function listDesignPages(
  workspaceId: string,
  itemId: string,
): Promise<{ pages: DesignPage[]; count: number }> {
  return await apiFetch<{ pages: DesignPage[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages`,
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages
 *
 * Create a new design page. The backend assigns `id`, `position`,
 * `created_at`, `updated_at`. The new page is appended at the end
 * of the current position order.
 *
 * Returns 201 Created with the full DesignPage record.
 */
export async function createDesignPage(
  workspaceId: string,
  itemId: string,
  name: string,
): Promise<DesignPage> {
  return await apiFetch<DesignPage>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages`,
    { method: 'POST', body: { name } },
  )
}

/**
 * PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 *
 * Update an existing design page's width/height. Backend validates
 * the ranges (width 320-4096, height 240-4096); out-of-range returns
 * 400 with an explicit error message so the UI can surface it.
 *
 * Returns 200 OK with the full DesignPage record.
 */
export async function updateDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
  patch: { width: number; height: number },
): Promise<DesignPage> {
  return await apiFetch<DesignPage>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'PATCH', body: patch },
  )
}

/**
 * GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 *
 * Fetch a single page plus its full element list (HTML bodies
 * EXCLUDED — fetch lazily via `getDesignElementHtml` as the user
 * selects each element, to keep the list-page payload small for
 * designs with many elements).
 */
export async function getDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ page: DesignPage; elements: DesignElement[] }> {
  return await apiFetch<{ page: DesignPage; elements: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements
 *
 * Add a new element to a page. Required body fields: `name`, `type`,
 * `html`. All other DesignElement fields are optional and fall back to
 * the backend's defaults (`x=y=width=height=rotation=0`, `fill=''`,
 * etc.) when omitted.
 *
 * The `html` body is written to a per-element file at
 * `<item.path>/.design/<page_id>/<element_id>.html` BEFORE the DB
 * insert, so a DB failure after the file write leaves an orphan —
 * the backend reaps orphans on the next insert for the same page.
 *
 * Returns 201 Created with the full DesignElement record.
 */
export async function addDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: {
    name: string
    type: DesignElementType
    html: string
    [k: string]: any
  },
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements`,
    { method: 'POST', body },
  )
}

/**
 * PUT /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId
 *
 * Full update of an element. The body shape is `Partial<DesignElement>` —
 * any subset of fields can be patched. The backend applies the patch
 * as a sparse merge (omitted fields left unchanged).
 *
 * Returns the full updated DesignElement record (so the frontend can
 * sync its local Pinia store from the response).
 */
export async function updateDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  patch: Partial<DesignElement>,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}`,
    { method: 'PUT', body: patch },
  )
}

/**
 * Wire shape for `POST .../design/pages/:pageId/elements/group`.
 * NEW (Chunk 5 of grouped-layers plan). Body fields:
 *   - `child_ids`: required, 2+ element ids on the SAME page. The
 *     backend rejects cross-page children with 400 (ChildAcrossDifferentPages)
 *     and already-parented children with 409 (ChildAlreadyParented).
 *   - `name`: optional, default `"Group"`. The new parent element's
 *     `name` field.
 *   - `type`: optional, default `'group'`. Valid values: `'group'`
 *     (non-clipping logical bundle) or `'frame'` (clipping container).
 */
export interface GroupDesignElementsRequest {
  child_ids: string[]
  name?: string
  type?: 'group' | 'frame'
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/group
 *
 * NEW (Chunk 5 of grouped-layers plan). Wraps 2+ elements into a new
 * `group` (or `frame`) parent at the union bbox of the children. The
 * backend sets `parent_id` on each child to the new group's id in a
 * single transaction.
 *
 * Response 201: `{ parent: DesignElement, children: DesignElement[] }`.
 * Error shape: 400 (BadChildId / ChildAcrossDifferentPages), 404
 * (PageNotFound), 409 (ChildAlreadyParented).
 */
export async function groupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: GroupDesignElementsRequest,
): Promise<{ parent: DesignElement; children: DesignElement[] }> {
  return await apiFetch<{ parent: DesignElement; children: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/group`,
    { method: 'POST', body },
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reorder
 *
 * NEW (Chunk 5 of right-click group menu plan). Reorders 1+ elements
 * on a page along the z-axis. The 4 modes:
 *   - `bring_to_front`: selected ids jump above all non-selected elements
 *     in the user-specified input order (first id = topmost).
 *   - `send_to_back`: mirror of bring_to_front (first id = bottommost).
 *   - `bring_forward`: each selected swaps with its next non-selected
 *     sibling above (the multi-selection moves up by one slot).
 *   - `send_backward`: mirror of bring_forward.
 *
 * Response 200: `{ reordered: DesignElement[] }` — the updated rows
 * in their new top-to-bottom z-order.
 *
 * Error shape: 400 (BadMode / NoElementIds / EmptyElementIds /
 * BadElementId / ChildAcrossDifferentPages), 404 (PageNotFound),
 * 409 (CrossPageIds).
 */
export type ReorderMode = 'bring_to_front' | 'send_to_back' | 'bring_forward' | 'send_backward'

export interface ReorderDesignElementsRequest {
  mode: ReorderMode
  element_ids: string[]
}

export async function reorderDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReorderDesignElementsRequest,
): Promise<{ reordered: DesignElement[] }> {
  return await apiFetch<{ reordered: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reorder`,
    { method: 'POST', body },
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/reparent-batch
 *
 * NEW (Chunk 1b of drag-to-reparent plan). Atomic N-element reparent
 * in a single transaction. Used by the LayersPanel drag-and-drop
 * affordance so dragging 1 or N selected rows into a group uses ONE
 * round-trip instead of N parallel PUTs. The whole batch is
 * all-or-nothing — if ANY element would close a cycle, the batch
 * fails with 400 BadReparent and no DB writes happen.
 *
 * Body shape: `{ element_ids: [...], new_parent_id: ... | null,
 *                reposition: 'last_in_parent' }`.
 *
 * Response 200: `{ updated: DesignElement[] }` in input order.
 *
 * Error shape: 400 (EmptyElementIds / BadElementId / BadNewParentId /
 * BadReparent), 404 (PageNotFound), 409 (CrossPageIds).
 */
export interface ReparentDesignElementsBatchRequest {
  element_ids: string[]
  /** null = top-level (leave any current group). */
  new_parent_id: string | null
  /** Currently only "last_in_parent" is supported. */
  reposition: 'last_in_parent'
}

export interface ReparentDesignElementsBatchResponse {
  updated: DesignElement[]
}

export async function reparentDesignElementsBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  body: ReparentDesignElementsBatchRequest,
): Promise<ReparentDesignElementsBatchResponse> {
  return await apiFetch<ReparentDesignElementsBatchResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/reparent-batch`,
    { method: 'POST', body },
  )
}

/**
 * DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId
 *
 * Idempotent delete. Returns `{ success: true }` whether the row
 * existed or not (the backend returns 200 either way — a missing
 * element is not a 404 here because the canonical "I want this gone"
 * semantic should be idempotent).
 */
export async function deleteDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}`,
    { method: 'DELETE' },
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/ungroup
 *
 * Dissolve a `group` or `frame` element: reparent its direct children
 * to the group's parent (or top-level if the group had no parent), then
 * delete the group row. Children keep their absolute x/y — their geometry
 * is independent of the group's bbox.
 *
 * Body: `{ element_id: 'elem_g' }`.
 *
 * Response 200: `{ orphaned: DesignElement[] }` — the children in their
 * new post-reparent state.
 *
 * Error shape: 400 (BadGroupId / NotAGroup / EmptyGroup), 500 (DbError).
 */
export async function ungroupDesignElements(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ orphaned: DesignElement[] }> {
  return await apiFetch<{ orphaned: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/ungroup`,
    { method: 'POST', body: { element_id: elementId } },
  )
}

/**
 * DELETE /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId
 *
 * Delete a design page. The backend (design_model.deletePage) handles
 * the SQL DELETE on design_pages (FK ON DELETE CASCADE cleans up the
 * child design_page_elements rows) and recursively rmdirs the
 * on-disk `<item_path>/.nalar/design/<sanitized_page_name>/` folder.
 *
 * UI-only — no LLM tool exposes this endpoint, only the DesignView
 * tab-strip × button. Returns 200 with `{success:true}`. 404 if the
 * page didn't exist (idempotent — caller treats 404 as success).
 *
 * Plan: docs/superpowers/plans/2026-07-25-design-page-delete-button.md
 *   (Chunk 2)
 */
export async function deleteDesignPage(
  workspaceId: string,
  itemId: string,
  pageId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}`,
    { method: 'DELETE' },
  )
}

/**
 * GET /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html
 *
 * Lazy-load a single element's HTML body. Used by the iframe preview
 * component as the user selects elements — avoids loading all
 * bodies up-front in the page+elements GET response.
 */
export async function getDesignElementHtml(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
): Promise<{ html: string }> {
  return await apiFetch<{ html: string }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/html`,
  )
}

/**
 * PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/html
 *
 * Persist a new HTML body for an element. Triggered by the
 * contenteditable / Monaco save flow — the content is the user-
 * edited inner HTML of the element's iframe.
 *
 * Returns the full updated DesignElement record.
 */
export async function updateDesignElementHtml(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  html: string,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/html`,
    { method: 'PATCH', body: { html } },
  )
}

/**
 * PATCH /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/geometry
 *
 * ⚠️  DEPRECATED — replaced by `translateDesignElement` (move) and
 * `resizeDesignElement` (resize). Kept for back-compat with any
 * existing client still wired to the old endpoint. See
 * `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
 *
 * Geometry-only update path — separate from the full PUT for two
 * reasons: (1) drag/resize fires 60+/sec, so the smaller payload +
 * sparser validation saves backend CPU; (2) the SSE event is
 * emitted at lower frequency for geometry vs. text/html updates
 * (the `update` event fires for HTML changes; geometry uses the
 * same `update` event but the frontend debounces by diffing).
 *
 * Returns the full updated DesignElement record.
 */
export async function updateDesignElementGeometry(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: DesignElementGeometry,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/geometry`,
    { method: 'PATCH', body: geometry },
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/translate
 *
 * NEW (2026-08-06) — single-element translate (move). The body
 * carries a `(dx, dy)` DELTA (not absolute `x, y`). If the target
 * element is a `group`/`frame`, the server cascades the delta to
 * every transitive descendant via the existing recursive CTE.
 *
 * Returns `{updated: [DesignElement, ...]}`:
 *   - 1 element for leaves
 *   - 1 + N elements for group/frame cascade (root + every cascadee)
 *
 * Replaces `updateDesignElementGeometry` for the move use case
 * (delta-based). See
 * `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
 */
export async function translateDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  dx: number,
  dy: number,
): Promise<{ updated: DesignElement[] }> {
  return await apiFetch<{ updated: DesignElement[] }>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/translate`,
    { method: 'POST', body: { dx, dy } },
  )
}

/**
 * POST /api/workspaces/:workspaceId/items/:itemId/design/pages/:pageId/elements/:elementId/resize
 *
 * NEW (2026-08-06) — single-element resize. The body carries
 * absolute `(x, y, width, height, rotation?)` fields. At least one
 * field is required. Resize NEVER cascades (Figma convention — only
 * the dragged element's bounding box changes; children keep their
 * own positions).
 *
 * Returns the single updated DesignElement.
 *
 * Replaces `updateDesignElementGeometry` for the resize use case.
 * See `docs/superpowers/plans/2026-08-06-split-move-resize.md`.
 */
export async function resizeDesignElement(
  workspaceId: string,
  itemId: string,
  pageId: string,
  elementId: string,
  geometry: DesignElementGeometry,
): Promise<DesignElement> {
  return await apiFetch<DesignElement>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/${elementId}/resize`,
    { method: 'POST', body: geometry },
  )
}

/**
 * Per-element geometry patch for the batch endpoint. All fields are
 * optional; null means "leave unchanged". Mirror of the single
 * `updateDesignElementGeometry` shape but reusable for N elements.
 */
export interface GeometryBatchUpdate {
  element_id: string
  x?: number
  y?: number
  width?: number
  height?: number
  rotation?: number
}

/**
 * Response from `POST .../geometry-batch`. `updated` is the
 * post-batch element list in input order.
 */
export interface GeometryBatchUpdateResponse {
  updated: DesignElement[]
}

/**
 * Atomic N-element geometry update. Used by the canvas drag handler
 * when multiple elements are selected (multi-element drag, group /
 * frame being moved) so the N per-element PATCHes collapse into ONE
 * PATCH per pointermove. Combined with the trailing-edge debounce in
 * `useDesignDragDebounce`, this drops the request rate from ~200
 * req/sec to ~2 req/sec for a 5-element drag.
 *
 * Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
 *   (Chunk 3, Task 3.1)
 */
export async function updateDesignElementsGeometryBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  updates: GeometryBatchUpdate[],
): Promise<GeometryBatchUpdateResponse> {
  return await apiFetch<GeometryBatchUpdateResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/geometry-batch`,
    { method: 'POST', body: { updates } },
  )
}

/**
 * Server-side cascade move. Each item's `(dx, dy)` applies to the
 * element AND every transitive descendant of that element via a
 * single recursive CTE inside one SQL transaction. Optional
 * `width`/`height`/`rotation` apply ONLY to the root element (Figma
 * convention — resize is per-element, not per-subtree).
 *
 * Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
 *   (Chunk 3, Task 3.1)
 */
export interface MoveBatchItem {
  element_id: string
  /** Translation delta in CSS px. Cascades to descendants. */
  dx: number
  dy: number
  /** Optional. Applies ONLY to the element_id (not descendants). */
  width?: number
  height?: number
  rotation?: number
}

export interface MoveBatchInput {
  items: MoveBatchItem[]
}

export interface MoveBatchResponse {
  updated: DesignElement[]
}

export async function moveDesignElementsBatch(
  workspaceId: string,
  itemId: string,
  pageId: string,
  input: MoveBatchInput,
): Promise<MoveBatchResponse> {
  return await apiFetch<MoveBatchResponse>(
    `/workspaces/${workspaceId}/items/${itemId}/design/pages/${pageId}/elements/move-batch`,
    { method: 'POST', body: input },
  )
}

// Skills API
export interface Skill {
  name: string
  description: string
  path?: string
}

export interface SkillDetail extends Skill {
  content: string
  is_global: boolean
}

export interface SkillDeleteResponse {
  success: boolean
  skill_name: string
  deleted_from: string | null
  error_message: string | null
}

export async function getSkills(cwd?: string): Promise<{
  global_skills: Skill[]
  local_skills: Skill[]
}> {
  const params = new URLSearchParams()
  if (cwd) {
    params.set('cwd', cwd)
  }
  const query = params.toString() ? `?${params.toString()}` : ''
  return await apiFetch<{ global_skills: Skill[]; local_skills: Skill[] }>(`/skills${query}`)
}

export async function getSkillDetail(
  name: string,
  cwd?: string,
): Promise<{ skill: SkillDetail | null; error_message: string | null }> {
  const params = new URLSearchParams()
  if (cwd) {
    params.set('cwd', cwd)
  }
  const query = params.toString() ? `?${params.toString()}` : ''
  return await apiFetch<{ skill: SkillDetail | null; error_message: string | null }>(
    `/skills/${encodeURIComponent(name)}${query}`,
  )
}

export async function deleteSkill(
  name: string,
  options: { is_global?: boolean; cwd?: string },
): Promise<SkillDeleteResponse> {
  const params = new URLSearchParams({ name })
  if (options.is_global !== undefined) {
    params.set('is_global', options.is_global.toString())
  }
  if (options.cwd) {
    params.set('cwd', options.cwd)
  }
  return await apiFetch<SkillDeleteResponse>(`/skills?${params}`, {
    method: 'DELETE',
  })
}

// Memories API
export interface Memory {
  name: string
  title: string
  path: string
  size: number
}

export interface MemoryDetail extends Memory {
  content: string
}

export interface MemoryDetailResponse {
  memory: MemoryDetail | null
  error_message: string | null
}

export interface MemoryDeleteResponse {
  success: boolean
  name: string
  error_message: string | null
}

export async function getMemories(): Promise<{ memories: Memory[] }> {
  return await apiFetch<{ memories: Memory[] }>('/memories')
}

export async function getMemoryDetail(name: string): Promise<MemoryDetailResponse> {
  try {
    return await apiFetch<MemoryDetailResponse>(
      `/memories/${encodeURIComponent(name)}`,
    )
  } catch (err) {
    // Preserve the "404 = not found" semantics — the caller uses the
    // returned shape to decide whether to show a "create new memory"
    // prompt vs. an error toast. apiFetch surfaces 404 as ApiError,
    // so we translate it back into the original { memory: null,
    // error_message } shape.
    if (err instanceof ApiError && err.status === 404) {
      return { memory: null, error_message: 'Memory not found' }
    }
    throw err
  }
}

export async function createMemory(name: string, content: string): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>('/memories', {
    method: 'POST',
    body: { name, content },
  })
}

export async function updateMemory(name: string, content: string): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>(
    `/memories/${encodeURIComponent(name)}`,
    {
      method: 'PUT',
      body: { content },
    },
  )
}

export async function deleteMemory(name: string): Promise<MemoryDeleteResponse> {
  return await apiFetch<MemoryDeleteResponse>(
    `/memories/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

// Local Memories API (per-cwd memories at `<cwd>/.nalar/memories/`).
//
// Distinct from the global memories above: local memories are scoped
// to a specific project directory (the cwd) and are auto-injected
// into every chat as the "Local Knowledge" section of the system
// prompt (see `loadLocalKnowledge` in
// `src/modules/agent/prompts.zig`). The `cwd` is passed in the body
// (POST/PUT) or the query string (GET/DELETE) and is required for
// the request to be useful. The backend falls back to the nalar
// server's CWD when no cwd is provided.

/**
 * Build the `cwd` query string for a local-memory request.
 * Returns the `?cwd=...` suffix, or `''` if `cwd` is empty.
 */
function cwdQuery(cwd?: string): string {
  if (!cwd) return ''
  const encoded = encodeURIComponent(cwd)
  return `?cwd=${encoded}`
}

export async function listLocalMemories(cwd?: string): Promise<{ memories: Memory[] }> {
  return await apiFetch<{ memories: Memory[] }>(`/local-memories${cwdQuery(cwd)}`)
}

export async function getLocalMemoryDetail(
  name: string,
  cwd?: string,
): Promise<MemoryDetailResponse> {
  try {
    return await apiFetch<MemoryDetailResponse>(
      `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    )
  } catch (err) {
    // Preserve the "404 = not found" semantics — the caller uses
    // the returned shape to decide whether to show a "create new
    // memory" prompt vs. an error toast. apiFetch surfaces 404 as
    // ApiError, so we translate it back into the original
    // { memory: null, error_message } shape.
    if (err instanceof ApiError && err.status === 404) {
      return { memory: null, error_message: 'Memory not found' }
    }
    throw err
  }
}

export async function createLocalMemory(
  name: string,
  content: string,
  cwd: string,
): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>('/local-memories', {
    method: 'POST',
    body: { name, content, cwd },
  })
}

export async function updateLocalMemory(
  name: string,
  content: string,
  cwd?: string,
): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>(
    `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    {
      method: 'PUT',
      body: { content, cwd },
    },
  )
}

export async function deleteLocalMemory(
  name: string,
  cwd?: string,
): Promise<MemoryDeleteResponse> {
  return await apiFetch<MemoryDeleteResponse>(
    `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    { method: 'DELETE' },
  )
}

// Git Status API
export interface GitStatus {
  is_git_repo: boolean
  branch: string
  has_changes: boolean
  is_clean: boolean
  current: string
  status: string
}

export interface GitFileChange {
  index_status: string
  worktree_status: string
  path: string
}

export interface GitChangesResponse {
  is_git_repo: boolean
  branch: string | null
  has_changes: boolean
  staged_files: GitFileChange[]
  modified_files: GitFileChange[]
  untracked_files: GitFileChange[]
}

export async function getGitStatus(cwd: string): Promise<GitStatus> {
  try {
    return await apiFetch<GitStatus>(`/git/status?path=${encodeURIComponent(cwd)}`)
  } catch (error) {
    // Return non-repo status on error (apiFetch also fires a toast
    // notification on non-2xx; the empty status fallback ensures the
    // UI doesn't crash while the user sees the error).
    return {
      is_git_repo: false,
      branch: '',
      has_changes: false,
      is_clean: true,
      current: '',
      status: 'error',
    }
  }
}

export async function getGitChanges(cwd: string): Promise<GitChangesResponse> {
  try {
    return await apiFetch<GitChangesResponse>(
      `/git/changes?path=${encodeURIComponent(cwd)}`,
    )
  } catch (error) {
    // Return non-repo status on error (apiFetch also fires a toast
    // notification on non-2xx; the empty status fallback ensures the
    // UI doesn't crash while the user sees the error).
    return {
      is_git_repo: false,
      branch: null,
      has_changes: false,
      staged_files: [],
      modified_files: [],
      untracked_files: [],
    }
  }
}

// Git worktree info — used by the "Create a PR" dialog to pre-fill
// the form. The optional `base` parameter is forwarded as
// `?base=<branch>` to the backend (Chunk 2 design decision #12): when
// the user changes the base branch and clicks Auto-fill, we want the
// diff re-computed against the new base.
export interface GitWorktreeInfo {
  is_git_repo: boolean
  branch: string
  last_commit_sha: string
  last_commit_msg: string
  default_base: string
  commits_ahead: number
  diff_summary: string
  draft_title: string
  draft_body: string
}

export async function getGitWorktreeInfo(
  worktreePath: string,
  base?: string,
): Promise<GitWorktreeInfo> {
  try {
    const params = new URLSearchParams({ path: worktreePath })
    if (base && base.trim() !== '') {
      params.set('base', base)
    }
    return await apiFetch<GitWorktreeInfo>(`/git/worktree/info?${params}`)
  } catch (error) {
    console.error('Failed to get git worktree info:', error)
    return {
      is_git_repo: false,
      branch: '',
      last_commit_sha: '',
      last_commit_msg: '',
      default_base: base || 'main',
      commits_ahead: 0,
      diff_summary: '',
      draft_title: '',
      draft_body: '',
    }
  }
}

// Create a PR via `gh pr create` in the worktree path. The backend
// runs the command and returns the PR URL on stdout.
export interface GitPrCreateResponse {
  success: boolean
  pr_url: string
  // Renamed from `error_message` per PR review (git_pr_create.zig:60).
  // The Zig struct field is `@"error"` (because `error` is a Zig keyword)
  // and serializes to JSON `"error"`. This frontend field name matches
  // the JSON wire format.
  error: string
}

export async function createGitPr(
  worktreePath: string,
  base: string,
  title: string,
  body: string,
): Promise<GitPrCreateResponse> {
  return await apiFetch<GitPrCreateResponse>('/git/pr', {
    method: 'POST',
    body: {
      worktree_path: worktreePath,
      base,
      title,
      body,
    },
  })
}

// File listing for autocomplete
export async function listFiles(cwd: string, dirPath?: string): Promise<string[]> {
  try {
    const targetPath = dirPath || cwd
    const data = await apiFetch<{ entries: FolderEntry[] }>(
      `/system/folder?path=${encodeURIComponent(targetPath)}&action=list`,
    )
    // Return names sorted, directories first
    const entries = data.entries || []
    return entries
      .map((e: FolderEntry) => e.name)
      .sort((a: string, b: string) => {
        const aIsDir = entries.find((e: FolderEntry) => e.name === a)?.is_directory
        const bIsDir = entries.find((e: FolderEntry) => e.name === b)?.is_directory
        if (aIsDir && !bIsDir) return -1
        if (!aIsDir && bIsDir) return 1
        return a.localeCompare(b)
      })
  } catch (error) {
    console.error('Failed to list files:', error)
    return []
  }
}

// Session event types for SSE subscription
export interface SessionEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  id: string
  name: string
  status: string
  cwd: string
  created_at: string
  updated_at: string
  selected_profile_model?: string
  // Mirrors `git_worktree_cwd` on the Session interface: empty
  // string when no worktree is bound, omitted for events that don't
  // carry session fields (e.g. delete).
  git_worktree_cwd?: string
  // Mirrors sessions.is_auto_retry_until_stop (Migration 063). Only
  // present on 'updated' events where the session row carries the
  // flag. Used by the workspaces store's SSE handler to keep
  // task.is_auto_retry_until_stop in sync so the
  // KanbanTaskDetailDialog toggle shows the live value.
  is_auto_retry_until_stop?: string
}

// Queue messages SSE event types
export type QueueMessageEvent =
  | {
      action: 'queued'
      id: string
      message: string
      image_url?: string
      session_id: string
    }
  | {
      action: 'deleted'
      id: string
      session_id: string
    }

// GET queued messages
export interface QueuedMessage {
  id: string
  message: string
}

export async function getQueuedMessages(sessionId: string): Promise<{
  messages: QueuedMessage[]
  count: number
}> {
  return await apiFetch<{ messages: QueuedMessage[]; count: number }>(
    `/llm/session/${sessionId}/queue_messages`,
  )
}

// Workers SSE event types
export interface WorkerEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  id: string
  session_id: string
  working_directory: string
  last_activity: number
  last_activity_description: string
  created_at: string
}

// Kanban SSE event types
// (see src/ai_workflow/tui/on_event_sent_kanban.zig on the backend).
export interface KanbanColumnEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered' | 'reordered'
  workspace_id: string
  item_id: string
  column_id: string
  new_name?: string | null
  new_description?: string | null
  new_position?: number | null
}

export interface KanbanTaskEvent {
  action: 'assigned' | 'moved' | 'unassigned'
  workspace_id: string
  item_id: string
  task_id: string
  new_column_id?: string | null
  new_position?: number | null
}

/**
 * Unified SSE channel options.
 *
 * Each property is a per-channel callback. Only the keys present in
 * `channels` are subscribed on the backend (passed as the
 * `?channels=` query param). The factory always registers all
 * known named event types (`kanban_column`, `kanban_task`,
 * `queue_queued`, `queue_deleted`, `llm_chunk`, `llm_full`,
 * `worker_created`, `worker_updated`, `worker_deleted`,
 * `session_created`, `session_deleted`, `design_element_created`,
 * `design_element_updated`, `design_element_deleted`) with the
 * SseClient so the browser dispatches them; the actual dispatch to
 * a consumer's callback is filtered by `eventType` inside the
 * factory.
 */
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
  /**
   * Subscribe to design-mode element mutations. The backend emits
   * three granular event names (`design_element_created`,
   * `design_element_updated`, `design_element_deleted`) that share
   * the same `DesignElementEvent` payload (the `action` discriminator
   * tells them apart). All three route on the central `design_element`
   * event_bus key — the consumer filters by `action` if it cares
   * about the distinction (the `designSse` store treats all three
   * uniformly: re-fetch the page's element list).
   */
  design?: (event: DesignElementEvent) => void
  /**
   * Subscribe to LLM streaming events. When `sessionId` is provided,
   * the factory sends `llm:<sid>` (per-session routing — used by any
   * future caller that wants server-side filtering). When omitted,
   * the factory sends bare `llm` — the backend broadcasts ALL
   * sessions' LLM events on the central key, and the consumer
   * filters by `event.session_id` on the JS side.
   */
  llm?: { sessionId?: string; onEvent: (event: SseEvent) => void }
  /**
   * Subscribe to queue-message events. Same pattern as `llm`:
   * `sessionId` provided → per-session routing; omitted → central
   * key (consumer filters by `event.session_id`).
   */
  queue?: { sessionId?: string; onEvent: (event: QueueMessageEvent) => void }
}

export interface UnifiedSseOptions {
  channels: UnifiedChannels
  onError?: (error: Event) => void
  onConnected?: () => void
}

/**
 * Open ONE EventSource that fans out every event family the caller
 * wired up. Replaces the 5 dedicated `create*SseConnection` factories
 * (workers / sessions / kanban / queue / llm) plus the design channel
 * — they all route to `/api/events?channels=…` under the hood.
 *
 * **Why 1 SSE endpoint doesn't mean "1 EventSource globally":**
 * For apps that subscribe to a session-scoped channel via the per-
 * session routing keys (`llm:<sid>`, `queue:<sid>`), one EventSource
 * per active session would still be needed. To avoid that, pass the
 * `llm` / `queue` channels WITHOUT a `sessionId` — the factory
 * sends bare `llm` / `queue` tokens; the backend broadcasts all
 * sessions' events on central keys; the consumer filters by
 * `event.session_id` on the JS side. Result: ONE EventSource per
 * app for the app's lifetime (see
 * docs/plans/2026-06-30-single-sse-all-sessions-design.md).
 */
export function createUnifiedSseConnection(opts: UnifiedSseOptions): SseClient {
  // 1. Build the ?channels= comma-separated list.
  const tokens: string[] = []
  if (opts.channels.workers) tokens.push('workers')
  if (opts.channels.sessions) tokens.push('sessions')
  if (opts.channels.kanban) tokens.push('kanban')
  if (opts.channels.design) tokens.push('design_element')
  if (opts.channels.llm) {
    tokens.push(opts.channels.llm.sessionId ? `llm:${opts.channels.llm.sessionId}` : 'llm')
  }
  if (opts.channels.queue) {
    tokens.push(opts.channels.queue.sessionId ? `queue:${opts.channels.queue.sessionId}` : 'queue')
  }

  // Empty subscriptions are meaningless; the backend would 400 anyway.
  // Throw early with a developer-friendly message.
  if (tokens.length === 0) {
    throw new Error('createUnifiedSseConnection: opts.channels is empty')
  }

  // Per-channel JSON buffer for the unnamed default `message` event,
  // if any are emitted. As of the granular `event:` names commit, EVERY
  // emitted event type sets an explicit `event:` line (worker_*,
  // session_*, llm_chunk, llm_full, queue_queued, queue_deleted,
  // kanban_column, kanban_task), so the default-message path below is
  // only hit by future unnamed events. The buffer stays in place so any
  // such addition is handled correctly without re-wiring the buffer.
  //
  // ONE shared buffer (not N per-channel buffers) — the SSE wire format
  // is a SINGLE stream of `data:` lines; the buffer holds the
  // accumulated bytes until a complete JSON object is parsed, then
  // the consumer that matches the shape dispatches and the buffer is
  // sliced past the consumed bytes. Using N buffers and feeding all
  // of them the same bytes leaks memory on the long-lived global
  // SSE — see Plan Reviewer finding #1.
  const defaultMessageBuf = { value: '' }

  return createSseClient({
    url: `${API_BASE}/events?channels=${tokens.join(',')}`,
    onConnected: opts.onConnected,
    // Every named event type the backend can emit MUST be pre-registered
    // — the browser's EventSource only dispatches each `event: <name>`
    // to listeners registered for that exact name. See the SseClient
    // JSDoc + the project memory browser-eventsource-named-events.md.
    // Set names MUST match the `event_type` values emitted by
    // on_event_sent.zig and llm_history.zig.
    additionalEventTypes: [
      'kanban_column',
      'kanban_task',
      'queue_queued',
      'queue_deleted',
      'llm_chunk',
      'llm_full',
      'worker_created',
      'worker_updated',
      'worker_deleted',
      'session_created',
      'session_deleted',
      // Design-mode element events (see src/ai_workflow/tui/on_event_sent_design.zig).
      // All granular single-element events share the `DesignElementEvent`
      // payload; the `action` discriminator tells them apart. The single
      // `design_element` channel token in `tokens` subscribes to all of
      // them at once — no per-action channel routing needed because the
      // frontend treats them uniformly (re-fetch the page's element list).
      // The BATCH event (`design_elements_geometry_batch_updated`) is
      // emitted by `updateElementsBatch` AND by `moveElementsWithDescendantsBatch`
      // — both endpoints share the same SSE event type. Without this
      // registration, the browser's EventSource drops the event before
      // our `onEvent` handler ever sees it (see project memory
      // browser-eventsource-named-events.md), which means the dedupe
      // check in `stores/designSse.ts` never runs and the local-mutation
      // skip path is dead code for batch updates.
      'design_element_created',
      'design_element_updated',
      'design_element_deleted',
      'design_elements_geometry_batch_updated',
    ],
    // Default heartbeat filter (matches backend sse_manager.sendHeartbeat).
    heartbeatData: 'ping',
    onEvent: (raw: string, eventType: string) => {
      if (eventType === 'connected') {
        // Reset the buffer on (re)connect — leftover bytes from the
        // previous connection would corrupt the next parse.
        defaultMessageBuf.value = ''
        return
      }

      // Named events: dispatch by eventType.
      if (eventType === 'kanban_column' || eventType === 'kanban_task') {
        if (!opts.channels.kanban) return
        try {
          const data = JSON.parse(raw)
          opts.channels.kanban(data as KanbanColumnEvent | KanbanTaskEvent)
        } catch (err) {
          console.error('[unifiedSSE] kanban event parse failed:', err, raw)
        }
        return
      }

      // Design-mode element events. The backend emits four event names:
      //   - `design_element_created` / `_updated` / `_deleted` — single
      //     element; all share the same `DesignElementEvent` payload
      //     (the `action` discriminator tells them apart).
      //   - `design_elements_geometry_batch_updated` — batch event with
      //     `element_ids[]` (the `DesignElementEvent` interface has
      //     `element_ids?: string[]` for this variant). Emitted by
      //     `updateElementsBatch` AND `moveElementsWithDescendantsBatch`.
      //   - src/ai_workflow/tui/on_event_sent_design.zig — all four
      //     are dispatched to the same `design` channel; the consumer
      //     can switch on `event.action` or check `event.element_ids`
      //     if it cares about the distinction.
      if (
        eventType === 'design_element_created' ||
        eventType === 'design_element_updated' ||
        eventType === 'design_element_deleted' ||
        eventType === 'design_elements_geometry_batch_updated'
      ) {
        if (!opts.channels.design) return
        try {
          const data = JSON.parse(raw)
          opts.channels.design(data as DesignElementEvent)
        } catch (err) {
          console.error('[unifiedSSE] design event parse failed:', err, raw)
        }
        return
      }

      if (eventType === 'queue_queued' || eventType === 'queue_deleted') {
        if (!opts.channels.queue) return
        try {
          const data = JSON.parse(raw)
          opts.channels.queue.onEvent(data as QueueMessageEvent)
        } catch (err) {
          console.error('[unifiedSSE] queue event parse failed:', err, raw)
        }
        return
      }

      // LLM streaming chunks / full responses. The backend sets
      // `event_type = "llm_chunk"` for content/reasoning/tool-call/final
      // chunks (per `on_event_sent.zig` `sendStreamChunk*`) and
      // `event_type = "llm_full"` for non-streaming full responses
      // (`onEventSendLLMHistory`). Both shapes are the same `SseEvent`
      // — the frontend doesn't need to distinguish them; the channel
      // callback receives the object either way.
      if (eventType === 'llm_chunk' || eventType === 'llm_full') {
        if (!opts.channels.llm) return
        try {
          const data = JSON.parse(raw)
          opts.channels.llm.onEvent(data as SseEvent)
        } catch (err) {
          console.error('[unifiedSSE] llm event parse failed:', err, raw)
        }
        return
      }

      // Worker events. The backend sets `worker_created` |
      // `worker_updated` | `worker_deleted` based on
      // `OnEventInputWorkers.action` (see `on_event_sent.zig`).
      if (
        eventType === 'worker_created' ||
        eventType === 'worker_updated' ||
        eventType === 'worker_deleted'
      ) {
        if (!opts.channels.workers) return
        try {
          const data = JSON.parse(raw)
          opts.channels.workers(data as WorkerEvent)
        } catch (err) {
          console.error('[unifiedSSE] worker event parse failed:', err, raw)
        }
        return
      }

      // Session events. The backend sets `session_created` |
      // `session_deleted` based on `OnEventInputSessions.action`. Today
      // only `created` is emitted; `deleted` is wired in `on_event_sent.zig`
      // for future use.
      if (
        eventType === 'session_created' ||
        eventType === 'session_deleted'
      ) {
        if (!opts.channels.sessions) return
        try {
          const data = JSON.parse(raw)
          opts.channels.sessions(data as SessionEvent)
        } catch (err) {
          console.error('[unifiedSSE] session event parse failed:', err, raw)
        }
        return
      }

      // Default `message` events: 3 distinct JSON shapes, differentiated
      // by which consumer registered the channel. The backend sends
      // these as multi-line JSON strings (one `data:` line per JSON
      // object's newline-delimited line), so we accumulate + parse
      // in a single shared buffer, then dispatch by JSON-shape check.
      //
      // Shape discrimination: `action` is present in worker and session
      // events but NOT in LLM chunk/full events (LLM uses `type`).
      // - `{action, id, working_directory, ...}`    → WorkerEvent
      // - `{action, id, name, status, cwd, ...}`   → SessionEvent
      // - `{type, content, session_id, ...}`      → SseEvent (LLM)
      //
      // Single buffer (not per-channel): the SSE wire format is ONE
      // stream; each `data:` line goes to exactly one consumer based on
      // its shape. After dispatch, the buffer is sliced past the
      // consumed JSON object so the next event starts fresh.
      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        defaultMessageBuf.value += trimmed + '\n'
        const jsonStart = defaultMessageBuf.value.indexOf('{')
        const jsonEnd = defaultMessageBuf.value.lastIndexOf('}')
        if (jsonStart === -1 || jsonEnd === -1 || jsonEnd <= jsonStart) {
          // Incomplete JSON object — wait for more bytes. If the
          // buffer grows unbounded (e.g. server sends invalid JSON),
          // a future fix could add a size guard; current callers
          // trust the backend's wire format.
          return
        }
        const jsonStr = defaultMessageBuf.value.slice(jsonStart, jsonEnd + 1)
        let parsed: unknown
        try {
          parsed = JSON.parse(jsonStr)
        } catch {
          // Invalid JSON; drop the leading bytes and keep accumulating.
          // (Defensive — the backend's std.json.fmt should always
          // emit valid JSON. But a buggy future emitter shouldn't
          // crash the SSE.)
          defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonStart + 1)
          return
        }

        const obj = parsed as Record<string, unknown>
        // Order matters: check session BEFORE worker because both have
        // `action`; the discriminator is `working_directory` (worker
        // has it, session doesn't) plus `status` (session has it,
        // worker doesn't). Either combination uniquely identifies.
        // We dispatch to AT MOST ONE consumer — the first matching
        // shape wins. If no shape matches, the event is silently
        // dropped (after the buffer advance below) so the buffer
        // stays bounded.
        if (
          opts.channels.sessions &&
          typeof obj.action === 'string' &&
          typeof obj.status === 'string' &&
          typeof obj.cwd === 'string'
        ) {
          opts.channels.sessions(obj as unknown as SessionEvent)
        } else if (
          opts.channels.workers &&
          typeof obj.action === 'string' &&
          typeof obj.working_directory === 'string'
        ) {
          opts.channels.workers(obj as unknown as WorkerEvent)
        } else if (
          opts.channels.llm &&
          (obj.type === 'chunk' || obj.type === 'full')
        ) {
          opts.channels.llm.onEvent(obj as unknown as SseEvent)
        }

        // ALWAYS advance past the consumed JSON object, regardless of
        // whether a consumer matched. The single-stream design means
        // every default-message event MUST produce forward progress —
        // if a caller subscribed only to `kanban` and the backend
        // emits a worker-shaped default-message event, we must still
        // slice past it so the buffer doesn't grow unboundedly.
        // (Code Reviewer Critical Fix, 2026-06-30.)
        defaultMessageBuf.value = defaultMessageBuf.value.slice(jsonEnd + 1)
      } catch (e) {
        console.error('[unifiedSSE] default message dispatch error:', e)
      }
    },
    onStateChange: (state, info) => {
      // Match the convention of the 5 old factories: terminal-failure
      // only. Transient errors are retried internally by the SseClient.
      // See memory nalar-sse-incomplete-chunked-encoding.md for why
      // ChatView's isStreaming flag flips ONLY on 'failed'.
      if (state === 'failed') {
        opts.onError?.(info.lastError ?? new Event('error'))
      }
    },
  })
}

// Nalar Config API
export interface NalarProfile {
  model?: string
  base_url?: string
  thinking?: string
  temperature?: string
  url_style?: string
  api_key?: string
  /**
   * Per-profile sub-agents. Same shape as the top-level
   * `NalarConfig.sub_agents` field — profiles can override the default
   * sub-agent set with their own.
   */
  sub_agents?: SubAgent[]
  /**
   * Optional override for this profile's context window (in tokens).
   * When null (or omitted), the backend's built-in per-model default
   * is used (e.g. 200_000 for MiniMax-M2.7, 500_000 for MiniMax-M3,
   * 200_000 fallback). Useful for self-hosted models with a
   * non-standard window.
   *
   * Mirrors the backend's `LlmProfile.max_capacity_tokens` field
   * (added in the configurable-compaction Chunk 7 reshape).
   */
  max_capacity_tokens?: number | null
  /**
   * Compaction threshold as a percentage (0-100) of this profile's
   * context window. When null (or omitted), defaults to 80. Out-of-range
   * values are rejected by the backend with `error.InvalidThresholdPercent`.
   *
   * Mirrors the backend's `LlmProfile.compaction_threshold_percent`.
   */
  compaction_threshold_percent?: number | null
}

export interface SubAgent {
  name: string
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  system_prompt: string
}

export interface McpHeader {
  key: string
  value: string
}

export interface McpServer {
  name: string
  url: string
  /** Optional list of HTTP headers to send with MCP requests (e.g. API keys). */
  headers?: McpHeader[]
}

export interface NalarConfig {
  api_endpoint?: string
  api_key?: string
  model?: string
  url_style?: string
  temperature?: number
  max_tokens?: string
  system_prompt?: string
  profiles?: Record<string, NalarProfile>
  active_profile?: string
  /**
   * Map of MCP server name to its raw JSON config (snake_case).
   * Each value follows the `{"url": "...", "headers": {...}}` shape used by
   * the LLM config. Sent verbatim to the backend on save.
   */
  mcp_servers?: Record<string, { url: string; headers?: Record<string, string> }>
  /**
   * Top-level sub-agents array. Each entry is a named sub-agent LLM
   * configuration (model + base_url + thinking + temperature + url_style
   * + api_key + system_prompt) that the `spawn_sub_agent` tool can
   * reference by name. Sent as-is to the backend on save.
   */
  sub_agents?: SubAgent[]
  /**
   * Opt-in OS notification flag. When true, the backend fires
   * `notify-send` / osascript / PowerShell when an LLM response
   * completes with `finish_reason === 'stop'`. Defaults to `false`
   * when absent (matches the `LlmConfigJson` default in
   * `Config.zig`).
   */
  notify_on_complete?: boolean
  /**
   * Compaction threshold in KB. Sessions whose DB-stored token
   * estimate exceeds this value trigger context compaction. Defaults
   * to `100` when absent. Not exposed in the UI — power users can
   * edit `config.json` directly.
   */
  model_compaction_size_kb?: number
  /**
   * Optional top-level override for the model's context window (in
   * tokens). `null` = fall through to per-profile override, then
   * built-in default. Restored in plan 2026-07-07-compaction-inline
   * so the Defaults tab can show + edit the top-level compaction
   * defaults. Mirrors `LlmConfig.max_capacity_token_model`.
   */
  max_capacity_token_model?: number | null
  /**
   * Optional top-level compaction threshold as a percentage (0-100).
   * `null` = fall through to per-profile override, then built-in 80.
   * Mirrors `LlmConfig.compaction_threshold_percent`.
   */
  compaction_threshold_percent?: number | null
  /**
   * Delay in milliseconds before the workflow retries a failed
   * `callDynamicAgentNew` call. 0 = no delay (current behavior, the
   * retry fires immediately on the next loop iteration). Range: 0–60 000.
   * The backend clamps values > 60 000 to 60 000. Mirrors
   * `LlmConfig.retry_delay_ms` in `Config.zig`.
   */
  retry_delay_ms?: number
  // Per-profile compaction overrides (`max_capacity_tokens` /
  // `compaction_threshold_percent`) live on `NalarProfile` (Chunk
  // 7.6) and remain there. Both layers coexist.
}

export async function getNalarConfig(): Promise<NalarConfig> {
  try {
    return await apiFetch<NalarConfig>('/config/nalar')
  } catch {
    return {}
  }
}

export async function saveNalarConfig(config: NalarConfig): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>('/config/nalar', {
    method: 'PUT',
    body: config,
  })
}

/**
 * Response shape from `DELETE /api/config/nalar/profiles/:name`.
 *
 * `active_profile_was_cleared` is `true` when the deleted profile was
 * the active one (the backend also cleared `active_profile` on disk).
 * `error_message` is set when the request succeeded (HTTP 200) but a
 * downstream concern (live reload) failed — the deletion still
 * persisted.
 */
export interface ProfileDeleteResponse {
  success: boolean
  profile_name: string
  active_profile_was_cleared?: boolean
  error_message?: string
}

/**
 * DELETE /api/config/nalar/profiles/:name
 *
 * Removes a profile from `config.json` and live-reloads the backend's
 * in-memory LLM config. Throws an Error (with the HTTP status) on
 * non-2xx responses; the composable wraps this for UI concerns
 * (optimistic update, rollback, notification).
 */
export async function deleteProfile(name: string): Promise<ProfileDeleteResponse> {
  return await apiFetch<ProfileDeleteResponse>(
    `/config/nalar/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
}

// Git File Diff API
export interface GitFileDiff {
  path: string
  diff_content: string // Unified diff output from git diff command
  staged: boolean
}

export async function getGitFileDiff(
  cwd: string,
  filePath: string,
  staged: boolean = false,
): Promise<GitFileDiff> {
  return await apiFetch<GitFileDiff>(
    `/git/file/diff?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}&staged=${staged}`,
  )
}

export async function readGitFile(
  cwd: string,
  filePath: string,
): Promise<{ content: string; encoding: string }> {
  return await apiFetch<{ content: string; encoding: string }>(
    `/git/file/read?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}`,
  )
}

// Read file content API (for CodeEditor)
export interface ReadFileResponse {
  content: string
  encoding: string
}

export async function readFileContent(cwd: string, filePath: string): Promise<ReadFileResponse> {
  // silent: true — AppLayout shows a fullscreen error view in the
  // code editor; a toast on every read failure would be redundant noise.
  return await apiFetch<ReadFileResponse>(
    `/system/folder?path=${encodeURIComponent(cwd)}&action=read&file=${encodeURIComponent(filePath)}`,
    { silent: true },
  )
}

// Write file content API (for CodeEditor save)
export async function writeFileContent(
  cwd: string,
  filePath: string,
  content: string,
): Promise<{ success: boolean; message?: string }> {
  // silent: true — AppLayout surfaces save failures inline in the
  // code editor; a toast would duplicate the message.
  return await apiFetch<{ success: boolean; message?: string }>('/system/folder', {
    method: 'POST',
    body: {
      action: 'write',
      path: cwd,
      file: filePath,
      content,
    },
    silent: true,
  })
}

// Git Stage/Unstage API
export interface GitStageResponse {
  success: boolean
  message: string
  staged_files: string[]
  failed_files: string[]
}

export async function stageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  return await apiFetch<GitStageResponse>(
    `/git/stage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
}

export async function unstageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  return await apiFetch<GitStageResponse>(
    `/git/unstage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
}

/**
 * Upload an image attachment for a kanban task. The server writes the
 * file to `<workspace_item.path>/.nalar/attachments/<task_id>/<n>.<ext>`
 * and returns a URL the frontend embeds in the markdown description as
 * `![name](<url>)`.
 *
 * Plan: docs/superpowers/plans/2026-07-25-kanban-description-rich-editor.md
 * (Option C: filesystem-backed attachments).
 */
export async function uploadTaskAttachment(
  taskId: string,
  file: File,
): Promise<{ url: string; size: number }> {
  const url = `${API_BASE}/workspaces/tasks/${encodeURIComponent(taskId)}/attachments?filename=${encodeURIComponent(file.name)}`
  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': file.type || 'application/octet-stream',
    },
    body: file,
  })
  if (!response.ok) {
    const text = await response.text().catch(() => '')
    throw new Error(`Attachment upload failed (${response.status}): ${text}`)
  }
  const json = (await response.json()) as { success: boolean; url: string; size: number }
  if (!json.success || !json.url) {
    throw new Error('Attachment upload returned invalid response')
  }
  return { url: json.url, size: json.size }
}

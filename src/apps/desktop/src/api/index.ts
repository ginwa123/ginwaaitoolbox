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
    // NEW (Chunk 5 of task-routines plan): routine-edit fields,
    // forwarded verbatim to the backend's PUT handler. The server
    // applies them to the routines row in the same transaction.
    schedule?: string
    initial_prompt?: string
    enabled?: boolean
  },
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    body: data,
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
  is_input?: string,
  is_output?: string
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
      max_total_tokens: undefined,
      max_capacity_total_tokens: undefined,
      total_count: undefined,
    }
  }
}

// Send a message to LLM
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
  imageUrls?: string[],
  selectedProfile?: string,
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

// Update an existing session (selectedProfile, name, etc.)
export async function updateSession(
  sessionId: string,
  updates: { selectedProfile?: string | null; name?: string },
): Promise<{ id: string; name: string; status: string; selected_profile_model: string }> {
  return await apiFetch<{ id: string; name: string; status: string; selected_profile_model: string }>(
    `/llm/session/${sessionId}`,
    {
      method: 'PUT',
      body: {
        selected_profile_model: updates.selectedProfile ?? '',
        name: updates.name ?? '',
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
  is_input?: string,
  is_output?: string,
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
    }>(`/llm/session/${sessionId}/messages?limit=1`, { silent: true })
    // The session info is in the cwd field - construct session object
    return {
      sessionId: sessionId,
      cwd: data.cwd || '',
      createdAt: '',
      agent: '',
      sessionName: data.messages?.[0]?.session_name || '',
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
  action: 'created' | 'updated' | 'deleted'
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
}

// Queue messages SSE event types
export interface QueueMessageEvent {
  action: 'queued' | 'deleted'
  id?: string
  message: string
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
  action: 'created' | 'updated' | 'deleted'
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
  action: 'created' | 'updated' | 'deleted' | 'reordered'
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
 * `session_created`, `session_deleted`) with the SseClient so the
 * browser dispatches them; the actual dispatch to a consumer's
 * callback is filtered by `eventType` inside the factory.
 */
export interface UnifiedChannels {
  workers?: (event: WorkerEvent) => void
  sessions?: (event: SessionEvent) => void
  kanban?: (event: KanbanColumnEvent | KanbanTaskEvent) => void
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
 * (workers / sessions / kanban / queue / llm) — they all route to
 * `/api/events?channels=…` under the hood.
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

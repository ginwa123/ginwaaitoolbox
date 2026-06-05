// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls

import { createSseClient, type SseClient } from '../helpers/sseClient'

export const API_BASE = '/api'

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

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  path?: string
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
}

export interface Task {
  id: string
  name: string
  description?: string
  completed?: boolean
  createdAt?: Date
}

// Health check
export async function healthCheck(): Promise<{
  status: string
  timestamp: number
}> {
  const response = await fetch(`${API_BASE}/health`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// System Folder API
export async function getSystemFolder(): Promise<FolderInfo> {
  const response = await fetch(`${API_BASE}/system/folder?action=list`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function listFolder(path: string): Promise<FolderInfo> {
  const response = await fetch(
    `${API_BASE}/system/folder?path=${encodeURIComponent(path)}&action=list`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  const response = await fetch(`${API_BASE}/workspaces`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function createWorkspace(name: string, icon: string = '📁'): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/workspaces`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function getWorkspace(id: string): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/workspaces/${id}`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function deleteWorkspace(id: string): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/${id}`, {
    method: 'DELETE',
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function updateWorkspace(id: string, data: Partial<Workspace>): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/workspaces/${id}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Task API
export async function getTasks(workspaceId: string, itemId: string): Promise<{ tasks: Task[] }> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function createTask(
  workspaceId: string,
  itemId: string,
  name: string,
  description?: string,
): Promise<Task> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, description }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function updateTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  data: Partial<Task>,
): Promise<{ success: boolean }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Task API - Simple version (just task_id + optional fields)
export async function updateTaskSimple(
  taskId: string,
  data: { name?: string; session_id?: string },
): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/tasks/${taskId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function deleteTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: 'DELETE' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
  role: 'user' | 'assistant' | 'system'
  content: string
  created_at: number
  tool_name?: string
  tool_call_id?: string
  diffview_before?: string
  diffview_after?: string
  image_url?: string
  tool_calls_json?: any
  finish_reason?: string
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
    const response = await fetch(`${API_BASE}/llm/session/${sessionId}/messages?${params}`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()
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
  let body: string

  // Join image URLs with pipe separator (same format as other parts of the system)
  const imageUrlsStr = imageUrls?.join('|') || ''

  // Step 1: Safely serialize — catch any JSON.stringify failures
  try {
    body = JSON.stringify({
      session_id: sessionId,
      queue_message: message,
      allowed_tools: 'all',
      cwd_session: cwdSession,
      image_urls: imageUrlsStr,
      selected_profile_model: selectedProfile || '',
    })
  } catch (serializeError) {
    console.error('Failed to serialize request body:', serializeError)
    return { status: 'invalid_payload' }
  }

  // Step 2: Validate the serialized body can be parsed back (round-trip check)
  try {
    JSON.parse(body)
  } catch (parseError) {
    console.error('Serialized body failed round-trip validation:', parseError)
    return { status: 'invalid_payload' }
  }

  // Step 3: Send the request
  try {
    const response = await fetch(`${API_BASE}/llm/session`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
    })

    if (!response.ok) {
      const errorText = await response.text().catch(() => '')
      console.error(`HTTP ${response.status}: ${errorText}`)

      // Distinguish backend JSON rejection from other HTTP errors
      if (response.status === 400) return { status: 'bad_request' }
      if (response.status === 422) return { status: 'unprocessable_entity' }
      throw new Error(`HTTP ${response.status}`)
    }

    // Step 4: Safely parse response JSON
    const text = await response.text()
    try {
      return JSON.parse(text)
    } catch {
      console.error('Response is not valid JSON:', text)
      return { status: 'invalid_response' }
    }
  } catch (error) {
    console.error('Request failed:', error)
    return { status: 'offline' }
  }
}

// Update an existing session (selectedProfile, name, etc.)
export async function updateSession(
  sessionId: string,
  updates: { selectedProfile?: string | null; name?: string },
): Promise<{ id: string; name: string; status: string; selected_profile_model: string }> {
  const body = JSON.stringify({
    selected_profile_model: updates.selectedProfile ?? '',
    name: updates.name ?? '',
  })
  const response = await fetch(`${API_BASE}/llm/session/${sessionId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body,
  })
  if (!response.ok) {
    const text = await response.text().catch(() => '')
    console.error(`updateSession HTTP ${response.status}: ${text}`)
    throw new Error(`HTTP ${response.status}`)
  }
  return response.json()
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
  is_input?: boolean
  is_output?: boolean
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
}

// Create SSE connection for real-time updates.
//
// The previous implementation returned a raw `EventSource` with no
// auto-reconnect: any network blip, server restart, or sleep/wake
// killed the chat stream permanently until the user reloaded the
// page. The new implementation is a thin adapter around the
// shared `SseClient` (helpers/sseClient.ts) which handles
// exponential backoff, jitter, visibility-aware pausing, and
// online-event fast-path. See `docs/sse-reconnect-plan.md`.
//
// The shape of the public API is unchanged — callers still get a
// `.close()`-able object — so call sites need only a type
// annotation update.
export function createSseConnection(
  sessionId: string,
  onMessage: (event: SseEvent) => void,
  onError?: (error: Event) => void,
  onConnected?: () => void,
): SseClient {
  console.log('[createSseConnection] Creating SSE connection for session:', sessionId)

  // Buffer to accumulate multi-line JSON. Closure-scoped, so each
  // client has its own. We clear it on every 'connected' event
  // because that's the first message from a fresh EventSource
  // — important during reconnects, where leftover bytes from the
  // previous connection would otherwise corrupt the new stream's
  // JSON parse.
  let jsonBuffer = ''

  return createSseClient({
    url: `${API_BASE}/llm/stream/${sessionId}`,
    onConnected,
    onEvent: (raw: string, eventType: string) => {
      if (eventType === 'connected') {
        // New stream (or freshly reconnected stream). Discard
        // any leftover buffered bytes from a previous connection.
        jsonBuffer = ''
        try {
          const data = JSON.parse(raw)
          onMessage({ ...data, type: 'connected' as const })
        } catch (err) {
          console.error('Failed to parse connected event:', err)
        }
        return
      }

      // 'message' events: existing JSON-buffer logic.
      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        // Some proxies return a plain HTTP response (e.g. 502
        // page) on the SSE path during a server restart. Detect
        // and skip.
        if (trimmed.startsWith('HTTP/')) {
          console.warn('SSE received HTTP response instead of SSE data, skipping')
          return
        }

        // Accumulate JSON until we have complete object
        jsonBuffer += trimmed + '\n'

        // Try to find complete JSON object (starts with { and ends with })
        const jsonStart = jsonBuffer.indexOf('{')
        const jsonEnd = jsonBuffer.lastIndexOf('}')

        if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
          const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1)
          try {
            const data = JSON.parse(jsonStr)
            console.log('[SSE API] Received data:', data)
            onMessage(data)
            // Keep anything after the JSON for next event
            jsonBuffer = jsonBuffer.slice(jsonEnd + 1)
          } catch (e) {
            // Not complete yet, keep buffering
            console.log(
              '[SSE API] Buffering, not complete JSON yet, buffer length:',
              jsonBuffer.length,
            )
          }
        }
      } catch (e) {
        console.error('SSE onmessage error:', e)
      }
    },
    // Only invoke the caller's `onError` on a *terminal* failure.
    // Transient errors are handled by SseClient's auto-reconnect —
    // firing `onError` for each retry would tell the caller
    // (e.g. ChatView) that the stream ended when really it just
    // hiccuped. ChatView specifically uses this to decide whether
    // to clear the "streaming" UI: it should only clear on a
    // true end-of-stream, not on a reconnect.
    onStateChange: (state, info) => {
      if (state === 'failed') {
        onError?.(info.lastError ?? new Event('error'))
      }
    },
  })
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
    const response = await fetch(`${API_BASE}/llm/session?${params}`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)

    const data = await response.json()

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
    // Return empty sessions when LLM backend unavailable
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
  const response = await fetch(`${API_BASE}/chats`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function createChat(name: string, icon: string = '💬'): Promise<ChatLegacy> {
  const response = await fetch(`${API_BASE}/chats`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, icon }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function deleteChat(id: string): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/chats/${id}`, { method: 'DELETE' })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Session API - Fetch session info including cwd
export interface Session {
  sessionId: string
  cwd: string
  createdAt: string
  agent: string
  sessionName: string
  selectedProfile?: string
}

export async function getSession(sessionId: string): Promise<Session | null> {
  try {
    // Use the same endpoint as getChatHistory - it returns session info including cwd
    const response = await fetch(`${API_BASE}/llm/session/${sessionId}/messages?limit=1`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()
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
    const response = await fetch(`${API_BASE}/session/${sessionId}/compact`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
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
  const response = await fetch(`${API_BASE}/workers?${params}`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Workspace Item API
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path: string,
  itemType: string = 'folder',
): Promise<WorkspaceItem> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, path, item_type: itemType }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function deleteWorkspaceItem(
  workspaceId: string,
  itemId: string,
): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items/${itemId}`, {
    method: 'DELETE',
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
  const response = await fetch(`${API_BASE}/skills${query}`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
  const response = await fetch(`${API_BASE}/skills/${encodeURIComponent(name)}${query}`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
  const response = await fetch(`${API_BASE}/skills?${params}`, {
    method: 'DELETE',
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
    const response = await fetch(`${API_BASE}/git/status?path=${encodeURIComponent(cwd)}`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  } catch (error) {
    // Return non-repo status on error
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
    const response = await fetch(`${API_BASE}/git/changes?path=${encodeURIComponent(cwd)}`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  } catch (error) {
    // Return non-repo status on error
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

// File listing for autocomplete
export async function listFiles(cwd: string, dirPath?: string): Promise<string[]> {
  try {
    const targetPath = dirPath || cwd
    const response = await fetch(
      `${API_BASE}/system/folder?path=${encodeURIComponent(targetPath)}&action=list`,
    )
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const data = await response.json()
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
}

// Create SSE connection for session events (global chat list updates).
// Now uses the shared SseClient for auto-reconnect — see
// `createSseConnection` above for the full rationale. The previous
// version had no reconnect logic at all, so a single network blip
// would freeze the sidebar's chat list until a manual reload.
export function createSessionsSseConnection(
  onEvent: (event: SessionEvent) => void,
  onError?: (error: Event) => void,
  onConnected?: () => void,
): SseClient {
  console.log('[createSessionsSseConnection] Creating SSE connection for session events')

  // Per-client JSON buffer; cleared on every 'connected' event so a
  // reconnect doesn't carry over stale bytes from the previous
  // connection. See createSseConnection for the same pattern.
  let jsonBuffer = ''

  return createSseClient({
    url: `${API_BASE}/sessions/stream`,
    onConnected,
    onEvent: (raw: string, eventType: string) => {
      // 'connected' is the server's first-byte confirmation; we
      // don't dispatch it to the caller's `onEvent` because
      // SessionEvent has no `connected` variant. The SseClient
      // already fires `onConnected` for it.
      if (eventType === 'connected') {
        jsonBuffer = ''
        try {
          const data = JSON.parse(raw)
          console.log('[SessionsSSE] connected event:', data)
        } catch (err) {
          console.error('Failed to parse connected event:', err)
        }
        return
      }

      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        // Accumulate JSON until we have complete object
        jsonBuffer += trimmed + '\n'

        // Try to find complete JSON object (starts with { and ends with })
        const jsonStart = jsonBuffer.indexOf('{')
        const jsonEnd = jsonBuffer.lastIndexOf('}')

        if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
          const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1)
          try {
            const data = JSON.parse(jsonStr)
            console.log('[SessionsSSE] Received data:', data)
            onEvent(data as SessionEvent)
            // Keep anything after the JSON for next event
            jsonBuffer = jsonBuffer.slice(jsonEnd + 1)
          } catch (e) {
            // Not complete yet, keep buffering
            console.log(
              '[SessionsSSE] Buffering, not complete JSON yet, buffer length:',
              jsonBuffer.length,
            )
          }
        }
      } catch (e) {
        console.error('SessionsSSE onmessage error:', e)
      }
    },
    onStateChange: (state, info) => {
      if (state === 'failed') {
        onError?.(info.lastError ?? new Event('error'))
      }
    },
  })
}

// Queue messages SSE event types
export interface QueueMessageEvent {
  action: 'queued' | 'deleted'
  id?: string
  message: string
  session_id: string
}

export function createQueueMessagesSseConnection(
  sessionId: string,
  onEvent: (event: QueueMessageEvent) => void,
  onError?: (error: Event) => void,
  onConnected?: () => void,
): SseClient {
  console.log('[createQueueMessagesSseConnection] Creating SSE connection for session:', sessionId)

  // Per-client JSON buffer; cleared on 'connected' (see
  // createSseConnection for the rationale).
  let jsonBuffer = ''

  return createSseClient({
    url: `${API_BASE}/llm/session/${sessionId}/queue_messages/stream`,
    onConnected,
    onEvent: (raw: string, eventType: string) => {
      // 'connected' is consumed by the SseClient (it fires
      // onConnected); the previous implementation used the
      // first 'queue_message' event as the liveness signal,
      // which was a bug — a session with an empty queue would
      // never trigger onConnected. The SseClient-based version
      // uses the proper 'connected' named event.
      if (eventType === 'connected') {
        jsonBuffer = ''
        return
      }

      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        // Accumulate JSON until we have complete object
        jsonBuffer += trimmed + '\n'

        // Try to find complete JSON object (starts with { and ends with })
        const jsonStart = jsonBuffer.indexOf('{')
        const jsonEnd = jsonBuffer.lastIndexOf('}')

        if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
          const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1)
          try {
            const data = JSON.parse(jsonStr)
            console.log('[QueueMessagesSSE] Received data:', data)
            onEvent(data as QueueMessageEvent)
            // Keep anything after the JSON for next event
            jsonBuffer = jsonBuffer.slice(jsonEnd + 1)
          } catch (e) {
            // Not complete yet, keep buffering
            console.log(
              '[QueueMessagesSSE] Buffering, not complete JSON yet, buffer length:',
              jsonBuffer.length,
            )
          }
        }
      } catch (e) {
        console.error('QueueMessagesSSE onmessage error:', e)
      }
    },
    onStateChange: (state, info) => {
      if (state === 'failed') {
        onError?.(info.lastError ?? new Event('error'))
      }
    },
  })
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
  const response = await fetch(`${API_BASE}/llm/session/${sessionId}/queue_messages`)
  if (!response.ok) {
    throw new Error(`Failed to get queued messages: ${response.statusText}`)
  }
  return response.json()
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

// Create SSE connection for worker events (global worker list updates).
// Now uses the shared SseClient for auto-reconnect. The previous
// implementation in `App.vue` had a hand-rolled 5 s
// `setTimeout(reconnect)` that suffered from two bugs (timer
// leak on unmount, and a stale timer closing a working
// connection). See `docs/sse-reconnect-plan.md` §1.1 and
// `helpers/sseClient.ts` for the full history.
export function createWorkersSseConnection(
  onEvent: (event: WorkerEvent) => void,
  onError?: (error: Event) => void,
  onConnected?: () => void,
): SseClient {
  console.log('[createWorkersSseConnection] Creating SSE connection for worker events')

  // Per-client JSON buffer; cleared on 'connected' (see
  // createSseConnection for the rationale).
  let jsonBuffer = ''

  return createSseClient({
    url: `${API_BASE}/workers/stream`,
    onConnected,
    onEvent: (raw: string, eventType: string) => {
      // 'connected' is consumed by the SseClient (it fires
      // onConnected); WorkerEvent has no `connected` variant so
      // we don't dispatch it to the caller.
      if (eventType === 'connected') {
        jsonBuffer = ''
        try {
          const data = JSON.parse(raw)
          console.log('[WorkersSSE] connected event:', data)
        } catch (err) {
          console.error('Failed to parse connected event:', err)
        }
        return
      }

      try {
        const trimmed = raw.trim()
        if (!trimmed) return

        // Accumulate JSON until we have complete object
        jsonBuffer += trimmed + '\n'

        // Try to find complete JSON object (starts with { and ends with })
        const jsonStart = jsonBuffer.indexOf('{')
        const jsonEnd = jsonBuffer.lastIndexOf('}')

        if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
          const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1)
          try {
            const data = JSON.parse(jsonStr)
            console.log('[WorkersSSE] Received data:', data)
            onEvent(data as WorkerEvent)
            // Keep anything after the JSON for next event
            jsonBuffer = jsonBuffer.slice(jsonEnd + 1)
          } catch (e) {
            // Not complete yet, keep buffering
            console.log(
              '[WorkersSSE] Buffering, not complete JSON yet, buffer length:',
              jsonBuffer.length,
            )
          }
        }
      } catch (e) {
        console.error('WorkersSSE onmessage error:', e)
      }
    },
    onStateChange: (state, info) => {
      if (state === 'failed') {
        onError?.(info.lastError ?? new Event('error'))
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
}

export async function getNalarConfig(): Promise<NalarConfig> {
  try {
    const response = await fetch(`${API_BASE}/config/nalar`)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  } catch {
    return {}
  }
}

export async function saveNalarConfig(config: NalarConfig): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/config/nalar`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(config),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
  const response = await fetch(
    `${API_BASE}/config/nalar/profiles/${encodeURIComponent(name)}`,
    { method: 'DELETE' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
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
  const response = await fetch(
    `${API_BASE}/git/file/diff?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}&staged=${staged}`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function readGitFile(
  cwd: string,
  filePath: string,
): Promise<{ content: string; encoding: string }> {
  const response = await fetch(
    `${API_BASE}/git/file/read?path=${encodeURIComponent(cwd)}&file=${encodeURIComponent(filePath)}`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Read file content API (for CodeEditor)
export interface ReadFileResponse {
  content: string
  encoding: string
}

export async function readFileContent(cwd: string, filePath: string): Promise<ReadFileResponse> {
  const response = await fetch(
    `${API_BASE}/system/folder?path=${encodeURIComponent(cwd)}&action=read&file=${encodeURIComponent(filePath)}`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Write file content API (for CodeEditor save)
export async function writeFileContent(
  cwd: string,
  filePath: string,
  content: string,
): Promise<{ success: boolean; message?: string }> {
  const response = await fetch(`${API_BASE}/system/folder`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      action: 'write',
      path: cwd,
      file: filePath,
      content,
    }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Git Stage/Unstage API
export interface GitStageResponse {
  success: boolean
  message: string
  staged_files: string[]
  failed_files: string[]
}

export async function stageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  const response = await fetch(
    `${API_BASE}/git/stage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function unstageGitFiles(cwd: string, files: string[]): Promise<GitStageResponse> {
  const response = await fetch(
    `${API_BASE}/git/unstage?path=${encodeURIComponent(cwd)}&files=${encodeURIComponent(files.join(','))}`,
    { method: 'POST' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

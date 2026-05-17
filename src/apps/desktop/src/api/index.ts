// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls

export const API_BASE = "/api";

// Types matching backend responses
export interface FolderEntry {
  name: string;
  path: string;
  is_directory: boolean;
  is_symlink: boolean;
}

export interface FolderInfo {
  path: string;
  absolute: string;
  home: string;
  parent?: string;
  entries: FolderEntry[];
}

export interface Workspace {
  id: string;
  name: string;
  icon: string;
  items: WorkspaceItem[];
  expanded: boolean;
}

export interface WorkspaceItem {
  id: string;
  name: string;
  item_type: string;
  path?: string;
  entries?: FolderEntry[];
  isLoaded?: boolean;
  isLoading?: boolean;
  expanded?: boolean;
  tasks?: Task[];
}

export interface Task {
  id: string;
  name: string;
  description?: string;
  completed?: boolean;
  createdAt?: Date;
}

// Health check
export async function healthCheck(): Promise<{
  status: string;
  timestamp: number;
}> {
  const response = await fetch(`${API_BASE}/health`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// System Folder API
export async function getSystemFolder(): Promise<FolderInfo> {
  const response = await fetch(`${API_BASE}/system/folder?action=list`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function listFolder(path: string): Promise<FolderInfo> {
  const response = await fetch(
    `${API_BASE}/system/folder?path=${encodeURIComponent(path)}&action=list`,
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  const response = await fetch(`${API_BASE}/workspaces`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function createWorkspace(
  name: string,
  icon: string = "📁",
): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/workspaces`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function getWorkspace(id: string): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/workspaces/${id}`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function deleteWorkspace(
  id: string,
): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/${id}`, {
    method: "DELETE",
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Task API
export async function getTasks(
  workspaceId: string,
  itemId: string,
): Promise<{ tasks: Task[] }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks`,
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function createTask(
  workspaceId: string,
  itemId: string,
  name: string,
  description?: string,
): Promise<Task> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, description }),
    },
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
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
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    },
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Task API - Simple version (just task_id + optional fields)
export async function updateTaskSimple(
  taskId: string,
  data: { name?: string; session_id?: string },
): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/tasks/${taskId}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function deleteTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
): Promise<{ success: boolean }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: "DELETE" },
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Chat API - Zig Backend Integration (Zig backend calls LLM backend internally)
export interface Chat {
  session_id: string;
  session_name?: string;
  status?: string;
}

export interface Message {
  id: string;
  role: "user" | "assistant" | "system";
  content: string;
  created_at: number;
  tool_name?: string;
  diffview_before?: string;
  diffview_after?: string;
}

// All chat endpoints go through Zig backend at /api/llm/*
// Zig backend internally calls LLM backend

// Parse timestamp - backend sends nanoseconds as string, convert to seconds
function parseTimestamp(ts: number | string): number {
  const num = typeof ts === "string" ? parseInt(ts, 10) : ts;
  // If timestamp looks like nanoseconds (> 1e12), convert to seconds
  return num > 1e12 ? Math.floor(num / 1e9) : num;
}
export async function getChatHistory(
  sessionId: string,
  limit = 50,
  cursor?: string,
): Promise<{
  messages: Message[];
  has_more: boolean;
  next_cursor: string | null;
  cwd?: string;
  max_total_tokens?: number;
  max_capacity_total_tokens?: number;
}> {
  try {
    const params = new URLSearchParams({
      sort_by: "created_at",
      direction: "desc",
      limit: limit.toString(),
    });
    if (cursor) {
      params.set("cursor", cursor);
    }
    const response = await fetch(
      `${API_BASE}/llm/session/${sessionId}/messages?${params}`,
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    return {
      messages: data.messages.map(
        (msg: {
          id: string;
          role: string;
          content: string;
          created_at: number | string;
          tool_name?: string;
          diffview_before?: string;
          diffview_after?: string;
        }) => ({
          ...msg,
          content: msg.content,
          created_at: parseTimestamp(msg.created_at),
          tool_name: msg.tool_name,
          diffview_before: msg.diffview_before,
          diffview_after: msg.diffview_after,
        }),
      ),
      has_more: data.has_more,
      next_cursor: data.next_cursor,
      cwd: data.cwd,
      max_total_tokens: data.max_total_tokens,
      max_capacity_total_tokens: data.max_capacity_total_tokens,
    };
  } catch (error) {
    // Return empty messages when LLM backend unavailable
    console.log(error);
    return {
      messages: [],
      has_more: false,
      next_cursor: null,
      cwd: undefined,
      max_total_tokens: undefined,
      max_capacity_total_tokens: undefined,
    };
  }
}

// Send a message to LLM
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
): Promise<{ status: string }> {
  let body: string;

  // Step 1: Safely serialize — catch any JSON.stringify failures
  try {
    body = JSON.stringify({
      session_id: sessionId,
      queue_message: message,
      allowed_tools: "all",
      cwd_session: cwdSession,
    });
  } catch (serializeError) {
    console.error("Failed to serialize request body:", serializeError);
    return { status: "invalid_payload" };
  }

  // Step 2: Validate the serialized body can be parsed back (round-trip check)
  try {
    JSON.parse(body);
  } catch (parseError) {
    console.error("Serialized body failed round-trip validation:", parseError);
    return { status: "invalid_payload" };
  }

  // Step 3: Send the request
  try {
    const response = await fetch(`${API_BASE}/llm/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => "");
      console.error(`HTTP ${response.status}: ${errorText}`);

      // Distinguish backend JSON rejection from other HTTP errors
      if (response.status === 400) return { status: "bad_request" };
      if (response.status === 422) return { status: "unprocessable_entity" };
      throw new Error(`HTTP ${response.status}`);
    }

    // Step 4: Safely parse response JSON
    const text = await response.text();
    try {
      return JSON.parse(text);
    } catch {
      console.error("Response is not valid JSON:", text);
      return { status: "invalid_response" };
    }
  } catch (error) {
    console.error("Request failed:", error);
    return { status: "offline" };
  }
}

// SSE event types matching the backend
// Note: Backend sends events without explicit 'type' field in data.
// The 'finish_reason' field indicates message completion.
export interface SseEvent {
  session_id: string;
  id?: string;
  content?: string;
  role?: string;
  finish_reason?: string;
  reasoning_content?: string;
  tool_calls?: any;
  tool_call_id?: string;
  tool_name?: string;
  agent_name?: string;
  loop_index?: number;
  temperature?: number;
  is_thinking?: boolean;
  is_input?: boolean;
  is_output?: boolean;
  parent_session_id?: string;
  parent_id?: string;
  created_at?: number;
  // Legacy type field for compatibility (not used by backend)
  type?:
    | "chunk"
    | "reasoning_chunk"
    | "chunk_final"
    | "tool_call_delta"
    | "connected"
    | "full";
  index?: number;
  total_tokens?: number;
  // Diff view data for text_replace tool
  diffview_before?: string;
  diffview_after?: string;
}

// Create SSE connection for real-time updates
export function createSseConnection(
  sessionId: string,
  onMessage: (event: SseEvent) => void,
  onError?: (error: Event) => void,
  onConnected?: () => void,
): EventSource {
  console.log(
    "[createSseConnection] Creating SSE connection for session:",
    sessionId,
  );
  const eventSource = new EventSource(`${API_BASE}/llm/stream/${sessionId}`);

  // Buffer to accumulate multi-line JSON
  let jsonBuffer = "";

  // Handle named event: "connected"
  eventSource.addEventListener("connected", (e: MessageEvent) => {
    try {
      const data = JSON.parse(e.data);
      onMessage({ ...data, type: "connected" as const });
      onConnected?.();
    } catch (err) {
      console.error("Failed to parse connected event:", err);
    }
  });

  // Handle default events (data: lines without event: prefix)
  eventSource.onmessage = (event) => {
    console.log("[SSE API] onmessage raw:", JSON.stringify(event.data));
    try {
      const raw = event.data;
      if (!raw) return;

      const trimmed = raw.trim();
      if (!trimmed) return;

      // Check for HTTP response
      if (trimmed.startsWith("HTTP/")) {
        console.warn(
          "SSE received HTTP response instead of SSE data, skipping",
        );
        return;
      }

      // Accumulate JSON until we have complete object
      jsonBuffer += trimmed + "\n";

      // Try to find complete JSON object (starts with { and ends with })
      const jsonStart = jsonBuffer.indexOf("{");
      const jsonEnd = jsonBuffer.lastIndexOf("}");

      if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
        const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1);
        try {
          const data = JSON.parse(jsonStr);
          console.log("[SSE API] Received data:", data);
          onMessage(data);
          // Keep anything after the JSON for next event
          jsonBuffer = jsonBuffer.slice(jsonEnd + 1);
        } catch (e) {
          // Not complete yet, keep buffering
          console.log(
            "[SSE API] Buffering, not complete JSON yet, buffer length:",
            jsonBuffer.length,
          );
        }
      }
    } catch (e) {
      console.error("SSE onmessage error:", e);
    }
  };

  eventSource.onerror = (error) => {
    console.error("[SSE API] EventSource onerror:", error);
    onError?.(error);
  };

  eventSource.onopen = () => {
    console.log("[SSE API] EventSource connected");
  };

  return eventSource;
}

// List all chat sessions with pagination
export async function getChats(
  sortBy: "created_at" | "session_name" | "agent" = "created_at",
  direction: "asc" | "desc" = "desc",
  limit: number = 10,
  cursor?: string,
): Promise<{
  sessions: Chat[];
  has_more: boolean;
  next_cursor: string | null;
}> {
  try {
    const params = new URLSearchParams({
      sort_by: sortBy,
      direction: direction,
      limit: limit.toString(),
    });
    if (cursor) {
      params.set("cursor", cursor);
    }
    const response = await fetch(`${API_BASE}/llm/session?${params}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = await response.json();

    // Fix: handle "undefined" or missing session_id in each session
    if (data.sessions && Array.isArray(data.sessions)) {
      data.sessions = data.sessions.map((session: any) => {
        const sessionId = session.session_id || session.id;
        if (!sessionId || sessionId === "undefined" || sessionId === "null") {
          // Generate proper session ID for invalid entries
          const timestamp = new Date()
            .toISOString()
            .replace(/[:-]/g, "")
            .replace("T", "_")
            .replace(/\.\d{3}Z$/, "");
          return {
            session_id: `session_${timestamp}`,
            session_name: session.session_name || session.name || "New Session",
            status: session.status || "active",
          };
        }
        return {
          session_id: sessionId,
          session_name: session.session_name || session.name || "New Session",
          status: session.status || "active",
        };
      });
    }

    return {
      sessions: data.sessions || [],
      has_more: data.has_more || false,
      next_cursor: data.next_cursor || null,
    };
  } catch (error) {
    // Return empty sessions when LLM backend unavailable
    return { sessions: [], has_more: false, next_cursor: null };
  }
}

// Legacy chat functions (kept for compatibility)
export interface ChatLegacy {
  id: string;
  label: string;
  icon: string;
  active?: boolean;
}

export async function getChatsLegacy(): Promise<{ chats: ChatLegacy[] }> {
  const response = await fetch(`${API_BASE}/chats`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function createChat(
  name: string,
  icon: string = "💬",
): Promise<ChatLegacy> {
  const response = await fetch(`${API_BASE}/chats`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, icon }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function deleteChat(id: string): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/chats/${id}`, { method: "DELETE" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Compact chat session history
export async function compactSession(
  sessionId: string,
): Promise<{ success: boolean; message?: string }> {
  try {
    const response = await fetch(`${API_BASE}/session/${sessionId}/compact`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  } catch (error) {
    console.error("Failed to compact session:", error);
    return { success: false, message: "Failed to compact session" };
  }
}

// Worker API
export interface Worker {
  id: string;
  session_id: string;
  working_directory: string | null;
  last_activity: string | null;
  last_activity_description: string | null;
  created_at: string | null;
  status: string;
  is_running: boolean;
  queue_count: number;
}

export async function getWorkers(
  status?: string,
  limit = 50,
  sessionId?: string,
): Promise<{ workers: Worker[]; count: number }> {
  const params = new URLSearchParams({ limit: limit.toString() });
  if (status) params.set("status", status);
  if (sessionId) params.set("session_id", sessionId);
  const response = await fetch(`${API_BASE}/workers?${params}`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Workspace Item API
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path: string,
  itemType: string = "folder",
): Promise<WorkspaceItem> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, path, item_type: itemType }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function deleteWorkspaceItem(
  workspaceId: string,
  itemId: string,
): Promise<{ success: boolean }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}`,
    {
      method: "DELETE",
    },
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Skills API
export interface Skill {
  name: string;
  description: string;
  path?: string;
}

export interface SkillDetail extends Skill {
  content: string;
  is_global: boolean;
}

export interface SkillDeleteResponse {
  success: boolean;
  skill_name: string;
  deleted_from: string | null;
  error_message: string | null;
}

export async function getSkills(): Promise<{
  global_skills: Skill[];
  local_skills: Skill[];
}> {
  const response = await fetch(`${API_BASE}/skills`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function getSkillDetail(
  name: string,
): Promise<{ skill: SkillDetail | null; error_message: string | null }> {
  const response = await fetch(
    `${API_BASE}/skills/${encodeURIComponent(name)}`,
  );
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function deleteSkill(
  name: string,
  options: { is_global?: boolean; cwd?: string },
): Promise<SkillDeleteResponse> {
  const params = new URLSearchParams({ name });
  if (options.is_global !== undefined) {
    params.set("is_global", options.is_global.toString());
  }
  if (options.cwd) {
    params.set("cwd", options.cwd);
  }
  const response = await fetch(`${API_BASE}/skills?${params}`, {
    method: "DELETE",
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

// Git Status API
export interface GitStatus {
  is_git_repo: boolean;
  branch: string;
  has_changes: boolean;
  is_clean: boolean;
  current: string;
  status: string;
}

export async function getGitStatus(cwd: string): Promise<GitStatus> {
  try {
    const response = await fetch(
      `${API_BASE}/git/status?path=${encodeURIComponent(cwd)}`,
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  } catch (error) {
    // Return non-repo status on error
    return {
      is_git_repo: false,
      branch: "",
      has_changes: false,
      is_clean: true,
      current: "",
      status: "error",
    };
  }
}

// File listing for autocomplete
export async function listFiles(
  cwd: string,
  dirPath?: string,
): Promise<string[]> {
  try {
    const targetPath = dirPath || cwd;
    const response = await fetch(
      `${API_BASE}/system/folder?path=${encodeURIComponent(targetPath)}&action=list`,
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    // Return names sorted, directories first
    const entries = data.entries || [];
    return entries
      .map((e: FolderEntry) => e.name)
      .sort((a: string, b: string) => {
        const aIsDir = entries.find(
          (e: FolderEntry) => e.name === a,
        )?.is_directory;
        const bIsDir = entries.find(
          (e: FolderEntry) => e.name === b,
        )?.is_directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return a.localeCompare(b);
      });
  } catch (error) {
    console.error("Failed to list files:", error);
    return [];
  }
}

// Session event types for SSE subscription
export interface SessionEvent {
  action: "created" | "updated" | "deleted";
  id: string;
  name: string;
  status: string;
  cwd: string;
  created_at: string;
  updated_at: string;
}

// Create SSE connection for session events (global chat list updates)
export function createSessionsSseConnection(
  onEvent: (event: SessionEvent) => void,
  onError?: (error: Event) => void,
  onConnected?: () => void,
): EventSource {
  console.log(
    "[createSessionsSseConnection] Creating SSE connection for session events",
  );
  const eventSource = new EventSource(`${API_BASE}/sessions/stream`);

  // Buffer to accumulate multi-line JSON
  let jsonBuffer = "";

  // Handle named event: "connected"
  eventSource.addEventListener("connected", (e: MessageEvent) => {
    try {
      const data = JSON.parse(e.data);
      console.log("[SessionsSSE] connected event:", data);
      onConnected?.();
    } catch (err) {
      console.error("Failed to parse connected event:", err);
    }
  });

  // Handle default events (data: lines without event: prefix)
  eventSource.onmessage = (event) => {
    console.log("[SessionsSSE] onmessage raw:", JSON.stringify(event.data));
    try {
      const raw = event.data;
      if (!raw) return;

      const trimmed = raw.trim();
      if (!trimmed) return;

      // Accumulate JSON until we have complete object
      jsonBuffer += trimmed + "\n";

      // Try to find complete JSON object (starts with { and ends with })
      const jsonStart = jsonBuffer.indexOf("{");
      const jsonEnd = jsonBuffer.lastIndexOf("}");

      if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
        const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1);
        try {
          const data = JSON.parse(jsonStr);
          console.log("[SessionsSSE] Received data:", data);
          onEvent(data as SessionEvent);
          // Keep anything after the JSON for next event
          jsonBuffer = jsonBuffer.slice(jsonEnd + 1);
        } catch (e) {
          // Not complete yet, keep buffering
          console.log(
            "[SessionsSSE] Buffering, not complete JSON yet, buffer length:",
            jsonBuffer.length,
          );
        }
      }
    } catch (e) {
      console.error("SessionsSSE onmessage error:", e);
    }
  };

  eventSource.onerror = (error) => {
    console.error("[SessionsSSE] EventSource onerror:", error);
    onError?.(error);
  };

  eventSource.onopen = () => {
    console.log("[SessionsSSE] EventSource connected");
  };

  return eventSource;
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
): EventSource {
  console.log(
    "[createQueueMessagesSseConnection] Creating SSE connection for session:",
    sessionId,
  );
  const eventSource = new EventSource(`${API_BASE}/llm/session/${sessionId}/queue_messages/stream`);

  // Buffer to accumulate multi-line JSON
  let jsonBuffer = "";

  // Handle named event: "queue_message"
  eventSource.addEventListener("queue_message", (e: MessageEvent) => {
    try {
      const data = JSON.parse(e.data);
      console.log("[QueueMessagesSSE] queue_message event:", data);
      onEvent(data as QueueMessageEvent);
      onConnected?.();
    } catch (err) {
      console.error("Failed to parse queue_message event:", err);
    }
  });

  // Handle default events (data: lines without event: prefix)
  eventSource.onmessage = (event) => {
    console.log("[QueueMessagesSSE] onmessage raw:", JSON.stringify(event.data));
    try {
      const raw = event.data;
      if (!raw) return;

      const trimmed = raw.trim();
      if (!trimmed) return;

      // Accumulate JSON until we have complete object
      jsonBuffer += trimmed + "\n";

      // Try to find complete JSON object (starts with { and ends with })
      const jsonStart = jsonBuffer.indexOf("{");
      const jsonEnd = jsonBuffer.lastIndexOf("}");

      if (jsonStart !== -1 && jsonEnd !== -1 && jsonEnd > jsonStart) {
        const jsonStr = jsonBuffer.slice(jsonStart, jsonEnd + 1);
        try {
          const data = JSON.parse(jsonStr);
          console.log("[QueueMessagesSSE] Received data:", data);
          onEvent(data as QueueMessageEvent);
          // Keep anything after the JSON for next event
          jsonBuffer = jsonBuffer.slice(jsonEnd + 1);
        } catch (e) {
          // Not complete yet, keep buffering
          console.log(
            "[QueueMessagesSSE] Buffering, not complete JSON yet, buffer length:",
            jsonBuffer.length,
          );
        }
      }
    } catch (e) {
      console.error("QueueMessagesSSE onmessage error:", e);
    }
  };

  eventSource.onerror = (error) => {
    console.error("[QueueMessagesSSE] EventSource onerror:", error);
    onError?.(error);
  };

  eventSource.onopen = () => {
    console.log("[QueueMessagesSSE] EventSource connected");
  };

  return eventSource;
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

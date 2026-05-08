// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls

const API_BASE = "/api";

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
  icon: string;
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
  const response = await fetch(`${API_BASE}/system/folder`);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json();
}

export async function listFolder(path: string): Promise<FolderInfo> {
  const response = await fetch(
    `${API_BASE}/system/folder/list?path=${encodeURIComponent(path)}`,
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
}

// All chat endpoints go through Zig backend at /api/llm/*
// Zig backend internally calls LLM backend

// Create a new chat session
export async function createSession(name?: string): Promise<Chat> {
  try {
    const response = await fetch(`${API_BASE}/llm/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: name || "New Chat",
        cwd_session: "/home/ginwa/agentic_coding_zig/ginwaaitoolbox",
      }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = await response.json();

    // Fix: handle "undefined" string from backend or missing session_id
    const sessionId = data.session_id || data.id;
    if (!sessionId || sessionId === "undefined" || sessionId === "null") {
      // Generate proper session ID
      const timestamp = new Date()
        .toISOString()
        .replace(/[:-]/g, "")
        .replace("T", "_")
        .replace(/\.\d{3}Z$/, "");
      return {
        session_id: `session_${timestamp}`,
        session_name: data.session_name || data.name || name || "New Chat",
        status: data.status || "send",
      };
    }

    return {
      session_id: sessionId,
      session_name: data.session_name || data.name || name || "New Chat",
      status: data.status || "send",
    };
  } catch (error) {
    // Return offline mock session when LLM backend unavailable
    return {
      session_id: `local-${Date.now()}`,
      session_name: name || "New Chat",
      status: "offline",
    };
  }
}

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
        }) => ({
          ...msg,
          content: msg.content,
          created_at: parseTimestamp(msg.created_at),
          tool_name: msg.tool_name,
        }),
      ),
      has_more: data.has_more,
      next_cursor: data.next_cursor,
      cwd: data.cwd,
    };
  } catch (error) {
    // Return empty messages when LLM backend unavailable
    console.log(error);
    return { messages: [], has_more: false, next_cursor: null, cwd: undefined };
  }
}

// Send a message to LLM
export async function sendChatMessage(
  sessionId: string,
  message: string,
  cwdSession: string,
): Promise<{ status: string }> {
  try {
    // todo hardcode cwd\
    cwdSession = "/home/ginwa/agentic_coding_zig/ginwaaitoolbox";
    const response = await fetch(`${API_BASE}/llm/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        session_id: sessionId,
        queue_message: message,
        allowed_tools: "all",
        cwd_session: cwdSession,
      }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  } catch (error) {
    // Return offline status when LLM backend unavailable
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
}

// Strip thinking tags and extract content from special wrappers
// This should be used at the display layer (Vue), NOT in API responses
export function stripThinkingTags(content: string | undefined): string {
  if (!content) return "";
  let result = content.trim();

  // Remove <think>... blocks
  result = result.replace(/<think>[\s\S]*?<\/think>/gi, "");

  // Remove <plain>...</plain> tags and extract inner content
  result = result.replace(/<plain>\s*/g, "").replace(/\s*<\/plain>/g, "");

  // Remove <markdown>...</markdown> wrapper but KEEP the inner content
  result = result
    .replace(/<markdown>\s*/gi, "")
    .replace(/\s*<\/markdown>/gi, "");

  return result.trim();
}

// Check if content is wrapped in markdown tags (for rendering decision)
export function hasMarkdownWrapper(content: string | undefined): boolean {
  if (!content) return false;
  return /<markdown>[\s\S]*<\/markdown>/gi.test(content);
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

// List all chat sessions
export async function getChats(
  sortBy: 'created_at' | 'session_name' | 'agent' = 'created_at',
  direction: 'asc' | 'desc' = 'desc'
): Promise<{ sessions: Chat[] }> {
  try {
    const params = new URLSearchParams({
      sort_by: sortBy,
      direction: direction,
    });
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

    return data;
  } catch (error) {
    // Return empty sessions when LLM backend unavailable
    return { sessions: [] };
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

// Workspace Item API
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path: string,
  icon: string = "📁",
): Promise<WorkspaceItem> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name, path, icon }),
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

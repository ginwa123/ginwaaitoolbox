// API Service - Centralized API calls for desktop backend
// All components should use this file instead of making direct fetch calls

const API_BASE = '/api'

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
  icon: string
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
export async function healthCheck(): Promise<{ status: string; timestamp: number }> {
  const response = await fetch(`${API_BASE}/health`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// System Folder API
export async function getSystemFolder(): Promise<FolderInfo> {
  const response = await fetch(`${API_BASE}/system/folder`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function listFolder(path: string): Promise<FolderInfo> {
  const response = await fetch(`${API_BASE}/system/folder/list?path=${encodeURIComponent(path)}`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  const response = await fetch(`${API_BASE}/workspaces`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function createWorkspace(name: string, items: WorkspaceItem[] = []): Promise<Workspace> {
  const response = await fetch(`${API_BASE}/workspaces`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, items }),
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
  const response = await fetch(`${API_BASE}/workspaces/${id}`, { method: 'DELETE' })
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
  description?: string
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
  data: Partial<Task>
): Promise<{ success: boolean }> {
  const response = await fetch(`${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`, {
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
  taskId: string
): Promise<{ success: boolean }> {
  const response = await fetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}`,
    { method: 'DELETE' }
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

// Chat API (placeholder for future AI integration)
export async function sendChatMessage(
  message: string,
  sessionId?: string
): Promise<{ response: string; session_id: string }> {
  const response = await fetch(`${API_BASE}/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message, session_id: sessionId }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function getChatHistory(sessionId: string): Promise<{ messages: Message[] }> {
  const response = await fetch(`${API_BASE}/chat/history/${sessionId}`)
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export interface Message {
  id: string
  role: 'user' | 'assistant'
  content: string
  timestamp: number
}

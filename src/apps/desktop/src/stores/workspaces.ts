import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { useNavigationStore } from './navigation'

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  path?: string
  lastAccessed?: Date
  entries?: FolderEntry[]  // Nested folder contents
  isLoaded?: boolean       // Whether contents have been fetched
  isLoading?: boolean      // Loading state
  expanded?: boolean       // Whether nested contents are expanded
  tasks?: Task[]           // Tasks within this project
}

export interface Workspace {
  id: string
  name: string
  icon: string
  items: WorkspaceItem[]
  expanded: boolean
}

export interface SystemFolderInfo {
  path: string
  absolute: string
  home: string
  parent?: string
  entries?: FolderEntry[]
}

export interface FolderEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

// Task interface for project tasks
export interface Task {
  id: string
  name: string
  description?: string
  completed?: boolean
  createdAt?: Date
}

// localStorage keys for state persistence
const STORAGE_KEY_WORKSPACE_EXPANDED = 'nalar-workspace-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_EXPANDED = 'nalar-workspace-item-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED = 'nalar-workspace-item-tasks-expanded'

import * as api from '../api'

export const useWorkspacesStore = defineStore('workspaces', () => {
  // Loading state
  const isLoading = ref(false)
  const loadingError = ref<string | null>(null)

  // Current active workspace item (for main content/FolderExplorer)
  const activeWorkspaceItemId = ref<string | null>(null)

  // Set of expanded workspace item IDs (for showing tasks list - allows multiple)
  const expandedItemIds = ref<Record<string, boolean>>({})

  // Active task within the selected workspace item
  const activeTaskId = ref<string | null>(null)

  // System folder info from API
  const systemFolderInfo = ref<SystemFolderInfo | null>(null)
  const systemFolderLoading = ref(false)
  const systemFolderError = ref<string | null>(null)

  // Workspaces with their items
  const workspaces = ref<Workspace[]>([])

  // Load expanded workspace IDs from localStorage
  function loadExpandedWorkspaces(): Set<string> {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_EXPANDED)
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed)) {
          return new Set(parsed)
        }
      } catch (e) {
        console.error('Failed to parse expanded workspaces:', e)
      }
    }
    return new Set()
  }

  // Load expanded workspace item IDs from localStorage (for nested folder expansion)
  function loadExpandedItems(): Set<string> {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_ITEM_EXPANDED)
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed)) {
          return new Set(parsed)
        }
      } catch (e) {
        console.error('Failed to parse expanded items:', e)
      }
    }
    return new Set()
  }

  // Load expanded workspace item IDs for tasks list from localStorage
  function loadExpandedItemIds(): Record<string, boolean> {
    const saved = localStorage.getItem(STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED)
    if (saved) {
      try {
        const parsed = JSON.parse(saved)
        if (Array.isArray(parsed)) {
          const record: Record<string, boolean> = {}
          for (const id of parsed) {
            record[id] = true
          }
          return record
        }
      } catch (e) {
        console.error('Failed to parse expanded item IDs:', e)
      }
    }
    return {}
  }

  // Save expanded workspace IDs to localStorage
  function saveExpandedWorkspaces(expandedIds: Set<string>) {
    localStorage.setItem(STORAGE_KEY_WORKSPACE_EXPANDED, JSON.stringify(Array.from(expandedIds)))
  }

  // Save expanded workspace item IDs to localStorage (for nested folder expansion)
  function saveExpandedItems(expandedIds: Set<string>) {
    localStorage.setItem(STORAGE_KEY_WORKSPACE_ITEM_EXPANDED, JSON.stringify(Array.from(expandedIds)))
  }

  // Save expanded workspace item IDs for tasks list to localStorage
  function saveExpandedItemIds(expandedIds: Record<string, boolean>) {
    localStorage.setItem(STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED, JSON.stringify(Object.keys(expandedIds)))
  }

  // Initialize store by loading data from API
  async function init() {
    isLoading.value = true
    loadingError.value = null

    try {
      // Step 1: fetch the workspaces list (no items — those come separately).
      const { workspaces: wsList } = await api.getWorkspaces()
      const expandedWorkspaces = loadExpandedWorkspaces()
      const expandedItems = loadExpandedItems()
      const expandedIds = loadExpandedItemIds()
      // Load expanded item IDs for tasks list from localStorage
      expandedItemIds.value = expandedIds

      // Step 2 + 3: fan out per-workspace items + per-item tasks in parallel.
      // A per-item tasks fetch failure is best-effort (logged + empty tasks
      // for that item) so a single bad item doesn't kill the whole init.
      workspaces.value = await Promise.all(
        (wsList || []).map(async (ws: Workspace) => {
          // Items for this workspace.
          const { items } = await api.getWorkspacesItems(ws.id)

          // Tasks for each item in this workspace (per-item, in parallel).
          const tasksByItem = new Map<string, Task[]>()
          await Promise.all(
            (items || []).map(async (item: WorkspaceItem) => {
              try {
                const { tasks } = await api.getTasks(ws.id, item.id)
                if (tasks && tasks.length > 0) {
                  tasksByItem.set(item.id, tasks)
                }
              } catch (err) {
                console.error(`Failed to fetch tasks for item ${item.id}:`, err)
              }
            }),
          )

          return {
            ...ws,
            // Restore expanded state from localStorage
            expanded: expandedWorkspaces.has(ws.id),
            items: (items || []).map((item: WorkspaceItem) => ({
              ...item,
              // Restore expanded state from localStorage
              expanded: expandedItems.has(item.id),
              // Attach tasks for this item (may be [] if no tasks or fetch failed).
              tasks: tasksByItem.get(item.id) ?? [],
            })),
          }
        }),
      )
    } catch (err) {
      loadingError.value = err instanceof Error ? err.message : 'Failed to load workspaces'
      console.error('Failed to load workspaces:', err)
      // Initialize with empty array on error
      workspaces.value = []
    } finally {
      isLoading.value = false
    }
  }

  // Computed: get flattened list of all workspace items
  const allWorkspaceItems = computed(() => {
    return workspaces.value.flatMap((ws) => ws.items)
  })

  // Get active workspace item details
  const activeWorkspaceItem = computed(() => {
    return allWorkspaceItems.value.find((item) => item.id === activeWorkspaceItemId.value)
  })

  // Get active workspace (parent)
  const activeWorkspace = computed(() => {
    return workspaces.value.find((ws) =>
      ws.items.some((item) => item.id === activeWorkspaceItemId.value)
    )
  })

  // Get active task details
  const activeTask = computed(() => {
    if (!activeTaskId.value || !activeWorkspaceItemId.value) return null
    
    const workspace = workspaces.value.find((ws) =>
      ws.items.some((item) => item.id === activeWorkspaceItemId.value)
    )
    if (!workspace) return null
    
    const item = workspace.items.find((i) => i.id === activeWorkspaceItemId.value)
    if (!item?.tasks) return null
    
    return item.tasks.find((t) => t.id === activeTaskId.value) || null
  })

  // Actions
  async function fetchSystemFolder(folderPath?: string) {
    systemFolderLoading.value = true
    systemFolderError.value = null

    try {
      const data = folderPath ? await api.listFolder(folderPath) : await api.getSystemFolder()
      systemFolderInfo.value = {
        path: data.path,
        absolute: data.absolute,
        home: data.home,
        parent: data.parent,
        entries: data.entries,
      }
      return data
    } catch (err) {
      systemFolderError.value = err instanceof Error ? err.message : 'Failed to fetch'
      console.error('Failed to fetch system folder:', err)
      throw err
    } finally {
      systemFolderLoading.value = false
    }
  }

  // Fetch folder contents for a specific workspace item
  async function fetchFolderContents(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.path) return

    // Mark as loading
    item.isLoading = true

    try {
      const data = await fetchSystemFolder(item.path)

      // Update entries
      item.entries = data.entries || []
      item.isLoaded = true
      // Don't auto-expand - let user control expanded state
    } catch (err) {
      console.error('Failed to fetch folder contents:', err)
      item.entries = []
    } finally {
      item.isLoading = false
    }
  }

  function toggleWorkspace(workspaceId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      workspace.expanded = !workspace.expanded
      // Persist to localStorage
      const expandedWorkspaces = loadExpandedWorkspaces()
      if (workspace.expanded) {
        expandedWorkspaces.add(workspaceId)
      } else {
        expandedWorkspaces.delete(workspaceId)
      }
      saveExpandedWorkspaces(expandedWorkspaces)
    }
  }

  // Toggle workspace item expansion (for nested folder contents)
  function toggleWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return

    item.expanded = !item.expanded
    // Persist to localStorage
    const expandedItems = loadExpandedItems()
    if (item.expanded) {
      expandedItems.add(itemId)
    } else {
      expandedItems.delete(itemId)
    }
    saveExpandedItems(expandedItems)
  }

  function setActiveWorkspaceItem(itemId: string | null) {
    activeWorkspaceItemId.value = itemId
  }

  // Toggle expanded state for workspace item (show/hide tasks list)
  function toggleExpandedItem(itemId: string) {
    console.log('[toggleExpandedItem] Before:', JSON.stringify(expandedItemIds.value), 'itemId:', itemId)
    if (expandedItemIds.value[itemId]) {
      delete expandedItemIds.value[itemId]
    } else {
      expandedItemIds.value[itemId] = true
    }
    // Trigger reactivity
    expandedItemIds.value = { ...expandedItemIds.value }
    console.log('[toggleExpandedItem] After:', JSON.stringify(expandedItemIds.value))
    saveExpandedItemIds(expandedItemIds.value)
  }

  async function addWorkspace(name: string, icon: string = '📂') {
    try {
      const newWorkspace = await api.createWorkspace(name, icon)
      const expandedWorkspaces = loadExpandedWorkspaces()
      workspaces.value.unshift({
        ...newWorkspace,
        expanded: expandedWorkspaces.has(newWorkspace.id),
        items: newWorkspace.items || [],
      })
    } catch (err) {
      console.error('Failed to create workspace:', err)
      // Fallback to local creation if API fails
      const id = `workspace-${Date.now()}`
      const expandedWorkspaces = loadExpandedWorkspaces()
      workspaces.value.unshift({
        id,
        name,
        icon,
        expanded: expandedWorkspaces.has(id),
        items: [],
      })
    }
  }

  async function addWorkspaceItem(workspaceId: string, name: string, path: string, itemType: string = 'folder'): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    try {
      const newItem = await api.createWorkspaceItem(workspaceId, name, path, itemType)
      const expandedItems = loadExpandedItems()
      workspace.items.push({
        ...newItem,
        expanded: expandedItems.has(newItem.id),
      })
      // Auto-expand workspace to show new item and persist
      if (!workspace.expanded) {
        workspace.expanded = true
        const expandedWorkspaces = loadExpandedWorkspaces()
        expandedWorkspaces.add(workspace.id)
        saveExpandedWorkspaces(expandedWorkspaces)
      }
      return newItem.id
    } catch (err) {
      console.error('Failed to create workspace item:', err)
      // Fallback to local creation if API fails
      const itemId = `item-${Date.now()}`
      const expandedItems = loadExpandedItems()
      workspace.items.push({
        id: itemId,
        name,
        item_type: itemType,
        path,
        expanded: expandedItems.has(itemId),
      })
      // Auto-expand workspace to show new item and persist
      if (!workspace.expanded) {
        workspace.expanded = true
        const expandedWorkspaces = loadExpandedWorkspaces()
        expandedWorkspaces.add(workspace.id)
        saveExpandedWorkspaces(expandedWorkspaces)
      }
      return itemId
    }
  }

  // Add a task to a workspace item
  async function addTask(workspaceId: string, itemId: string, name: string, description?: string): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return undefined

    if (!item.tasks) {
      item.tasks = []
    }

    try {
      const newTask = await api.createTask(workspaceId, itemId, name, description)
      item.tasks.unshift(newTask)
      return newTask.id
    } catch (err) {
      console.error('Failed to create task:', err)
      // Fallback to local creation if API fails
      const taskId = `task-${Date.now()}`
      item.tasks.unshift({
        id: taskId,
        name,
        description,
        completed: false,
        createdAt: new Date(),
      })
      return taskId
    }
  }

  // Toggle task completion
  async function toggleTask(workspaceId: string, itemId: string, taskId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    const task = item.tasks.find((t) => t.id === taskId)
    if (task) {
      task.completed = !task.completed
      // Sync with API
      try {
        await api.updateTask(workspaceId, itemId, taskId, { completed: task.completed })
      } catch (err) {
        console.error('Failed to update task:', err)
        // Revert on error
        task.completed = !task.completed
      }
    }
  }

  // Delete a task
  async function deleteTask(workspaceId: string, itemId: string, taskId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    // Store reference for potential rollback
    const taskIndex = item.tasks.findIndex((t) => t.id === taskId)
    if (taskIndex === -1) return

    const deletedTask = item.tasks[taskIndex]
    item.tasks = item.tasks.filter((t) => t.id !== taskId)

    // Clear active task if it was the deleted one
    if (activeTaskId.value === taskId) {
      activeTaskId.value = null
    }

    // Sync with API
    try {
      await api.deleteTask(workspaceId, itemId, taskId)
    } catch (err) {
      console.error('Failed to delete task:', err)
      // Rollback on error
      if (deletedTask) {
        item.tasks.splice(taskIndex, 0, deletedTask)
      }
    }
  }

  // Set active task - also ensures parent workspace is expanded
  function setActiveTask(taskId: string | null) {
    activeTaskId.value = taskId
    if (taskId) {
      // Find parent workspace and item, then expand workspace
      for (const workspace of workspaces.value) {
        for (const item of workspace.items) {
          if (item.tasks?.some((t) => t.id === taskId)) {
            // Found the parent - set active item
            activeWorkspaceItemId.value = item.id
            // Expand workspace and persist if not already expanded
            if (!workspace.expanded) {
              workspace.expanded = true
              const expandedWorkspaces = loadExpandedWorkspaces()
              expandedWorkspaces.add(workspace.id)
              saveExpandedWorkspaces(expandedWorkspaces)
            }
            return
          }
        }
      }
    }
  }

  async function removeWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    // Store for potential rollback
    const itemIndex = workspace.items.findIndex((i) => i.id === itemId)
    if (itemIndex === -1) return

    const removedItem = workspace.items[itemIndex]
    workspace.items = workspace.items.filter((item) => item.id !== itemId)

    if (activeWorkspaceItemId.value === itemId) {
      activeWorkspaceItemId.value = null
    }

    // Remove from expandedItemIds if present
    if (expandedItemIds.value[itemId]) {
      delete expandedItemIds.value[itemId]
      expandedItemIds.value = { ...expandedItemIds.value }
      saveExpandedItemIds(expandedItemIds.value)
    }

    // Sync with API
    try {
      await api.deleteWorkspaceItem(workspaceId, itemId)
    } catch (err) {
      console.error('Failed to delete workspace item:', err)
      // Rollback on error
      if (removedItem) {
        workspace.items.splice(itemIndex, 0, removedItem)
      }
    }
  }

  // Rename a workspace
  async function renameWorkspace(workspaceId: string, newName: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const trimmed = newName.trim()
    if (!trimmed || trimmed === workspace.name) return

    const previousName = workspace.name
    // Optimistic update
    workspace.name = trimmed

    // Sync with API
    try {
      await api.updateWorkspace(workspaceId, { name: trimmed })
    } catch (err) {
      console.error('Failed to rename workspace:', err)
      // Rollback on error
      workspace.name = previousName
    }
  }

  // Rename a task. Cascades to the linked session via the backend
  // (`updateTaskName` in llm_history.zig, then onEventSendSessions
  // SSE broadcast) so the ChatsList picks up the new name. Mirrors
  // the optimistic-update + rollback pattern from `renameWorkspace`.
  // If the renamed task is the active one, also keeps
  // `navigationStore.activeChatName` in sync — the chat-view header
  // (AppLayout.vue:652) binds `:chat-name="activeTask.name"` and
  // updates automatically, but other views (e.g. the chat-list
  // header) read `activeChatName` and would otherwise show stale.
  async function renameTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    newName: string,
  ) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return

    const trimmed = newName.trim()
    if (!trimmed || trimmed === task.name) return

    const previousName = task.name
    // Optimistic update
    task.name = trimmed

    // Keep the chat-view / chat-list header in sync if this is the
    // active task.
    const wasActive = activeTaskId.value === taskId
    if (wasActive) {
      useNavigationStore().setActiveChatName(trimmed)
    }

    // Sync with API. The backend PUT /api/workspaces/tasks/:task_id
    // cascades the rename to the linked session row and broadcasts
    // a session.updated SSE event (see backend tasks_update.zig).
    try {
      await api.updateTaskSimple(taskId, { name: trimmed })
    } catch (err) {
      console.error('Failed to rename task:', err)
      // Rollback on error
      task.name = previousName
      if (wasActive) {
        useNavigationStore().setActiveChatName(previousName)
      }
    }
  }

  async function removeWorkspace(workspaceId: string) {
    const workspaceIndex = workspaces.value.findIndex((ws) => ws.id === workspaceId)
    if (workspaceIndex === -1) return

    const removedWorkspace = workspaces.value[workspaceIndex]
    workspaces.value = workspaces.value.filter((ws) => ws.id !== workspaceId)

    // Clear active if affected
    if (removedWorkspace) {
      removedWorkspace.items.forEach((item) => {
        if (activeWorkspaceItemId.value === item.id) {
          activeWorkspaceItemId.value = null
        }
      })
    }

    // Sync with API
    try {
      await api.deleteWorkspace(workspaceId)
    } catch (err) {
      console.error('Failed to delete workspace:', err)
      // Rollback on error
      if (removedWorkspace) {
        workspaces.value.splice(workspaceIndex, 0, removedWorkspace)
      }
    }
  }

  // Update workspace item path from system folder
  function updateWorkspaceItemPath(workspaceId: string, itemId: string, newPath: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      const item = workspace.items.find((i) => i.id === itemId)
      if (item) {
        item.path = newPath
      }
    }
  }

  // Initialize workspace items from system folder
  async function initializeFromSystemFolder() {
    // First, load workspaces from API
    await init()
    
    // Also fetch system folder info for navigation
    await fetchSystemFolder()

    // Restore active task if it was set before workspaces were loaded
    // This handles the case where setActiveTask was called before init() completed
    if (activeTaskId.value) {
      // Find and set the parent workspace item for the active task
      for (const workspace of workspaces.value) {
        for (const item of workspace.items) {
          if (item.tasks?.some((t) => t.id === activeTaskId.value)) {
            // Found the parent - ensure it's set correctly
            activeWorkspaceItemId.value = item.id
            // Expand workspace if not already expanded
            if (!workspace.expanded) {
              workspace.expanded = true
              const expandedWorkspaces = loadExpandedWorkspaces()
              expandedWorkspaces.add(workspace.id)
              saveExpandedWorkspaces(expandedWorkspaces)
            }
            return
          }
        }
      }
    }
  }

  return {
    // State
    workspaces,
    activeWorkspaceItemId,
    expandedItemIds,
    activeTaskId,
    systemFolderInfo,
    systemFolderLoading,
    systemFolderError,
    isLoading,
    loadingError,
    // Computed
    allWorkspaceItems,
    activeWorkspaceItem,
    activeWorkspace,
    activeTask,
    // Actions
    init,
    toggleWorkspace,
    toggleWorkspaceItem,
    toggleExpandedItem,
    setActiveWorkspaceItem,
    setActiveTask,
    addWorkspace,
    addWorkspaceItem,
    removeWorkspaceItem,
    removeWorkspace,
    renameWorkspace,
    updateWorkspaceItemPath,
    addTask,
    toggleTask,
    deleteTask,
    renameTask,
    initializeFromSystemFolder,
    fetchSystemFolder,
    fetchFolderContents,
  }
})

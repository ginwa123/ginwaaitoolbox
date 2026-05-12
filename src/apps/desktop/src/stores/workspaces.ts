import { defineStore } from 'pinia'
import { ref, computed } from 'vue'

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

import * as api from '../api'

export const useWorkspacesStore = defineStore('workspaces', () => {
  // Loading state
  const isLoading = ref(false)
  const loadingError = ref<string | null>(null)

  // Current active workspace item
  const activeWorkspaceItemId = ref<string | null>(null)

  // Active task within the selected workspace item
  const activeTaskId = ref<string | null>(null)

  // System folder info from API
  const systemFolderInfo = ref<SystemFolderInfo | null>(null)
  const systemFolderLoading = ref(false)
  const systemFolderError = ref<string | null>(null)

  // Workspaces with their items
  const workspaces = ref<Workspace[]>([])

  // Initialize store by loading data from API
  async function init() {
    isLoading.value = true
    loadingError.value = null

    try {
      const data = await api.getWorkspaces()
      workspaces.value = data.workspaces || []
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
    }
  }

  function setActiveWorkspaceItem(itemId: string | null) {
    activeWorkspaceItemId.value = itemId
    // Don't auto-expand - preserve user's expanded states
  }

  async function addWorkspace(name: string, icon: string = '📂') {
    try {
      const newWorkspace = await api.createWorkspace(name, icon)
      workspaces.value.push({
        ...newWorkspace,
        expanded: false,
        items: newWorkspace.items || [],
      })
    } catch (err) {
      console.error('Failed to create workspace:', err)
      // Fallback to local creation if API fails
      workspaces.value.push({
        id: `workspace-${Date.now()}`,
        name,
        icon,
        expanded: false,
        items: [],
      })
    }
  }

  async function addWorkspaceItem(workspaceId: string, name: string, path: string, itemType: string = 'folder'): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    try {
      const newItem = await api.createWorkspaceItem(workspaceId, name, path, itemType)
      workspace.items.push(newItem)
      // Auto-expand workspace to show new item
      workspace.expanded = true
      return newItem.id
    } catch (err) {
      console.error('Failed to create workspace item:', err)
      // Fallback to local creation if API fails
      const itemId = `item-${Date.now()}`
      workspace.items.push({
        id: itemId,
        name,
        item_type: itemType,
        path,
      })
      workspace.expanded = true
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
      item.tasks.push(newTask)
      return newTask.id
    } catch (err) {
      console.error('Failed to create task:', err)
      // Fallback to local creation if API fails
      const taskId = `task-${Date.now()}`
      item.tasks.push({
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
            // Found the parent - set active item and expand workspace
            activeWorkspaceItemId.value = item.id
            workspace.expanded = true
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
  }

  return {
    // State
    workspaces,
    activeWorkspaceItemId,
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
    setActiveWorkspaceItem,
    setActiveTask,
    addWorkspace,
    addWorkspaceItem,
    removeWorkspaceItem,
    removeWorkspace,
    updateWorkspaceItemPath,
    addTask,
    toggleTask,
    deleteTask,
    initializeFromSystemFolder,
    fetchSystemFolder,
    fetchFolderContents,
  }
})

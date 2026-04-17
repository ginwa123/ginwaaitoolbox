import { defineStore } from 'pinia'
import { ref, computed, watch } from 'vue'

export interface WorkspaceItem {
  id: string
  name: string
  icon: string
  path?: string
  lastAccessed?: Date
  entries?: FolderEntry[]  // Nested folder contents
  isLoaded?: boolean       // Whether contents have been fetched
  isLoading?: boolean      // Loading state
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

const API_BASE = ''
const STORAGE_KEY = 'nalar-workspaces'

// Load persisted state from localStorage
function loadPersistedState(): { workspaces: Workspace[]; activeWorkspaceItemId: string | null } {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (stored) {
      return JSON.parse(stored)
    }
  } catch {
    // Ignore errors
  }
  return {
    workspaces: [],
    activeWorkspaceItemId: null,
  }
}

export const useWorkspacesStore = defineStore('workspaces', () => {
  // Load persisted state
  const persisted = loadPersistedState()

  // Current active workspace item
  const activeWorkspaceItemId = ref<string | null>(persisted.activeWorkspaceItemId)

  // System folder info from API
  const systemFolderInfo = ref<SystemFolderInfo | null>(null)
  const systemFolderLoading = ref(false)
  const systemFolderError = ref<string | null>(null)

  // Workspaces with their items (from persistence or empty)
  const workspaces = ref<Workspace[]>(persisted.workspaces)

  // Persist to localStorage on changes
  function persistState() {
    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          workspaces: workspaces.value,
          activeWorkspaceItemId: activeWorkspaceItemId.value,
        })
      )
    } catch {
      // Ignore errors
    }
  }

  // Watch for changes and persist
  watch(
    [workspaces, activeWorkspaceItemId],
    () => {
      persistState()
    },
    { deep: true }
  )

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

  // Actions
  async function fetchSystemFolder(path?: string) {
    systemFolderLoading.value = true
    systemFolderError.value = null

    try {
      const url = path ? `${API_BASE}/api/system/folder?path=${encodeURIComponent(path)}&action=list` : `${API_BASE}/api/system/folder`
      const response = await fetch(url)
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`)
      }
      const data = await response.json()
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

      // Auto-expand the workspace
      workspace.expanded = true
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
    if (itemId) {
      // Auto-expand parent workspace
      const parentWorkspace = workspaces.value.find((ws) =>
        ws.items.some((item) => item.id === itemId)
      )
      if (parentWorkspace) {
        workspaces.value.forEach((ws) => {
          ws.expanded = ws.id === parentWorkspace.id
        })
      }
    }
  }

  function addWorkspace(name: string, icon: string = '📂') {
    workspaces.value.push({
      id: `workspace-${Date.now()}`,
      name,
      icon,
      expanded: false,
      items: [],
    })
  }

  function addWorkspaceItem(workspaceId: string, name: string, icon: string = '◆') {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      workspace.items.push({
        id: `item-${Date.now()}`,
        name,
        icon,
      })
    }
  }

  function removeWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      workspace.items = workspace.items.filter((item) => item.id !== itemId)
      if (activeWorkspaceItemId.value === itemId) {
        activeWorkspaceItemId.value = null
      }
    }
  }

  function removeWorkspace(workspaceId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      workspace.items.forEach((item) => {
        if (activeWorkspaceItemId.value === item.id) {
          activeWorkspaceItemId.value = null
        }
      })
    }
    workspaces.value = workspaces.value.filter((ws) => ws.id !== workspaceId)
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
    await fetchSystemFolder()

    if (systemFolderInfo.value) {
      // Add system folder as a workspace if not exists
      const existingSystemWorkspace = workspaces.value.find(
        (ws) => ws.id === 'system-workspace'
      )

      if (!existingSystemWorkspace) {
        workspaces.value.unshift({
          id: 'system-workspace',
          name: 'Current Project',
          icon: '🏠',
          expanded: true,
          items: [
            {
              id: 'current-folder',
              name: systemFolderInfo.value.path || 'Root',
              icon: '📁',
              path: systemFolderInfo.value.absolute,
            },
          ],
        })
      } else {
        // Update existing system workspace
        const currentItem = existingSystemWorkspace.items.find(
          (i) => i.id === 'current-folder'
        )
        if (currentItem) {
          currentItem.name = systemFolderInfo.value.path || 'Root'
          currentItem.path = systemFolderInfo.value.absolute
        }
      }
    }
  }

  return {
    // State
    workspaces,
    activeWorkspaceItemId,
    systemFolderInfo,
    systemFolderLoading,
    systemFolderError,
    // Computed
    allWorkspaceItems,
    activeWorkspaceItem,
    activeWorkspace,
    // Actions
    toggleWorkspace,
    setActiveWorkspaceItem,
    addWorkspace,
    addWorkspaceItem,
    removeWorkspaceItem,
    removeWorkspace,
    updateWorkspaceItemPath,
    initializeFromSystemFolder,
    fetchSystemFolder,
    fetchFolderContents,
  }
})

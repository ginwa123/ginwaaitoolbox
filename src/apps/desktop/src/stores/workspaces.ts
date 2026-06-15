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
  // Pagination state for the task list. Populated when tasks are first
  // fetched (in init()) and reset whenever tasks are reloaded. `null`
  // next_cursor means there are no more pages. `isLoadingMoreTasks` is
  // per-item and independent of `isLoading` (which is for the folder
  // entry fetch). See loadMoreTasks action below.
  hasMoreTasks?: boolean
  tasksNextCursor?: string | null
  isLoadingMoreTasks?: boolean
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
//
// `task_type` distinguishes standard chat tasks from cron-scheduled
// routines (Chunk 5 of the task-routines plan). Optional so legacy
// task literals without it keep type-checking; runtime code defaults
// to 'standard'.
//
// `routine` is present iff `task_type === 'routine'`. It mirrors the
// API response shape from getTasks / createTask.
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
  // compat with legacy task literals (tests + offline fallbacks).
  task_type?: 'standard' | 'routine'
  // NEW: present iff task_type === 'routine'.
  routine?: RoutineMeta
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
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
                const { tasks, has_more, next_cursor } = await api.getTasks(ws.id, item.id)
                if (tasks && tasks.length > 0) {
                  tasksByItem.set(item.id, tasks)
                }
                // Stash pagination state on the item object directly.
                // The spread below copies these into the final item.
                // If the fetch failed, hasMoreTasks / tasksNextCursor
                // stay undefined → the Load More button stays hidden
                // (its v-if is `item.hasMoreTasks` which is falsy for
                // undefined). The user can retry by reloading the page.
                item.hasMoreTasks = has_more
                item.tasksNextCursor = next_cursor
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

  // Add a task to a workspace item.
  //
  // The third arg is a single params object. For a standard task
  // (the default), pass `{ name, description? }`. For a routine, pass
  // `{ name, taskType: 'routine', routine: { schedule, initial_prompt, enabled? } }`.
  //
  // taskType defaults to 'standard' so a caller that omits it gets
  // the legacy behavior. For routines, `routine` must include
  // `schedule` + `initial_prompt`; `enabled` defaults to true on the
  // backend.
  async function addTask(
    workspaceId: string,
    itemId: string,
    params: {
      name: string
      description?: string
      taskType?: 'standard' | 'routine'
      routine?: {
        schedule: string
        initial_prompt: string
        enabled?: boolean
      }
    },
  ): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return undefined

    if (!item.tasks) {
      item.tasks = []
    }

    const taskType: 'standard' | 'routine' = params.taskType ?? 'standard'

    try {
      const newTask = await api.createTask(workspaceId, itemId, {
        name: params.name,
        description: params.description,
        taskType,
        routine: params.routine,
      })
      item.tasks.unshift(newTask)
      return newTask.id
    } catch (err) {
      console.error('Failed to create task:', err)
      // Fallback to local creation if API fails. Match the
      // pre-existing fallback contract (returns a taskId, populates
      // the item's tasks list) and now also carry task_type +
      // routine so the offline UI still branches correctly.
      const taskId = `task-${Date.now()}`
      item.tasks.unshift({
        id: taskId,
        name: params.name,
        description: params.description,
        task_type: taskType,
        routine: params.routine
          ? {
              schedule: params.routine.schedule,
              initial_prompt: params.routine.initial_prompt,
              enabled: params.routine.enabled ?? true,
              last_run_at: null,
              next_run_at: '',
              last_status: null,
              last_error: null,
            }
          : undefined,
        completed: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      })
      return taskId
    }
  }

  // Manually fire a routine. Returns the backend's
  // `{ session_id }` on success, or `undefined` on failure (the
  // caller's responsibility to navigate / show an error).
  //
  // We deliberately do NOT navigate here — that's a UI concern
  // owned by Sidebar.vue. The store action is pure: it calls
  // the API and returns the result. This matches the `addTask`
  // pattern (store action returns a taskId; the component decides
  // what to do with it).
  async function runRoutine(
    workspaceId: string,
    itemId: string,
    taskId: string,
  ): Promise<{ session_id: string } | undefined> {
    try {
      return await api.runRoutine(workspaceId, itemId, taskId)
    } catch (err) {
      console.error('Failed to run routine:', err)
      return undefined
    }
  }

  // PATCH-equivalent for routine tasks. The backend's
  // updateTaskSimple accepts name + routine fields, so this is
  // a thin wrapper that calls the API and updates the local
  // task's name (optimistic) on success. Schedule + initial_prompt
  // + enabled live on the routine row; their updates surface via
  // the routines table's next refresh (or the SSE event the
  // backend emits on update — see Chunk 4 for the broadcast).
  async function updateRoutine(
    workspaceId: string,
    itemId: string,
    taskId: string,
    fields: {
      name?: string
      description?: string
      schedule?: string
      initial_prompt?: string
      enabled?: boolean
    },
  ): Promise<{ success: boolean }> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return { success: false }
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return { success: false }
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return { success: false }

    const previousName = task.name
    if (fields.name !== undefined && fields.name.trim() !== task.name) {
      task.name = fields.name.trim()
    }

    try {
      return await api.updateTaskSimple(taskId, fields)
    } catch (err) {
      console.error('Failed to update routine:', err)
      // Rollback the optimistic name change on error.
      task.name = previousName
      return { success: false }
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

  // Load the next page of tasks for a workspace item. No-op if there
  // are no more pages, a load is already in progress for this item, or
  // the item / workspace can't be found. Mirrors the `loadMoreChats`
  // pattern in ChatsList.vue:121-183. Click-to-load only: this is the
  // ONLY way the second-or-later pages get fetched (no auto-load).
  async function loadMoreTasks(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return
    if (item.isLoadingMoreTasks) return
    if (!item.hasMoreTasks) return
    if (!item.tasksNextCursor) return

    item.isLoadingMoreTasks = true
    try {
      const { tasks, has_more, next_cursor } = await api.getTasks(
        workspaceId,
        itemId,
        20, // PAGE_SIZE — keep in sync with the default in api/index.ts
        item.tasksNextCursor,
      )
      // Append the new page to the existing list. We push (not unshift)
      // because tasks are ordered newest-first, so older tasks go at
      // the end of the list.
      if (!item.tasks) item.tasks = []
      item.tasks.push(...tasks)
      item.hasMoreTasks = has_more
      item.tasksNextCursor = next_cursor
    } catch (err) {
      console.error(`Failed to load more tasks for item ${itemId}:`, err)
      // Leave hasMoreTasks/cursor as-is so the user can retry by
      // clicking the button again. Do not surface a toast — keep the
      // failure mode quiet (same pattern as addTask's catch block).
    } finally {
      item.isLoadingMoreTasks = false
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

  /**
   * Reorder the workspaces array to match `orderedIds` and persist the
   * new order via `POST /api/workspaces/reorder`. Optimistic: the
   * local array is reordered immediately so the UI snaps to the new
   * position on drop. On API failure, the snapshot is restored and
   * the error is logged (no toast/banner — matches the project's
   * silent-failure pattern in addTask/deleteTask/loadMoreTasks).
   *
   * No-op when `orderedIds` is empty or matches the current order
   * (same set of IDs in the same positions). Length mismatch is
   * rejected (the client is out of sync).
   *
   * Plan: docs/plans/2026-06-12-workspace-drag-and-drop.md
   */
  async function reorderWorkspaces(orderedIds: string[]) {
    const current = workspaces.value
    if (orderedIds.length === 0) return

    // Defensive: the client must send a complete ordering. A partial
    // list (e.g. drag-reordering 2 of 5 workspaces) would lose the
    // other 3. Refuse early.
    if (orderedIds.length !== current.length) {
      console.error(
        `[workspacesStore.reorderWorkspaces] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
      )
      return
    }

    // No-op: same set of IDs in (potentially) different order. The
    // set-equality check is an O(n) walk — fine for the realistic
    // sidebar size.
    const currentIdSet = new Set(current.map((w) => w.id))
    const newIdSet = new Set(orderedIds)
    const isSameSet =
      currentIdSet.size === newIdSet.size && [...currentIdSet].every((id) => newIdSet.has(id))
    if (isSameSet && current.every((w, i) => w.id === orderedIds[i])) {
      return
    }

    // Snapshot for rollback. Vue's ref returns the inner array;
    // copying the slice gives us a moment-in-time view.
    const previousOrder = current.slice()

    // Optimistic local reorder: build a new array by looking up each
    // id in the current array. If an id is missing (defensive — the
    // length-mismatch check above should have caught this), fall
    // back to keeping the original row at its original position.
    const byId = new Map(current.map((w) => [w.id, w]))
    const reordered: Workspace[] = []
    for (const id of orderedIds) {
      const ws = byId.get(id)
      if (ws) reordered.push(ws)
    }
    // If any current rows were missed, append them at the end (should
    // not happen given the length check, but defensive).
    for (const ws of current) {
      if (!orderedIds.includes(ws.id)) reordered.push(ws)
    }
    workspaces.value = reordered

    // Persist to backend.
    try {
      await api.reorderWorkspaces(orderedIds)
    } catch (err) {
      console.error('[workspacesStore.reorderWorkspaces] API call failed, rolling back:', err)
      workspaces.value = previousOrder
    }
  }

  /**
   * Reorder the items of one workspace to match `orderedIds` and
   * persist the new order via
   * `POST /api/workspaces/:workspace_id/items/reorder`. Mirrors
   * `reorderWorkspaces` but scoped to a single workspace's items.
   *
   * Optimistic: the workspace's items array is reordered immediately
   * so the UI snaps to the new position on drop. On API failure, the
   * snapshot is restored and the error is logged.
   *
   * No-op when `orderedIds` is empty or matches the current order.
   * Length mismatch is rejected (the client is out of sync — drag
   * handlers send the full list, not a delta).
   *
   * Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
   */
  async function reorderWorkspaceItems(workspaceId: string, orderedIds: string[]) {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) {
      console.error(
        `[workspacesStore.reorderWorkspaceItems] workspace ${workspaceId} not found`,
      )
      return
    }
    const current = workspace.items
    if (orderedIds.length === 0) return
    if (orderedIds.length !== current.length) {
      console.error(
        `[workspacesStore.reorderWorkspaceItems] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
      )
      return
    }

    // No-op: same set of IDs in (potentially) different order. The
    // set-equality check is an O(n) walk — fine for the realistic
    // items-per-workspace count.
    const currentIdSet = new Set(current.map((i) => i.id))
    const newIdSet = new Set(orderedIds)
    const isSameSet =
      currentIdSet.size === newIdSet.size && [...currentIdSet].every((id) => newIdSet.has(id))
    if (isSameSet && current.every((i, idx) => i.id === orderedIds[idx])) {
      return
    }

    // Snapshot for rollback.
    const previousOrder = current.slice()

    // Optimistic local reorder. The workspace is a ref inside the
    // workspaces array; mutating `workspace.items` in place preserves
    // Vue reactivity (the workspace's items array is what the
    // sidebar's v-for is bound to).
    const byId = new Map(current.map((i) => [i.id, i]))
    const reordered: WorkspaceItem[] = []
    for (const id of orderedIds) {
      const item = byId.get(id)
      if (item) reordered.push(item)
    }
    // If any current rows were missed, append them at the end
    // (should not happen given the length check, but defensive).
    for (const item of current) {
      if (!orderedIds.includes(item.id)) reordered.push(item)
    }
    workspace.items = reordered

    // Persist to backend.
    try {
      await api.reorderWorkspaceItems(workspaceId, orderedIds)
    } catch (err) {
      console.error(
        '[workspacesStore.reorderWorkspaceItems] API call failed, rolling back:',
        err,
      )
      workspace.items = previousOrder
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

  // ─── Session events SSE subscription ──────────────────────────────────────
  //
  // The backend cascade for task rename (updateTaskName →
  // updateSessionName → onEventSendSessions → SSE session.updated)
  // emits a `session.updated` event on `/api/sessions/stream`.
  // The ChatsList listens for that to update its own navItems
  // (the top-of-sidebar chat list), but the workspace-item task
  // list lives in THIS store, so we also need to listen and update
  // the matching task's name. Without this, renaming a task from
  // anywhere (this store's renameTask action, or any future
  // external renamer) leaves the task row showing the old name
  // until manual reload.
  //
  // task.id is the session_id (see AppLayout.vue:651
  // `:chat-id="activeTask.id"`), so the lookup is by task.id ==
  // event.id. We iterate workspaces → items → tasks until we find
  // the match.
  //
  // Idempotent: calling subscribeToSessionEvents() twice is a
  // no-op. The SSE client lives for the lifetime of the app; no
  // cleanup is needed (Pinia stores live forever, the page
  // unloads on close).
  const sessionsSse = ref<api.SseClient | null>(null)

  function subscribeToSessionEvents() {
    if (sessionsSse.value) {
      // Already subscribed.
      return
    }
    console.log('[workspacesStore] Subscribing to /api/sessions/stream')
    sessionsSse.value = api.createSessionsSseConnection(
      (event) => {
        if (event.action === 'updated') {
          // Find the task (task.id == session_id) and update its
          // name. We also keep navigationStore.activeChatName in
          // sync if the renamed task is active — this is the same
          // pattern as renameTask (workspaces.ts:renameTask).
          for (const ws of workspaces.value) {
            for (const item of ws.items) {
              if (!item.tasks) continue
              const task = item.tasks.find((t) => t.id === event.id)
              if (task) {
                task.name = event.name || task.name
                if (activeTaskId.value === task.id) {
                  useNavigationStore().setActiveChatName(task.name)
                }
                return
              }
            }
          }
        } else if (event.action === 'deleted') {
          // Find and remove the task. If it was active, clear the
          // active state so the chat view doesn't render a stale
          // task id.
          for (const ws of workspaces.value) {
            for (const item of ws.items) {
              if (!item.tasks) continue
              const idx = item.tasks.findIndex((t) => t.id === event.id)
              if (idx !== -1) {
                item.tasks.splice(idx, 1)
                if (activeTaskId.value === event.id) {
                  activeTaskId.value = null
                }
                return
              }
            }
          }
        }
        // 'created' events are deliberately ignored here: tasks are
        // only ever created via POST /workspaces/:w/items/:i/tasks
        // (which the addTask action handles directly). A 'created'
        // SSE event for an unbound session is a no-op for the
        // workspace tree.
      },
      // onError is only invoked on TERMINAL failure (SseClient
      // state went to `failed`). Transient errors are retried
      // internally with exponential backoff — see
      // helpers/sseClient.ts.
      (error) => {
        console.error('[workspacesStore] Sessions SSE failed permanently:', error)
      },
      () => {
        console.log('[workspacesStore] Sessions SSE connected')
      },
    )
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
    reorderWorkspaces,
    reorderWorkspaceItems,
    updateWorkspaceItemPath,
    addTask,
    toggleTask,
    deleteTask,
    loadMoreTasks,
    renameTask,
    runRoutine,
    updateRoutine,
    initializeFromSystemFolder,
    subscribeToSessionEvents,
    fetchSystemFolder,
    fetchFolderContents,
  }
})

import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { useNavigationStore } from './navigation'
import { useSseBus } from '../helpers/sseBus'
import type { DesignElement } from '../api'

export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /**
   * Free-text description of the column's meaning. Empty string
   * when no description has been set. Mirrors the
   * `KanbanColumn` interface in `api/index.ts` so test fixtures
   * that import this type see the same shape. Optional for
   * backwards compat with legacy column literals in test files
   * (see nalar-frontend-task-literal-typing-rule).
   */
  description?: string | null
  position: number
  created_at: string
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // The on-disk cwd for kanban items. Optional (matches the API
  // interface in api/index.ts): legacy kanbans have no path (the
  // API returns `null` for unset rows), folder items never set it,
  // test fixtures may omit it. The KanbanView template treats null
  // AND undefined AND "" the same way via `v-if="!item.path"`.
  path?: string | null
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
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // `item_type === 'kanban'` items. Optional so legacy literals
  // (5+ test files construct WorkspaceItem without this field) keep
  // type-checking — see the nalar-frontend-task-literal-typing-rule
  // memory.
  kanban_columns?: KanbanColumn[]
  // NEW (Chunk 6 of design-mode-redesign plan). Populated for
  // `item_type === 'design'` items when the active page is open.
  // Optional so legacy literals (5+ test files construct WorkspaceItem
  // without this field) keep type-checking — see the
  // nalar-frontend-task-literal-typing-rule memory.
  design_elements?: DesignElement[]
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
  // 'memory' added in 2026-06-20 for the markdown-memory feature
  // (plan: docs/plans/2026-06-20-add-markdown-memory.md).
  task_type?: 'standard' | 'routine' | 'memory'
  // NEW: present iff task_type === 'routine'.
  routine?: RoutineMeta
  // NEW: present iff task_type === 'memory'. Captures the .md
  // file name (no extension in the path; just the basename like
  // 'project-notes.md') for the UI badge.
  memory_name?: string
  completed?: boolean
  createdAt?: Date
  updatedAt?: Date
  // NEW (pinned-tasks feature, plan:
  // docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md).
  // Both optional so legacy task literals (8+ test files construct
  // Task without these fields) keep type-checking — see the
  // nalar-frontend-task-literal-typing-rule memory.
  is_pinned?: boolean
  pinned_position?: number
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // tasks under `item_type === 'kanban'` parents. `kanban_column_id`
  // is `null` (not undefined) when the task is unassigned. Both
  // optional so legacy task literals keep type-checking.
  kanban_column_id?: string | null
  kanban_position?: number
}

// localStorage keys for state persistence
const STORAGE_KEY_WORKSPACE_EXPANDED = 'nalar-workspace-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_EXPANDED = 'nalar-workspace-item-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED = 'nalar-workspace-item-tasks-expanded'

import * as api from '../api'
// Aliases for design-mode API functions whose names collide with
// the store action wrappers below (Task 6.1 of design-mode-redesign
// plan). `getDesignPage` doesn't collide so it stays as a bare api
// lookup (no `api.getDesignPage(...)` in the action).
import {
  addDesignElement as addDesignElementApi,
  updateDesignElement as updateDesignElementApi,
  deleteDesignElement as deleteDesignElementApi,
  updateDesignElementGeometry as updateDesignElementGeometryApi,
} from '../api'

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

    // Install the bus-backed session-event listeners (idempotent —
    // safe to call on every init, including HMR re-mounts). The bus
    // is opened once by App.vue, so we don't own the SSE connection
    // here anymore (Chunk 6 of unify-frontend-sse).
    installSessionEventHandlers()

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
  // For a memory, pass `{ name, taskType: 'memory', memory: { name, content } }`.
  //
  // taskType defaults to 'standard' so a caller that omits it gets
  // the legacy behavior. For routines, `routine` must include
  // `schedule` + `initial_prompt`; `enabled` defaults to true on the
  // backend. For memories, `memory.name` is the .md filename (must
  // end in .md, validated server-side) and `memory.content` is the
  // initial body of the .md file.
  async function addTask(
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
  ): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return undefined

    if (!item.tasks) {
      item.tasks = []
    }

    const taskType: 'standard' | 'routine' | 'memory' = params.taskType ?? 'standard'

    try {
      const newTask = await api.createTask(workspaceId, itemId, {
        name: params.name,
        description: params.description,
        taskType,
        routine: params.routine,
        memory: params.memory,
      })
      item.tasks.unshift(newTask)
      return newTask.id
    } catch (err) {
      console.error('Failed to create task:', err)
      // Fallback to local creation if API fails. Match the
      // pre-existing fallback contract (returns a taskId, populates
      // the item's tasks list) and now also carry task_type +
      // routine + memory so the offline UI still branches correctly.
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
        memory_name: params.memory?.name,
        completed: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      })
      return taskId
    }
  }

  // ─── Kanban actions (Chunk 5 of workspace-item-kanban plan) ─────────────
  //
  // These five actions back the kanban board UI. The API wrappers
  // (api.createKanban, api.addKanbanColumn, etc.) were added in
  // Chunk 4; these store actions are thin wrappers that call the
  // API and mirror the response into the local store state.
  //
  // The plan (docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
  // Task 5.1) deliberately does NOT include offline fallbacks for
  // kanban actions — kanban is a multi-column feature where stale
  // local state would be worse than no state. A failed API call
  // leaves the local store untouched; the caller's UI is expected
  // to handle the rejection.

  // Private helper: locate a single workspace item by id. Returns
  // the live reference (Vue 3 reactivity is preserved) or undefined.
  function findItem(workspaceId: string, itemId: string): WorkspaceItem | undefined {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined
    return workspace.items.find((i) => i.id === itemId)
  }

  // Create a new kanban workspace item. The backend seeds three
  // default columns (todo / in progress / done) and returns them
  // alongside the item. We push the item into the workspace's
  // items array and pre-populate `kanban_columns` + `tasks` so
  // the board renders immediately. Returns the new item's id.
  // The optional `path` is persisted as `workspace_items.path` and
  // used as the cwd for every chat session created under this
  // kanban's tasks. Strongly recommended — without it, git/file
  // tools fail with "no such directory" because the chat session
  // has no cwd. The AddKanbanDialog requires the user to pick a
  // folder before the Add button enables.
  async function addKanbanItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const { item, columns } = await api.createKanban(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          kanban_columns: columns,
          tasks: [],
        })
        // Auto-expand the workspace to surface the new kanban and
        // persist the expansion (same UX as addWorkspaceItem).
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addKanbanItem] API call failed:', err)
      return undefined
    }
  }

  /**
   * Create a new design workspace item and select it.
   *
   * `path` is REQUIRED — design elements live as HTML files at
   * `<path>/.nalar/design/<page>/<element>.html`. The backend's
   * `POST /api/workspaces/:wid/items/design` rejects an empty
   * `path` with 400 (PathRequired), and the model's `addElement`
   * rejects `path IS NULL` with `ItemPathMissing` on first use.
   * So path is mandatory at both layers.
   *
   * After the API call, the new item is pushed into the local store
   * and `activeWorkspaceItemId` is set to it (so the DesignView
   * opens immediately). Returns the new item id or undefined on
   * failure.
   */
  async function addDesignItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const item = await api.createDesign(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        // Defensive merge: the backend now returns the full
        // CreateDesignResponse (id, workspace_id, item_type, name,
        // path, position) — but if it ever regresses to the bare
        // {id, success} shape, the sidebar would render "Untitled
        // project" because `item.name` would be undefined. Fall
        // back to the form's name/path (we just sent them — they're
        // the source of truth on the client side) so the UI is
        // always correct, regardless of what the backend returns.
        // The kanban flow has the same pattern via `addKanbanItem`
        // (line ~595) — mirrors the same defense-in-depth.
        ws.items.push({
          ...item,
          // WorkspaceItem interface fields — fall back to the form
          // values when the response is missing them.
          // `workspace_id` is intentionally NOT set here — it lives
          // on the parent Workspace (we found `ws` by `ws.id ===
          // workspaceId`), and the WorkspaceItem interface doesn't
          // have a workspace_id field (the parent-workspace lookup
          // is the source of truth).
          name: item.name ?? name,
          item_type: item.item_type ?? 'design',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        // Auto-expand the workspace + select the new item so the
        // user lands in the new DesignView (mirror addKanbanItem).
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addDesignItem] API call failed:', err)
      return undefined
    }
  }

  // Backfill (or change) the `path` of a kanban workspace item. Used
  // by the KanbanView "Set project root" banner that surfaces when a
  // kanban was created before the path field existed (the user's
  // existing kanbans all have `path = NULL`). Sets the new path on
  // the local store so the UI updates immediately; the backend
  // persists the change.
  async function updateKanbanItemPath(
    workspaceId: string,
    itemId: string,
    path: string,
  ): Promise<void> {
    const ws = workspaces.value.find((w) => w.id === workspaceId)
    const item = ws?.items.find((i) => i.id === itemId)
    try {
      await api.updateWorkspaceItem(workspaceId, itemId, { path })
      if (item) item.path = path
    } catch (err) {
      console.error('[workspacesStore.updateKanbanItemPath] API call failed:', err)
      throw err
    }
  }

  // Update kanban item name from the Settings dialog or KanbanView
  // inline-rename pencil. Optimistic: mutate `item.name` BEFORE the
  // API call resolves so the UI updates immediately; roll back on
  // error. Backend contract: PUT /items/:id accepts `{name}` and
  // either writes it (200) or rejects empty (400) — the API throws
  // on non-2xx so we catch + restore + rethrow.
  async function updateKanbanItemName(
    workspaceId: string,
    itemId: string,
    newName: string,
  ): Promise<void> {
    const ws = workspaces.value.find((w) => w.id === workspaceId)
    const item = ws?.items.find((i) => i.id === itemId)
    const previousName = item?.name
    // Optimistic update.
    if (item) item.name = newName
    try {
      await api.updateWorkspaceItem(workspaceId, itemId, { name: newName })
    } catch (err) {
      // Restore the previous name on failure so the UI doesn't lie.
      if (item && previousName !== undefined) item.name = previousName
      console.error('[workspacesStore.updateKanbanItemName] API call failed:', err)
      throw err
    }
  }

  // Fetch the columns for a kanban from the backend and populate
  // `item.kanban_columns`. Called when a kanban item is expanded
  // (mirrors the folder-item `fetchFolderContents` pattern). The
  // workspaces/items endpoint intentionally does NOT embed columns
  // — kanbans can have arbitrarily many columns and we want a
  // lazy load. The seeded 3 default columns (todo / in progress /
  // done) live in the DB; without this call, the kanban board
  // renders empty after every page reload.
  async function fetchKanbanColumns(
    workspaceId: string,
    itemId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    try {
      const { columns } = await api.listKanbanColumns(workspaceId, itemId)
      // Sort defensively (the backend already orders by position, but
      // a stale local snapshot from before a backend reorder would
      // otherwise keep the old ordering).
      item.kanban_columns = [...columns].sort(
        (a, b) => a.position - b.position,
      )
    } catch (err) {
      console.error('[workspacesStore.fetchKanbanColumns] API call failed:', err)
      // Leave whatever columns we have (or undefined) so the UI can
      // show an empty-state rather than a hard error.
    }
  }

  // Refresh an item's tasks from the backend and replace the local
  // `item.tasks` array. Used by the kanbanSse store to react to
  // `kanban_task.*` SSE events (moved / assigned / unassigned) so the
  // KanbanView.vue card visibly moves to the new column without a
  // manual reload.
  //
  // Mirrors `fetchKanbanColumns` in shape and error semantics:
  //   - Silently no-ops if the item isn't in the local store (defensive
  //     against stale SSE events after a workspace switch).
  //   - Silently preserves the existing tasks array on API failure
  //     (matches `fetchKanbanColumns`'s best-effort semantics — the
  //     next SSE event will trigger another fetch).
  //   - Sets `hasMoreTasks` + `tasksNextCursor` on the item for
  //     pagination-state consistency (matches `loadMoreTasks`'s
  //     pattern at workspaces.ts:1051-1083).
  //
  // Does NOT call `api.getTasks` if the item is missing — short-circuit
  // before the HTTP request to avoid a needless 404 roundtrip.
  async function fetchKanbanTasks(
    workspaceId: string,
    itemId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    try {
      const { tasks, has_more, next_cursor } = await api.getTasks(workspaceId, itemId)
      item.tasks = tasks ?? []
      item.hasMoreTasks = has_more
      item.tasksNextCursor = next_cursor
    } catch (err) {
      console.error('[workspacesStore.fetchKanbanTasks] API call failed:', err)
      // Leave the existing tasks array untouched so the UI doesn't
      // flash to empty on a transient network blip. The next SSE
      // event will trigger another fetch.
    }
  }

  // Add a column to a kanban and append it to the local item's
  // `kanban_columns` array, sorted by position. The backend
  // returns the column with its server-assigned id and position.
  // `description` defaults to '' (the backend's "no description"
  // sentinel) so callers like AppLayout that only pass `name` keep
  // working unchanged.
  async function addKanbanColumn(
    workspaceId: string,
    itemId: string,
    name: string,
    description: string = '',
  ): Promise<void> {
    const col = await api.addKanbanColumn(workspaceId, itemId, name, description)
    const item = findItem(workspaceId, itemId)
    if (item) {
      item.kanban_columns = [...(item.kanban_columns ?? []), col].sort(
        (a, b) => a.position - b.position,
      )
    }
  }

  // Patch a kanban column's name, description, and/or position. The
  // backend re-numbers sibling positions when `position` changes;
  // it returns the FULL updated board on every successful PATCH
  // (same `{columns, count}` envelope as `listKanbanColumns`) so the
  // frontend can mirror sibling renumbering in one round-trip.
  //
  // We replace the local `kanban_columns` array with the backend's
  // returned list (defensively re-sorted by position) — this keeps
  // sibling columns in sync after a reorder PATCH without a follow-up
  // GET, and fixes the "kanban-settings shows 'No description' after
  // save" bug where the previous version tried to assign the list
  // response to a single column slot and lost the column's own
  // fields (`description`, `name`, etc).
  async function updateKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
    patch: { name?: string; description?: string; position?: number },
  ): Promise<void> {
    const result = await api.updateKanbanColumn(workspaceId, itemId, columnId, patch)
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mirror the backend's full board — replaces the previous
    // `item.kanban_columns[i] = result` bug, which corrupted the
    // single-column slot with the `{columns, count}` envelope and
    // made every UI field on the saved column read as undefined.
    item.kanban_columns = [...result.columns].sort(
      (a, b) => a.position - b.position,
    )
  }

  // Copy the column spec from `sourceItemId` to `targetItemId`.
  // Destructive for the target in 'replace' mode (existing columns
  // are deleted via the backend's `deleteColumn` path which
  // unassigns tasks). 'append' mode adds the source's columns
  // after the target's existing MAX(position).
  //
  // Mirrors the `updateKanbanColumn` pattern: the backend returns
  // the full updated board on success so the local store gets the
  // fresh column order without a follow-up GET.
  async function copyKanbanSpecFrom(
    workspaceId: string,
    targetItemId: string,
    sourceItemId: string,
    mode: 'replace' | 'append' = 'replace',
  ): Promise<void> {
    const result = await api.copyKanbanSpec(workspaceId, targetItemId, sourceItemId, mode)
    const item = findItem(workspaceId, targetItemId)
    if (!item) return
    item.kanban_columns = [...result.columns].sort(
      (a, b) => a.position - b.position,
    )
  }

  // Reorder a kanban column via drag-and-drop. The DnD handler in
  // <KanbanColumn> only knows the dragged column's id and the target
  // column's id (the column the user dropped onto); this action
  // resolves the target's current position and calls the API, then
  // re-fetches the full column list because the backend's PATCH
  // response only includes the moved column — sibling positions
  // changed too (dense renumber), so we need the backend's full
  // post-renumber ordering to mirror into the local store.
  //
  // No-op (silently) if the workspace / item / target column can't
  // be found locally. This matches the pattern in `updateKanbanColumn`
  // (the action assumes the column exists; the UI should only emit
  // reorder events with valid ids).
  async function reorderKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
    targetColumnId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item?.kanban_columns) return
    const target = item.kanban_columns.find((c) => c.id === targetColumnId)
    if (!target) return
    // PATCH the moved column to the target's position. The backend's
    // reorderColumn shifts the siblings (dense renumber) and returns
    // the moved column's NEW position; we ignore the return value
    // because we'll re-fetch the whole list next.
    await api.updateKanbanColumn(workspaceId, itemId, columnId, {
      position: target.position,
    })
    // Re-fetch so local state matches the backend's renumbered
    // sibling positions.
    await fetchKanbanColumns(workspaceId, itemId)
  }

  // Delete a kanban column. The backend unassigns tasks in the
  // column (sets kanban_column_id to NULL) — we mirror that by
  // clearing `kanban_column_id` on any matching tasks in the
  // local store so the "Unassigned" view is consistent.
  async function deleteKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<void> {
    await api.deleteKanbanColumn(workspaceId, itemId, columnId)
    const item = findItem(workspaceId, itemId)
    if (item) {
      item.kanban_columns = (item.kanban_columns ?? []).filter((c) => c.id !== columnId)
      // Mirror the backend's NULL-unassign for tasks in the column.
      if (item.tasks) {
        for (const t of item.tasks) {
          if (t.kanban_column_id === columnId) t.kanban_column_id = null
        }
      }
    }
  }

  // Move a task to a different column and/or position. The
  // backend does the move + sibling re-numbering in a single
  // transaction; we update the local task's `kanban_column_id`
  // + `kanban_position` so the UI snaps to the new position.
  async function moveTaskToColumn(
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId: string,
    position: number,
  ): Promise<void> {
    await api.moveTask(workspaceId, itemId, taskId, columnId, position)
    const item = findItem(workspaceId, itemId)
    if (item && item.tasks) {
      const task = item.tasks.find((t) => t.id === taskId)
      if (task) {
        task.kanban_column_id = columnId
        task.kanban_position = position
      }
    }
  }

  // ─── Design mode actions (Chunk 6 of design-mode-redesign plan) ──────
  //
  // These 5 actions back the design canvas / layers panel / properties
  // panel UI of the v6 Figma-lite design mode. The API wrappers
  // (api.getDesignPage, addDesignElement, etc.) were added in Chunk 5
  // (src/apps/desktop/src/api/index.ts lines 1295-1503); these store
  // actions are thin wrappers that call the API and mirror the response
  // into the local store state — mirroring the kanban-actions section's
  // pattern above (Chunk 5 of workspace-item-kanban plan).
  //
  // The design-mode SSE routing key (`design_element`) is GLOBAL — every
  // connected client receives every event. The `designSse` store
  // (src/apps/desktop/src/stores/designSse.ts) handles incoming events
  // by re-fetching via `fetchDesignElements` below. Page tracking is
  // wired in Chunk 7 (AppLayout sets the active page id); until then,
  // `fetchInitialDesign` in designSse.ts is a no-op.

  // Fetch a single design page (with all its elements) and populate
  // `item.design_elements`. Mirrors `fetchKanbanColumns`'s shape and
  // error semantics: silently no-ops if the item isn't in the local
  // store (defensive against stale SSE events after a workspace
  // switch) and silently preserves the existing elements array on
  // API failure (best-effort — the next SSE event will trigger
  // another fetch).
  async function fetchDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    try {
      const { elements } = await api.getDesignPage(workspaceId, itemId, pageId)
      item.design_elements = elements
    } catch (err) {
      console.error('[workspacesStore.fetchDesignElements] API call failed:', err)
      // Leave the existing elements array untouched so the UI
      // doesn't flash to empty on a transient network blip. The
      // next SSE event will trigger another fetch.
    }
  }

  // Add an element to a design page and append it to the local
  // item's `design_elements` array. The backend returns the full
  // element with server-assigned id / position / timestamps. We
  // push (not unshift) to match the backend's ordering (oldest
  // first by position). Used by the AddDesignElementDialog in
  // Chunk 7 + by the LLM tool-driven add_element handler.
  async function addDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: {
      name: string
      type: DesignElement['type']
      html: string
      [k: string]: any
    },
  ): Promise<DesignElement> {
    const newElem = await addDesignElementApi(workspaceId, itemId, pageId, body)
    const item = findItem(workspaceId, itemId)
    if (item) {
      if (!item.design_elements) item.design_elements = []
      item.design_elements.push(newElem)
    }
    return newElem
  }

  // Patch an element's fields (full update — backend applies a
  // sparse merge). Replaces the local copy in place so the canvas
  // re-renders the patched element immediately. Used by the
  // PropertiesPanel (form input changes) and the LLM tool-driven
  // update_element handler.
  async function updateDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    patch: Partial<DesignElement>,
  ): Promise<DesignElement> {
    const updated = await updateDesignElementApi(
      workspaceId,
      itemId,
      pageId,
      elementId,
      patch,
    )
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = updated
    }
    return updated
  }

  // Geometry-only update path (drag/resize fires 60+/sec). The
  // backend's design_elements_geometry_update PATCH is the
  // dedicated endpoint — no full element GET is needed. The
  // response is the same full DesignElement (so the frontend
  // can sync its local Pinia store).
  //
  // We intentionally DON'T mirror the returned element into the
  // local `design_elements` array — geometry patches arrive at
  // 60+/sec, and pushing every response through reactive
  // watchers would flood the canvas. The drag-end handler in
  // DesignView.vue (Chunk 7) fires a follow-up
  // `fetchDesignElements` to reconcile local state once the user
  // releases the mouse.
  async function updateDesignElementGeometry(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    geometry: {
      x?: number
      y?: number
      width?: number
      height?: number
      rotation?: number
    },
  ): Promise<DesignElement> {
    return await updateDesignElementGeometryApi(
      workspaceId,
      itemId,
      pageId,
      elementId,
      geometry,
    )
  }

  // Delete an element. Idempotent on the backend (returns
  // `{success: true}` whether the row existed or not). Filters
  // the local `design_elements` array to remove the row.
  async function deleteDesignElement(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
  ): Promise<void> {
    await deleteDesignElementApi(workspaceId, itemId, pageId, elementId)
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      item.design_elements = item.design_elements.filter(
        (e) => e.id !== elementId,
      )
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

  /**
   * Pin or unpin a task and persist the change via
   * `POST /api/.../tasks/:task_id/pin`. Optimistic: the local
   * task's `is_pinned` flag is flipped immediately and the
   * `pinned_position` is bumped to MAX+1 (matching the backend's
   * behavior). On API failure, the previous pin state and
   * position are restored and the error is logged.
   *
   * When the user pins a task, the row is moved to the bottom
   * of the pinned region. The list lister's
   * `ORDER BY is_pinned DESC, pinned_position DESC, ...` then
   * surfaces it correctly on the next render.
   */
  async function pinTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    isPinned: boolean,
  ): Promise<{ success: boolean; pinned_position: number } | undefined> {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) return undefined
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return undefined
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return undefined

    // Snapshot for rollback.
    const previousIsPinned = task.is_pinned ?? false
    const previousPinnedPosition = task.pinned_position ?? 0

    // Compute the optimistic pinned_position. When pinning,
    // bump to MAX+1 across the item's currently-pinned tasks
    // (excluding the row being pinned — its current value
    // would otherwise be the new MAX). When unpinning, reset
    // to 0 (the value is irrelevant for unpinned rows).
    let optimisticPosition = previousPinnedPosition
    if (isPinned) {
      const maxPinned = item.tasks.reduce<number>((acc, t) => {
        if (t.id === taskId) return acc
        const p = t.pinned_position ?? 0
        return p > acc ? p : acc
      }, -1)
      optimisticPosition = maxPinned + 1
    }

    task.is_pinned = isPinned
    task.pinned_position = optimisticPosition

    try {
      const result = await api.pinTask(workspaceId, itemId, taskId, isPinned)
      // The backend may assign a different pinned_position if a
      // concurrent pin raced with ours. Echo the backend's value.
      if (result.pinned_position !== undefined) {
        task.pinned_position = result.pinned_position
      }
      return { success: true, pinned_position: result.pinned_position }
    } catch (err) {
      console.error('[workspacesStore.pinTask] API call failed, rolling back:', err)
      task.is_pinned = previousIsPinned
      task.pinned_position = previousPinnedPosition
      return undefined
    }
  }

  /**
   * Reorder the pinned subset of a single workspace item and
   * persist the new order via
   * `POST /api/.../tasks/reorder_pinned`. Optimistic: the
   * item's pinned tasks are reordered in the local array
   * immediately so the UI snaps on drop. On API failure, the
   * snapshot is restored and the error is logged.
   *
   * The caller (WorkspaceItem.vue's drag handler) sends the
   * FULL ordered list of pinned task IDs, not a delta.
   * Unpinned tasks are not affected (they keep their
   * position in the unpinned region below).
   */
  async function reorderPinnedTasks(
    workspaceId: string,
    itemId: string,
    orderedIds: string[],
  ) {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return

    const currentPinned = item.tasks.filter((t) => t.is_pinned)
    if (currentPinned.length === 0) return

    if (orderedIds.length !== currentPinned.length) {
      console.error(
        `[workspacesStore.reorderPinnedTasks] orderedIds length ${orderedIds.length} != current pinned ${currentPinned.length}; refusing reorder`,
      )
      return
    }

    // Snapshot for rollback.
    const previousOrder = item.tasks.slice()

    // Optimistic local reorder: rebuild the tasks array as
    // [ordered pinned rows in the new order, ...unpinned
    // rows]. Unpinned rows keep their existing relative
    // order (the unpinned-region ORDER BY is unchanged by the
    // reorder).
    const pinnedById = new Map(currentPinned.map((t) => [t.id, t]))
    const reorderedPinned: Task[] = []
    for (const id of orderedIds) {
      const t = pinnedById.get(id)
      if (t) reorderedPinned.push(t)
    }
    // Defensive: any pinned rows missed in the payload are
    // appended at the end (should not happen given the length
    // check).
    for (const t of currentPinned) {
      if (!orderedIds.includes(t.id)) reorderedPinned.push(t)
    }
    const unpinned = item.tasks.filter((t) => !t.is_pinned)
    item.tasks = [...reorderedPinned, ...unpinned]

    try {
      await api.reorderPinnedTasks(workspaceId, itemId, orderedIds)
    } catch (err) {
      console.error(
        '[workspacesStore.reorderPinnedTasks] API call failed, rolling back:',
        err,
      )
      item.tasks = previousOrder
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

  // ─── Session events via sseBus ─────────────────────────────────────────────
  //
  // The backend cascade for task rename (updateTaskName →
  // updateSessionName → onEventSendSessions → SSE session.updated)
  // emits a `session.updated` event on `/api/sessions/stream`. The
  // bus (opened once by App.vue at app start, see `helpers/sseBus.ts`)
  // is the SINGLE subscription point for session events. The ChatsList
  // listens for that to update its own navItems (the top-of-sidebar
  // chat list), but the workspace-item task list lives in THIS store,
  // so we also need to listen and update the matching task's name.
  // Without this, renaming a task from anywhere (this store's
  // renameTask action, or any future external renamer) leaves the
  // task row showing the old name until manual reload.
  //
  // task.id is the session_id (see AppLayout.vue:651
  // `:chat-id="activeTask.id"`), so the lookup is by task.id ==
  // event.id. We iterate workspaces → items → tasks until we find
  // the match.
  //
  // Idempotent: the install flag guards against HMR re-entry (the
  // bus's listener Set accepts duplicates, but we don't want double
  // mutations per event). The bus lives for the lifetime of the app;
  // no cleanup is needed (Pinia stores live forever, the page
  // unloads on close).
  let sessionHandlersInstalled = false

  /**
   * Subscribe to session events. The callback fires once per
   * session event (after the internal workspacesStore handler runs).
   * Returns an unsubscribe function.
   *
   * Use this when you have a SEPARATE data structure that needs to
   * stay in sync with session renames/deletes/creates — for
   * example, ChatsList.vue's `navItems` mirror.
   */
  function onSessionEvent(cb: (event: api.SessionEvent) => void): () => void {
    const bus = useSseBus()
    return bus.on('session', (event) => {
      try {
        cb(event)
      } catch (e) {
        // Swallow subscriber errors so a buggy callback can't take
        // down sibling subscribers (the bus's own dispatch already
        // wraps the listener call in try/catch — this is defense
        // in depth: it also covers the case where a future bus
        // implementation drops that wrapping).
        console.error('[workspacesStore] session event subscriber threw:', e)
      }
    })
  }

  function installSessionEventHandlers() {
    if (sessionHandlersInstalled) {
      // Already installed — don't double-register on HMR.
      return
    }
    sessionHandlersInstalled = true

    const bus = useSseBus()
    bus.on('session', (event) => {
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
    })
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
    pinTask,
    reorderPinnedTasks,
    addKanbanItem,
    // NEW (design-mode feature): creates a design-mode workspace item.
    // POSTs to /api/workspaces/:wsId/items/design and pushes the
    // returned item (with empty tasks + design_elements) into the
    // local store, auto-expanding the workspace + selecting the new
    // item so the user lands in the new DesignView. Plan:
    // docs/superpowers/plans/2026-06-13-design-mode.md.
    addDesignItem,
    addKanbanColumn,
    updateKanbanColumn,
    copyKanbanSpecFrom,
    deleteKanbanColumn,
    reorderKanbanColumn,
    moveTaskToColumn,
    updateKanbanItemPath,
    updateKanbanItemName,
    fetchKanbanColumns,
    fetchKanbanTasks,
    // Design mode actions (Chunk 6 of design-mode-redesign plan)
    fetchDesignElements,
    addDesignElement,
    updateDesignElement,
    updateDesignElementGeometry,
    deleteDesignElement,
    initializeFromSystemFolder,
    onSessionEvent,
    fetchSystemFolder,
    fetchFolderContents,
  }
})

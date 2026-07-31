import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { useNavigationStore } from './navigation'
import { useSseBus } from '../helpers/sseBus'
import type { DesignElement, DesignPage } from '../api'

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
  // NEW (Chunk 5 of auto-retry-until-stop plan). Mirrors the
  // sessions.is_auto_retry_until_stop column (Migration 063). For
  // routine tasks, task.id == session.id (project convention) so
  // the flag can be persisted via PUT /api/llm/session/<id>.
  // For non-routine tasks the field is shown as a UI affordance
  // but won't affect runtime behavior. Optional + string ('0'/'1')
  // to match the session API shape and to keep legacy task
  // literals type-checking (see nalar-frontend-task-literal-typing-rule).
  is_auto_retry_until_stop?: string
  // NEW (kanban-task-notification-icon feature, plan
  // docs/plans/2026-07-26-kanban-task-notification-icon.md).
  // Backend-computed boolean from Migration 065 +
  // sessions.last_finish_reason. When true AND not currently
  // running, the card renders the orange "AI finished — awaiting
  // your review" dot. When false AND last_finish_reason==='stop',
  // the card renders the green "reviewed" checkmark. When false
  // AND last_finish_reason==='' (or undefined — never ran), the
  // card renders nothing for this icon. Optional so legacy task
  // literals in tests keep type-checking.
  needs_human_review?: boolean
  // NEW: denormalized cache of the session's last_finish_reason
  // (joined from sessions.last_finish_reason on the kanban SELECT).
  // Empty string when no session row exists. The frontend uses
  // this ONLY to distinguish "AI ran and finished" from "AI never
  // ran" — when needs_human_review is false and this is 'stop',
  // we paint the green checkmark. Optional for backwards compat.
  last_finish_reason?: string
  // NEW (kanban task tags feature, plan:
  // docs/superpowers/plans/2026-07-28-kanban-task-tags.md).
  // Array of free-form tag strings (Migration 067). Empty array
  // = no tags. Optional for backwards compat with legacy task
  // literals in tests. Decoded from the wire JSON-encode string
  // (task.tags on the wire is a string; this is a string[]).
  tags?: string[]
}

// localStorage keys for state persistence
const STORAGE_KEY_WORKSPACE_EXPANDED = 'nalar-workspace-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_EXPANDED = 'nalar-workspace-item-expanded'
const STORAGE_KEY_WORKSPACE_ITEM_TASKS_EXPANDED = 'nalar-workspace-item-tasks-expanded'

// Kanban task tags normalization (Migration 067 — plan
// docs/superpowers/plans/2026-07-28-kanban-task-tags.md).
// The backend stores tags as a JSON-encoded array string ('' when
// no tags). On the wire the field is `tags: string`. The frontend
// convention (per the `Task` interface) is `tags?: string[]`. This
// helper decodes the wire shape to the in-memory shape — applied
// at every `api.getTasks` fetch site so the rest of the codebase
// can treat tags as a plain array.
function normalizeTaskTags(task: Task): Task {
  if (task.tags === undefined) {
    return task
  }
  // Coerce anything (string, already-array, missing) to a string[].
  // Defensive: legacy rows from before Migration 067 might have
  // undefined OR an empty string. The new shape is a JSON-encoded
  // array string; parse errors fall back to [] rather than
  // throwing (the kanban card shouldn't crash on malformed JSON).
  if (typeof task.tags === 'string') {
    try {
      const parsed = JSON.parse(task.tags) as unknown
      task.tags = Array.isArray(parsed) ? (parsed as string[]) : []
    } catch {
      task.tags = []
    }
  } else if (!Array.isArray(task.tags)) {
    task.tags = []
  }
  return task
}

// ─── SSE local-mutation dedupe (Chunk 3 of design-drag-debounce-batch)
// ─────────────────────────────────────────────────────────────────
//
// Every locally-issued geometry PATCH (single-element or batch)
// registers the affected element_id(s) here with an expiry timestamp.
// The SSE handler in `stores/designSse.ts` reads this Map on every
// incoming `design_element_updated` / `design_elements_geometry_batch_updated`
// event and SKIPS the `fetchDesignElements` GET when the event is for
// one of these ids (i.e. the change came from this client).
//
// Why a module-level Map (NOT a Pinia ref): the SSE handler reads it
// synchronously on every event. Reactivity would add overhead for no
// benefit — the Map is not user-visible state.
//
// Why 1500 ms TTL: long enough to cover the round-trip + SSE round-trip
// + Vue reactivity on slow networks; short enough that concurrent
// edits from another client (chat-side, second tab) still propagate
// within ~1.5 s. Figma uses ~1000 ms; 1500 ms is the safer default
// for slower networks.
//
// Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
//   (Chunk 3, Task 3.1)
export const RECENT_MUTATION_TTL_MS = 1500

const recentLocalMutations = new Map<string, number>()

export function registerRecentLocalMutations(
  ids: string[],
  expiryMs: number,
): void {
  const now = Date.now()
  // Lazy GC: drop expired entries on every register call to keep
  // the Map small. O(N) per PATCH is acceptable for v1 (worst case
  // bounded by the mutation rate; typically < 50 entries).
  for (const [id, exp] of recentLocalMutations) {
    if (exp < now) recentLocalMutations.delete(id)
  }
  for (const id of ids) {
    recentLocalMutations.set(id, expiryMs)
  }
}

/**
 * True iff `elementId` was mutated by this client within the last
 * `RECENT_MUTATION_TTL_MS` milliseconds. Read by the SSE handler to
 * decide whether to skip the GET fan-out for an incoming event.
 *
 * Exported for `stores/designSse.ts`. Side effect: expired entries are
 * lazily GC'd on read.
 */
export function isRecentLocalMutation(elementId: string): boolean {
  const exp = recentLocalMutations.get(elementId)
  if (exp === undefined) return false
  if (exp < Date.now()) {
    recentLocalMutations.delete(elementId)
    return false
  }
  return true
}

/**
 * Test-only helper to clear the dedupe Map between tests. NOT exposed
 * in the production API surface — exported via the store's returned
 * object only for unit tests.
 */
export function _clearRecentLocalMutationsForTests(): void {
  recentLocalMutations.clear()
}

import * as api from '../api'
// Aliases for design-mode API functions whose names collide with
// the store action wrappers below (Task 6.1 of design-mode-redesign
// plan). `getDesignPage` doesn't collide so it stays as a bare api
// lookup (no `api.getDesignPage(...)` in the action).
import {
  addDesignElement as addDesignElementApi,
  updateDesignElement as updateDesignElementApi,
  updateDesignElementHtml as updateDesignElementHtmlApi,
  deleteDesignElement as deleteDesignElementApi,
  deleteDesignPage as deleteDesignPageApi,
  updateDesignElementGeometry as updateDesignElementGeometryApi,
  updateDesignElementsGeometryBatch as updateDesignElementsGeometryBatchApi,
  updateDesignPage as updateDesignPageApi,
  groupDesignElements as groupDesignElementsApi,
  reorderDesignElements as reorderDesignElementsApi,
  ungroupDesignElements as ungroupDesignElementsApi,
  reparentDesignElementsBatch as reparentDesignElementsBatchApi,
  moveDesignElementsBatch as moveDesignElementsBatchApi,
  type GeometryBatchUpdate,
  type MoveBatchItem,
  type GroupDesignElementsRequest,
  type ReparentDesignElementsBatchRequest,
  type ReorderMode,
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

  // NEW (Chunk 1 of design-element-drag-and-drop plan). The currently
  // active design page id, set by DesignView on mount / tab switch and
  // cleared on unmount. Read by AppLayout's design handlers
  // (handleDesignUpdateElement / handleDesignDeleteElement) so they can
  // route PATCH/PUT/DELETE to the correct page. Also read by
  // handleDesignOpenChat to scope the chat task per-page (each page
  // gets a disjoint "Design Chat: <pageName>" task — switching pages
  // does NOT swap the active chat, which is intentional). Empty
  // string means "no active design page" (DesignView is not mounted,
  // or no page is selected yet). Using empty string (not null) keeps
  // the type as string and makes the "no active page" check a single
  // `!pageId`.
  const activeDesignPageId = ref<string>('')
  function setActiveDesignPage(pageId: string): void {
    activeDesignPageId.value = pageId
  }

  // NEW (kanban task search feature, plan:
  // docs/superpowers/plans/2026-07-30-kanban-task-search.md Chunk 4).
  // Map<itemId, q> — the active search query per board. Read by
  // `loadMoreTasks` (to forward q on "Load more" clicks) and by the
  // SSE handler that re-fetches tasks on `kanban_task.*` events (so a
  // remote move/edit during a search keeps the user's narrowed view).
  // Written by `fetchKanbanTasks(ws, item, limit, cursor, q)`:
  // q === undefined / '' → DELETE; otherwise → SET. Plain Map (not
  // reactive ref) — the SSE handler reads synchronously after each
  // mutation; no UI depends on this state for rendering (the input
  // v-model is component-local in KanbanView.vue).
  const activeSearchQueries: Map<string, string> = new Map()

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
                  // Migration 067 — normalize tags from wire string to
                  // in-memory string[]. All fetch sites do this; the
                  // card UI and dialog rely on tags being a string[].
                  tasksByItem.set(item.id, tasks.map(normalizeTaskTags))
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
      // Auto-retry-until-stop (Migration 063, Option A fix): when
      // `'1'`, the backend ALSO inserts a `sessions` row keyed by
      // the new task.id so the unattended-mode flag persists from
      // creation. Forwarded only for standard tasks (routine and
      // memory have their own session lifecycle). The api.createTask
      // helper filters out `'0'`/undefined so we don't trigger an
      // unnecessary session INSERT for the common case.
      isAutoRetryUntilStop?: string
      // NEW (Migration 067 — kanban task tags): array of free-form
      // tag strings. Forwarded to api.createTask which JSON-encodes
      // for the wire. Empty array / undefined = no tags.
      tags?: string[]
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
        isAutoRetryUntilStop: params.isAutoRetryUntilStop,
        // Migration 067 — pass tags through.
        tags: params.tags,
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
        is_auto_retry_until_stop: params.isAutoRetryUntilStop,
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
          // Defensive merge: mirror the `addDesignItem` pattern
          // (workspaces.ts:721-748). If the backend ever regresses
          // to a bare `{id, success}` envelope or omits the
          // `name` field, the sidebar would render the
          // `{{ item.name || 'Untitled project' }}` fallback
          // (WorkspaceItem.vue:401-408) until reload. Falling back
          // to the form's `name` / `path` (the source of truth on
          // the client side) keeps the UI correct regardless of
          // what the server returns. Locked in by the
          // `kanbanStoreAddNameFallback` regression test.
          name: item.name ?? name,
          item_type: item.item_type ?? 'kanban',
          path: item.path ?? path,
          kanban_columns: columns || [],
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
        // (line ~670) — mirrors the same defense-in-depth. (Bug
        // history: kanban originally did NOT have this fallback
        // and the backend returned a flat `CreateKanbanResponse`
        // without the `item` wrapper, so `const { item, columns }
        // = await api.createKanban(...)` got both as undefined and
        // every newly-created kanban displayed as "Untitled
        // project" until reload. The backend now wraps the
        // response in `{item, columns}` and both store actions
        // have the defensive fallback.)
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
    limit = 100,
    cursor?: string,
    q?: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    try {
      // Chunk 1 of kanban-lazy-load-tasks plan: bump initial fetch to
      // the backend's MAX_PAGE_SIZE (100). The previous default (no
      // limit → backend default 20) silently truncated kanbans with >
      // 20 tasks so columns showed partial data with no "Load more"
      // affordance. Keep this in sync with tasks_list.zig::MAX_PAGE_SIZE.
      //
      // Kanban task search (Chunk 4 of plan):
      // docs/superpowers/plans/2026-07-30-kanban-task-search.md — `q`
      // is the active search query. Server-side filter on name +
      // description + tags. When q changes, the cursor resets to
      // undefined (page 1 of the filtered set) — the caller is
      // responsible for that, we don't track cursor+q consistency
      // here.
      const { tasks, has_more, next_cursor } = await api.getTasks(
        workspaceId,
        itemId,
        limit,
        cursor,
        'updated_at',
        'desc',
        q,
      )
      // Migration 067 — normalize tags from wire string to in-memory
      // string[]. The card UI reads task.tags directly; if the wire
      // string leaks through, JSON.stringify fails silently and the
      // chip render path crashes.
      item.tasks = (tasks ?? []).map(normalizeTaskTags)
      item.hasMoreTasks = has_more
      item.tasksNextCursor = next_cursor

      // Track the active q so SSE handlers + loadMoreTasks can
      // forward it on subsequent refetches. Empty / undefined =
      // "no search active" → DELETE the entry (preserves Map size
      // bounded by the number of boards with active searches).
      if (q && q.length > 0) {
        activeSearchQueries.set(itemId, q)
      } else {
        activeSearchQueries.delete(itemId)
      }
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

  // HTML body-only update (Monaco Save button). Mirrors the
  // `updateDesignElement` shape: PATCHes the dedicated html
  // endpoint, mirrors the response into the local design_elements
  // array. Undo/redo plan Chunk 1 wire-up — the Monaco Save button
  // previously emitted `htmlChanged` upward with no listener
  // (silent drop). Now PropertiesPanel calls this directly.
  async function updateDesignElementHtml(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
    html: string,
  ): Promise<DesignElement> {
    const updated = await updateDesignElementHtmlApi(
      workspaceId,
      itemId,
      pageId,
      elementId,
      html,
    )
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = updated
    }
    return updated
  }

  // Geometry-only update path (drag/resize fires at the 50 ms
  // throttle, i.e. ≤20 Hz). The backend's `design_elements_geometry_
  // update` PATCH is the dedicated endpoint — no full element GET is
  // needed; the response is the full DesignElement.
  //
  // MIRROR the response into `item.design_elements[]` so the
  // DesignElement wrapper's `elementStyle.left/top` (bound to
  // `props.element.x/y`) updates reactively during drag. The earlier
  // "don't mirror — drag-end handler reconciles" comment was wrong:
  // no such handler existed, so single-element drags stayed frozen
  // at the pointerdown-time position for the entire drag (PATCHes
  // fired, the element just didn't visually follow the cursor). The
  // 60+/sec reactivity concern from the original comment is moot —
  // the 50 ms throttle caps the rate at 20 Hz, the SSE dedupe
  // (1500 ms TTL) prevents the GET fan-out, and Vue's reactivity is
  // cheap (just an attribute-style update on the wrapper div).
  //
  // The batch endpoint (`updateDesignElementsGeometryBatch` below)
  // already mirrors its response — this action was the asymmetric
  // exception that bit the single-element drag path.
  //
  // Chunk 3 (design-drag-debounce-batch): register the mutated
  // element_id in `recentLocalMutations` so the SSE handler skips
  // the GET fan-out for locally-issued PATCHes.
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
    const result = await updateDesignElementGeometryApi(
      workspaceId,
      itemId,
      pageId,
      elementId,
      geometry,
    )
    // Mirror the response into the local cache. Defensive no-op when
    // the item isn't in the local store (stale SSE callers).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      const idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (idx !== -1) item.design_elements[idx] = result
    }
    registerRecentLocalMutations([elementId], Date.now() + RECENT_MUTATION_TTL_MS)
    return result
  }

  // Atomic N-element geometry update. Used by the canvas drag
  // handler for multi-element drag so the N per-element PATCHes
  // collapse into ONE PATCH per pointermove. The response is
  // mirrored into the local design_elements array in place
  // (preserves the array's order for non-affected elements).
  //
  // Plan: docs/superpowers/plans/2026-07-30-design-drag-debounce-batch.md
  //   (Chunk 3, Task 3.1)
  async function updateDesignElementsGeometryBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    updates: GeometryBatchUpdate[],
  ): Promise<DesignElement[]> {
    if (updates.length === 0) return []
    const result = await updateDesignElementsGeometryBatchApi(
      workspaceId,
      itemId,
      pageId,
      updates,
    )
    // Mirror every updated row into the local design_elements array
    // in input order (preserves the array's existing order).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    // Register all affected element ids so the SSE handler skips the
    // GET fan-out. Strict superset semantics in the SSE listener:
    // a missing id falls through to the fetch path (defensive).
    registerRecentLocalMutations(
      updates.map((u) => u.element_id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    return result.updated
  }

  // Update a design page's width/height (UI resize from the canvas
  // header W × H inputs). Backend's PATCH /pages/:page_id validates
  // the ranges (width 320-4096, height 240-4096) and returns 400
  // with an explicit error message otherwise. The DesignPage list
  // lives in DesignView's local state (not Pinia), so this action
  // only needs to return the updated page — the caller mutates its
  // local array. Errors propagate via the apiFetch wrapper's thrown
  // ApiError, surfaced as a toast by DesignView's catch block.
  async function updateDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
    patch: { width: number; height: number },
  ): Promise<DesignPage> {
    return await updateDesignPageApi(workspaceId, itemId, pageId, patch)
  }

  // Server-side cascade move. Each item's (dx, dy) applies to the
  // element AND every transitive descendant of that element. Optional
  // width/height/rotation apply ONLY to the root.
  //
  // Mirrors the response into the local `design_elements` array in
  // input order (the server returns the deduped union of all cascaded
  // ids in tree-traversal order). Registers all cascaded ids in
  // recentLocalMutations so the SSE handler skips the GET fan-out.
  //
  // Empty `items` is a no-op (returns []) without an API call — same
  // defensive pattern as `updateDesignElementsGeometryBatch`.
  //
  // Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md
  //   (Chunk 3, Task 3.2)
  async function moveDesignElementsBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    items: MoveBatchItem[],
  ): Promise<DesignElement[]> {
    if (items.length === 0) return []
    const result = await moveDesignElementsBatchApi(workspaceId, itemId, pageId, { items })
    // Mirror every updated row into the local design_elements array
    // (preserves the array's existing order for non-affected elements).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    // Register all cascaded ids so the SSE handler skips the GET
    // fan-out. The cascade can include descendants the user didn't
    // explicitly select (e.g. clicking a group with 4 children follows
    // with all 4 ids).
    registerRecentLocalMutations(
      result.updated.map((e) => e.id),
      Date.now() + RECENT_MUTATION_TTL_MS,
    )
    return result.updated
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

  // Wrap 2+ elements into a new `group` (or `frame`) parent at the
  // union bbox. The backend returns the full new parent + the
  // updated children (with `parent_id` set). Mirrors both rows into
  // the local `design_elements` array:
  //   - the new parent is appended (so the layers panel picks it up);
  //   - each returned child replaces its previous copy in place
  //     (preserves z_index / position sort stability).
  //
  // Errors propagate via the apiFetch ApiError (4xx throws, network
  // failures throw, surface via the composable's notification toast).
  async function reorderDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    mode: ReorderMode,
    elementIds: string[],
  ): Promise<DesignElement[]> {
    const result = await reorderDesignElementsApi(workspaceId, itemId, pageId, {
      mode,
      element_ids: elementIds,
    })
    // Mirror the server's `reordered` rows into the local
    // design_elements array so the layers panel + canvas re-render
    // immediately. We replace matching ids in place (preserves the
    // local array's ordering for any ids NOT in the response).
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.reordered) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result.reordered
  }

  async function groupDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: GroupDesignElementsRequest,
  ): Promise<{ parent: DesignElement; children: DesignElement[] }> {
    const result = await groupDesignElementsApi(workspaceId, itemId, pageId, body)
    const item = findItem(workspaceId, itemId)
    if (item) {
      if (!item.design_elements) item.design_elements = []
      // Append the new parent (preserves backend ordering: highest
      // position last).
      item.design_elements.push(result.parent)
      // Replace each child in place. We don't filter the array first
      // because the backend's returned children are already updated
      // versions; the originals are still useful for comparison in
      // tests but the in-place replace keeps the array length stable.
      for (const updated of result.children) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result
  }

  // Atomic N-element reparent (1 OR many). Used by the LayersPanel
  // drag-and-drop affordance. The whole batch is all-or-nothing —
  // the backend rejects with 400 BadReparent if ANY element would
  // close a cycle, and 0 writes happen. The local state is mirrored
  // after a successful response; on error the store is unchanged
  // and the error propagates so the composable can show a toast.
  //
  // Mirrors the in-place-replace pattern of groupDesignElements +
  // updateDesignElementsGeometryBatch: each returned `updated` row
  // replaces its current row in `design_elements` (preserves the
  // array's existing order for non-affected elements).
  async function reparentDesignElementsBatch(
    workspaceId: string,
    itemId: string,
    pageId: string,
    body: Omit<ReparentDesignElementsBatchRequest, 'reposition'> & {
      reposition?: ReparentDesignElementsBatchRequest['reposition']
    },
  ): Promise<DesignElement[]> {
    const reposition = body.reposition ?? 'last_in_parent'
    const result = await reparentDesignElementsBatchApi(workspaceId, itemId, pageId, {
      element_ids: body.element_ids,
      new_parent_id: body.new_parent_id,
      reposition,
    })
    const item = findItem(workspaceId, itemId)
    if (item?.design_elements) {
      for (const updated of result.updated) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
    }
    return result.updated
  }

  // Dissolve a group/frame: reparent its direct children to the
  // group's parent (or top-level if the group had no parent), then
  // delete the group row. Mirrors the in-place-replace pattern of
  // groupDesignElements (each returned `orphaned` row replaces its
  // current row in `design_elements`; the group row is removed).
  async function ungroupDesignElements(
    workspaceId: string,
    itemId: string,
    pageId: string,
    elementId: string,
  ): Promise<{ orphaned: DesignElement[] }> {
    const result = await ungroupDesignElementsApi(workspaceId, itemId, pageId, elementId)
    const item = findItem(workspaceId, itemId)
    if (item && item.design_elements) {
      // Replace each orphaned child in place.
      for (const updated of result.orphaned) {
        const idx = item.design_elements.findIndex((e) => e.id === updated.id)
        if (idx !== -1) item.design_elements[idx] = updated
      }
      // Remove the group row itself.
      const group_idx = item.design_elements.findIndex((e) => e.id === elementId)
      if (group_idx !== -1) item.design_elements.splice(group_idx, 1)
    }
    return result
  }

  // Delete a page. Idempotent on the backend (404 = already gone).
  // Note: DesignView manages its own local `pages` array (fetched
  // via `listDesignPages`); there is no `design_pages` field on the
  // WorkspaceItem type. So the store's only responsibility here is
  // to clear `activeDesignPageId` if it matches the deleted page —
  // DesignView's own `watch(activePageId)` picks up the change and
  // re-fetches via `listDesignPages`, which returns the new (smaller)
  // page list. The next-page-active pick uses DesignView's own
  // first-page-defaults-to-empty convention.
  async function deleteDesignPage(
    workspaceId: string,
    itemId: string,
    pageId: string,
  ): Promise<void> {
    await deleteDesignPageApi(workspaceId, itemId, pageId)
    if (activeDesignPageId.value === pageId) {
      activeDesignPageId.value = ''
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

  // Kanban "create task & run agent" flow (plan:
  // docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md).
  // Wraps api.sendChatMessage so KanbanView doesn't import the wire
  // shape directly. Returns the backend status so the host can decide
  // whether to navigate to the chat view.
  async function runAgentOnNewTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
    params: {
      queueMessage: string
      cwd: string
      isAutoRetryUntilStop?: '0' | '1'
    },
  ): Promise<{ status: string } | undefined> {
    try {
      return await api.sendChatMessage(
        taskId,
        params.queueMessage,
        params.cwd,
        undefined, // imageUrls
        '', // selectedProfile
        params.isAutoRetryUntilStop ?? '', // forwards '1' when toggle ON, else ''
      )
    } catch (err) {
      console.error('Failed to run agent on new task:', err)
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
      // Kanban task search (Chunk 4): forward the active q so
      // "Load more" fetches the next page of MATCHES, not the next
      // page of everything. Read from activeSearchQueries (set by
      // fetchKanbanTasks(q)).
      const activeQ = activeSearchQueries.get(itemId)
      const { tasks, has_more, next_cursor } = await api.getTasks(
        workspaceId,
        itemId,
        20, // PAGE_SIZE — keep in sync with the default in api/index.ts
        item.tasksNextCursor,
        'updated_at',
        'desc',
        activeQ,
      )
      // Append the new page to the existing list. We push (not unshift)
      // because tasks are ordered newest-first, so older tasks go at
      // the end of the list. Migration 067 — normalize tags from wire
      // string to in-memory string[] at every fetch site.
      if (!item.tasks) item.tasks = []
      item.tasks.push(...tasks.map(normalizeTaskTags))
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
    // FIX (2026-07-14): clear the navigation store's active chat so a
    // subsequent SSE session_created event (fired on every send) cannot
    // navigate back into the previous chat when the user is typing into
    // a task. Mirrors navigationStore.setActiveTask (navigation.ts:123).
    //
    // IMPORTANT (fix for `view=chat&session=X` showing the welcome page
    // instead of <ChatView>): only clear the chat when we're ACTIVATING
    // a task (taskId !== null). When called with taskId === null as
    // part of the "navigate to chat" / "navigate to workspace" /
    // "navigate to design" cleanup sequences (Sidebar.vue:321, ChatsList.vue:212,
    // ChatsList.vue:227, ChatsList.vue:251), clearing the chat
    // UNDOES the navigationStore.setActiveChat that just ran a few lines
    // above, leaving the v-else-if chain at AppLayout.vue:1611 unable to
    // match `activeChatId.startsWith('chat-')` and falling through to
    // <Chats/> (welcome page) instead of <ChatView/>. Symptom trace
    // (verified in the live app via DevTools):
    //   [Sidebar.vue:318 handleChatsNavigate]
    //   → workspacesStore.setActiveTask(null)
    //   → workspacesStore.setActiveTask calls useNavigationStore().clearActiveChat()
    //   → activeChatId flips from 'chat-task_X' to ''
    //   → v-else-if at AppLayout.vue:1611 fails → <Chats/> renders
    // Originally cleared unconditionally in the 2026-07-14 fix that
    // introduced `setActiveTask(null)` calls in the chat-list nav paths;
    // the unconditional clear was a side-effect, not a deliberate
    // contract. Gating on `taskId !== null` preserves the original
    // intent (don't keep a stale chat active when entering a task) while
    // letting the chat-clear happen in the right place (after the user
    // truly leaves the chat for a task, not as part of a "reset all
    // non-chat state before activating chat" sequence).
    if (taskId !== null) {
      useNavigationStore().clearActiveChat()
    }

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
            // Chunk 7 of kanban-task-notification-icon: opening the
            // chat counts as a human touch — stamp
            // `last_human_touched_at` so the kanban card's orange
            // "AI finished — awaiting review" dot flips to the
            // green "reviewed" checkmark. Fire-and-forget: this
            // is best-effort metadata; failures log a warning but
            // don't surface to the user (the chat has already
            // opened, that's what they care about).
            //
            // Idempotency is guaranteed by the store's
            // `activeTaskId.value = taskId` assignment above: if
            // the same taskId is passed twice in a row (a re-click
            // on the already-active card), the second call short-
            // circuits here because activeTaskId is already the
            // target value.
            void api.markTaskHumanTouched(workspace.id, item.id, taskId).catch(
              (err: unknown) => {
                console.warn(
                  '[workspacesStore.setActiveTask] markTaskHumanTouched failed (non-fatal):',
                  err,
                )
              },
            )
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

  // Update a task's name AND/OR description in a single round-trip
  // (kanban-task-detail-dialog plan, Chunk 2). Mirrors the
  // optimistic-update + rollback pattern from `renameTask`. The
  // patch object only includes fields the caller actually sent —
  // missing fields are left unchanged server-side. Empty string
  // for `description` IS sent (user explicitly cleared it);
  // empty/whitespace `name` is rejected (matches the
  // renameTask guard).
  async function updateTaskDetails(
    workspaceId: string,
    itemId: string,
    taskId: string,
    fields: { name?: string; description?: string; tags?: string[] },
  ) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.tasks) return
    const task = item.tasks.find((t) => t.id === taskId)
    if (!task) return

    // Build the patch — only include fields the caller actually sent.
    // A no-op patch (all undefined) is rejected early so we don't
    // burn an API call.
    const patch: { name?: string; description?: string; tags?: string[] } = {}
    if (fields.name !== undefined) {
      const trimmed = fields.name.trim()
      if (!trimmed) return // empty name is never a valid update
      patch.name = trimmed
    }
    if (fields.description !== undefined) {
      patch.description = fields.description
    }
    // Migration 067 — kanban task tags. Empty array = clear all
    // tags; undefined = leave unchanged. The api.updateTaskSimple
    // helper detects `tags !== undefined` and JSON-encodes the
    // array for the wire; the backend validates + persists.
    if (fields.tags !== undefined) {
      patch.tags = fields.tags
    }
    if (Object.keys(patch).length === 0) return

    // Optimistic update — capture previous values for rollback.
    const previousName = task.name
    const previousDescription = task.description
    const previousTags = task.tags
    if (patch.name !== undefined) task.name = patch.name
    if (patch.description !== undefined) task.description = patch.description
    if (patch.tags !== undefined) task.tags = patch.tags

    // Keep the chat-view / chat-list header in sync if this is the
    // active task and a name change is part of the patch.
    const wasActive = activeTaskId.value === taskId
    if (wasActive && patch.name !== undefined) {
      useNavigationStore().setActiveChatName(patch.name)
    }

    try {
      await api.updateTaskSimple(taskId, patch)
    } catch (err) {
      console.error('Failed to update task details:', err)
      // Rollback on error
      task.name = previousName
      task.description = previousDescription
      task.tags = previousTags
      if (wasActive) {
        useNavigationStore().setActiveChatName(previousName)
      }
      // Rethrow so the dialog can show a retry option. Mirrors the
      // renameTask contract — the dialog (Chunk 3) catches this in
      // its own Save handler.
      throw err
    }
  }

  // Refetch a single task from the server and patch the in-store copy
  // in place. Used by KanbanView.handleViewTaskDetail so the
  // Task details dialog opens with the live `is_auto_retry_until_stop`
  // value (which lives on sessions, joined at read time) rather than
  // the value the workspaces store last saw at init() time. This
  // prevents the "toggle shows OFF but the DB is ON" race when a
  // different client toggled the flag since this client last loaded.
  //
  // Implementation note: we re-fetch the WHOLE task list for the
  // item (via the existing GET /api/workspaces/:ws/items/:item/tasks
  // endpoint) and pluck the one we care about. This avoids adding
  // a new GET /tasks/:id endpoint just for this case — the backend
  // already returns is_auto_retry_until_stop via the JOIN we just
  // added (commit 2e2373ed). A list refresh is heavier than a
  // single-row fetch but the workspace_item_tasks table is small
  // (typically <20 rows per item) so the cost is negligible.
  //
  // Best-effort: a failure is logged but does NOT block the dialog
  // from opening. The dialog will fall back to the cached value
  // (which is still better than blocking the user with a network
  // error on every dialog open).
  async function refreshTask(
    workspaceId: string,
    itemId: string,
    taskId: string,
  ): Promise<void> {
    try {
      const { tasks: fresh } = await api.getTasks(workspaceId, itemId, 100)
      // Migration 067 — normalize tags from wire string to in-memory
      // string[] before splicing into the store.
      const freshTask = fresh.map(normalizeTaskTags).find((t) => t.id === taskId)
      if (!freshTask) return
      for (const ws of workspaces.value) {
        if (ws.id !== workspaceId) continue
        for (const item of ws.items) {
          if (item.id !== itemId) continue
          if (!item.tasks) continue
          const idx = item.tasks.findIndex((t) => t.id === taskId)
          if (idx === -1) continue
          // Replace the cached task object entirely. The Task
          // interface is loose enough (mostly optional fields) that
          // this preserves all caller state. The dialog re-derives
          // its local form state from the new task via its watcher.
          item.tasks.splice(idx, 1, freshTask)
          return
        }
      }
    } catch (err) {
      console.warn('Failed to refresh task before dialog open:', err)
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
        // name + unattended flag. We also keep
        // navigationStore.activeChatName in sync if the renamed
        // task is active — this is the same pattern as
        // renameTask (workspaces.ts:renameTask). The unattended
        // flag update keeps the KanbanTaskDetailDialog toggle
        // in sync if the dialog is open (without it, the toggle
        // would show the value from when the dialog was opened,
        // which becomes stale on PUT /api/llm/session/:id).
        for (const ws of workspaces.value) {
          for (const item of ws.items) {
            if (!item.tasks) continue
            const task = item.tasks.find((t) => t.id === event.id)
            if (task) {
              task.name = event.name || task.name
              if (event.is_auto_retry_until_stop !== undefined) {
                task.is_auto_retry_until_stop = event.is_auto_retry_until_stop
              }
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
    // NEW (Chunk 1 of design-element-drag-and-drop plan): the currently
    // active design page id, mirrored from DesignView so AppLayout's
    // design handlers can route PATCH/PUT/DELETE to the right page.
    activeDesignPageId,
    // Kanban task search (Chunk 4): exposed so SSE handlers can read
    // the active q and forward it on refetch.
    activeSearchQueries,
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
    // NEW (Chunk 1 of design-element-drag-and-drop plan): mirror the
    // active design page id from DesignView. Called on mount + tab
    // switch, and cleared on unmount.
    setActiveDesignPage,
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
    // NEW (kanban-task-detail-dialog plan, Chunk 2). Edit a task's
    // name and/or description in one API call from the detail
    // dialog. Uses the same PUT /api/workspaces/tasks/:task_id
    // endpoint as renameTask — only the body shape is wider.
    updateTaskDetails,
    // NEW (auto-retry-until-stop fix): re-fetch a single task from
    // the server (with the JOINed is_auto_retry_until_stop column)
    // and patch the in-store copy. Used by the Task details dialog
    // on open so the unattended-mode toggle shows server truth
    // instead of the value cached at workspaces store init().
    refreshTask,
    runRoutine,
    runAgentOnNewTask,
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
    updateDesignElementsGeometryBatch,
    moveDesignElementsBatch,
    updateDesignElementHtml,
    deleteDesignElement,
    deleteDesignPage,
    updateDesignPage,
    groupDesignElements,
    ungroupDesignElements,
    reparentDesignElementsBatch,
    reorderDesignElements,
    initializeFromSystemFolder,
    onSessionEvent,
    fetchSystemFolder,
    fetchFolderContents,
  }
})

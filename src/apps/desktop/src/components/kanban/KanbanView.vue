<!--
  KanbanView — the board layout for a kanban workspace item.

  Layout (top → bottom):
    1. Header — kanban name (item.name) + "+ Column" button.
                "+ Column" emits `add-column` (the parent opens
                KanbanColumnEditor in 'add' mode).
    2. Columns row — horizontally-scrollable container of
                <KanbanColumn>, one per item.kanban_columns (sorted
                by position). Each column receives the full tasks
                array and filters internally by kanban_column_id.

  The view is purely presentational — all the heavy lifting (CRUD
  on columns and tasks) lives in the host (WorkspaceItem.vue →
  Sidebar.vue → workspacesStore). The board just emits events
  upward; the host decides what to do (open the editor, call a
  store action, navigate, etc.).

  Public API:
    props:
      item          WorkspaceItem
      workspaceId   string  (default '' — host should pass the real id)
      itemId        string  (default item.id — kept separate so the
                              host can override if needed)
    emits:
      add-column    []
      move-task     [{ taskId, columnId, position }]
      rename-column [{ columnId, name }]
      delete-column [columnId]
      reorder-column [{ columnId, targetColumnId }]
      // Pass-through from KanbanColumn:
      select-task, delete-task, rename-task, edit-routine,
      run-routine, pin-task
      request-rename-column, request-delete-column (host opens
      KanbanColumnEditor on these)
      view-task-detail (consumed internally — see comment below)
      rename-item (kanban header pencil; forwarded to AppLayout)

  Live updates:
    The component reacts to backend SSE events on `/api/kanban/events`
    through the workspacesStore. Two event families drive auto-refresh:
      - kanban_column.* (created / updated / deleted / reordered)
        → workspacesStore.fetchKanbanColumns refreshes
          item.kanban_columns. The columns row re-renders.
      - kanban_task.* (assigned / moved / unassigned)
        → workspacesStore.fetchKanbanTasks refreshes item.tasks.
          The cards re-filter by kanban_column_id and re-sort by
          kanban_position, so the affected card visibly moves
          between columns without a manual reload.

    Both refresh paths are owned by useKanbanSseStore (one global
    connection, AppLayout-managed). KanbanView.vue does NOT open
    its own SSE connection — the store-level subscription covers
    the lifetime of the AppLayout (one connection, even if the
    user navigates between kanbans).
-->
<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import KanbanColumn from './KanbanColumn.vue'
import KanbanSearchInput from './KanbanSearchInput.vue'
import KanbanTaskDetailDialog from './KanbanTaskDetailDialog.vue'
import InlineEditableText from '../preview/InlineEditableText.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { useKanbanScrollRestore } from '../../composables/useKanbanScrollRestore'
import { useRoute, useRouter } from 'vue-router'
import type { PreviewFile } from '../file/FilePreview.vue'
import type { WorkspaceItem, Task, KanbanColumn as KanbanColumnType } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    item: WorkspaceItem
    workspaceId?: string
    itemId?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
  },
)

const workspacesStore = useWorkspacesStore()
const router = useRouter()
const route = useRoute()

// Lazy-load the kanban's columns on mount + whenever the item id
// changes (e.g. user navigates from one kanban to another without
// unmounting the component). The workspaces/items endpoint does NOT
// embed columns — kanbans can have arbitrarily many and we want a
// lazy load (mirrors the folder-item `fetchFolderContents` pattern).
// Without this, the board renders empty on every page reload even
// though the seeded 3 default columns exist in the DB.
const effectiveItemId = computed(() => props.itemId || props.item.id)

// NOTE (kanban-chat-as-dialog plan): KanbanView no longer owns a
// chat pane. The dialog is mounted at AppLayout level (KanbanChatDialog)
// and the kanban renders only the full-width board. The
// `workspacesStore.activeTask` getter is consumed by the dialog,
// not by this component.

const loadColumns = () => {
  if (props.workspaceId && effectiveItemId.value) {
    void workspacesStore.fetchKanbanColumns(props.workspaceId, effectiveItemId.value)
  }
}

onMounted(loadColumns)
watch(() => [props.workspaceId, effectiveItemId.value], loadColumns)

// ─── Horizontal scroll position preservation ──────────────────────────
//
// KanbanView renders the kanban board full-width. The chat task is
// now in AppLayout's KanbanChatDialog (centered modal overlay, not
// a side-by-side layout). When the user opens + closes the dialog,
// the KanbanView instance stays mounted — the dialog teleports in
// and out — so scroll position survives naturally. The composable
// still persists scrollLeft to localStorage so refreshes keep the
// column the user was looking at.
//
// Plan: docs/superpowers/plans/2026-07-23-preserve-kanban-horizontal-scroll.md
const kanbanColumnsContainer = ref<HTMLElement | null>(null)
const kanbanScrollStorageKey = computed(
  () => `kanban-scroll-${effectiveItemId.value}`,
)
useKanbanScrollRestore(kanbanColumnsContainer, kanbanScrollStorageKey)

const emit = defineEmits<{
  addColumn: []
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  // Column drag-and-drop reorder (Trello/Jira UX). Bubbled up
  // from <KanbanColumn> headers to AppLayout, which calls the
  // workspacesStore.reorderKanbanColumn action.
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  // Open the per-board KanbanSettingsDialog (host owns it). No
  // payload — the host derives the active item from its own state.
  openSettings: []
  // Pass-through from KanbanColumn.
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the per-task detail dialog (kanban-task-detail-dialog
  // feature). Consumed INTERNALLY here — the dialog is mounted in
  // this file's template (we own the kanban's columns & tasks, so
  // resolving the matching column is trivial). AppLayout doesn't
  // need to know about this dialog.
  viewTaskDetail: [taskId: string]
  // The column's "⋮" menu sends these; the host opens
  // KanbanColumnEditor in the right mode.
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
  /**
   * Fired when the user renames the kanban via the inline pencil
   * on the header title. Mirrors KanbanSettingsDialog's
   * rename-item emit so AppLayout handles both with one handler.
   *
   * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
   */
  renameItem: [name: string]
  // Chat pane (kanban-embed-chatview plan, Task 2+4). Fired when
  // ChatView's header close button is clicked. AppLayout's handler
  // clears activeTask + navigates to view=workspace (URL is the
  // source of truth).
  closeChat: []
}>()

// ─── Derived data ──────────────────────────────────────────────────────────

// Columns sorted by position ascending (defensive — the backend
// already returns them in order, but we sort again locally so a
// reorder never produces an out-of-order board even before the
// API response lands).
const sortedColumns = computed(() => {
  return (props.item.kanban_columns ?? [])
    .slice()
    .sort((a, b) => a.position - b.position)
})

// Tasks for this kanban (defensive — undefined is treated as []).
const tasks = computed<Task[]>(() => props.item.tasks ?? [])

// ─── Search (kanban task search — Chunk 6) ────────────────────────────────
//
// The search input is a v-model'd ref. A 300ms trailing-edge debounce
// (hand-rolled — @vueuse/core is not installed in this project) drives
// a refetch via workspacesStore.fetchKanbanTasks(q). Empty/whitespace
// q is treated as "no filter" (passed as undefined so the backend
// omits the SQL WHERE clause). Component-local state — closing and
// reopening the kanban clears it automatically (KanbanView is
// mounted/unmounted on navigation between kanbans).
//
// Cursor resets on every query change (page 1 of the filtered set) —
// mixing page 1 of the old query with page 2 of the new query would
// return inconsistent results.
const searchQuery = ref('')
let searchDebounceTimer: ReturnType<typeof setTimeout> | null = null

const clearSearchDebounce = () => {
  if (searchDebounceTimer !== null) {
    clearTimeout(searchDebounceTimer)
    searchDebounceTimer = null
  }
}

watch(searchQuery, (newQ) => {
  clearSearchDebounce()
  searchDebounceTimer = setTimeout(() => {
    searchDebounceTimer = null
    const trimmed = newQ.trim()
    void workspacesStore.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      100,        // limit (matches backend MAX_PAGE_SIZE)
      undefined,  // cursor — reset to page 1 of the filtered set
      trimmed || undefined,
    )
  }, 300)
})

onUnmounted(clearSearchDebounce)

// ─── Per-column sort (kanban-sort-by, redo 2026-08-06) ────────────────
//
// Each KanbanColumn has its own sortBy + direction (columns/index.vue
// emits 'sortChange' on every change). KanbanView is the source of
// truth for:
//   1. URL persistence — `?sorts=col_<id>:<sortBy>:<direction>,...`.
//      Default sort (position + asc) is omitted to keep URLs clean
//      for users who never touch a column's sort dropdown.
//   2. API re-fetch — when any column's sort changes, we fetch the
//      kanban tasks with that sort. The backend returns ALL tasks
//      sorted globally; each column's cardsInColumn then applies its
//      own client-side sort on top (so per-column independence is
//      preserved — see compareBySortMode in KanbanColumn.vue).
//
// The fetch is debounced (300ms) so rapid column-sort changes don't
// fire N requests. Same pattern as the search-input watcher above.
//
// URL format: `?sorts=col_1:name:asc,col_2:created_at:desc,...`
// Comma-separated; each entry is `col_<id>:<sortBy>:<direction>`.
// Validate on parse (typo / out-of-range → drop the entry).

interface SortEntry {
  columnId: string
  sortBy: 'position' | 'created_at' | 'updated_at' | 'name'
  direction: 'asc' | 'desc'
}

// Parse the URL's `sorts` query param. Returns an empty array if
// missing / malformed.
const parseSortsParam = (raw: string | string[] | undefined): SortEntry[] => {
  if (!raw) return []
  const s = Array.isArray(raw) ? raw.join(',') : raw
  const entries: SortEntry[] = []
  for (const part of s.split(',')) {
    const trimmed = part.trim()
    if (!trimmed) continue
    const [columnId, sortBy, direction] = trimmed.split(':')
    if (!columnId || !sortBy || !direction) continue
    if (
      sortBy !== 'position' && sortBy !== 'created_at' &&
      sortBy !== 'updated_at' && sortBy !== 'name'
    ) continue
    if (direction !== 'asc' && direction !== 'desc') continue
    entries.push({ columnId, sortBy, direction })
  }
  return entries
}

// Encode the per-column sorts into a URL-safe `sorts` string.
// Default sorts (position + asc) are OMITTED so the URL stays clean.
// Returns null when no non-default sorts exist (caller writes no
// `sorts` param).
const encodeSortsParam = (entries: SortEntry[]): string | null => {
  const filtered = entries.filter(
    (e) => !(e.sortBy === 'position' && e.direction === 'asc'),
  )
  if (filtered.length === 0) return null
  return filtered.map((e) => `${e.columnId}:${e.sortBy}:${e.direction}`).join(',')
}

// Map of column.id → latest sort. Reflects every column's picks
// (not just the latest one). Used by the URL mirror and by the
// fetch watcher.
const columnSorts = ref<Record<string, SortEntry>>({})

// Template refs to each KanbanColumn instance — needed so we can
// call the columns' setSortMode() (defineExpose seam) on URL
// restore. Map keyed by column.id, populated by the `ref="..."`
// callback in the template.
const columnRefs = ref<Record<string, unknown>>({})
const setColumnRef = (columnId: string) => (el: unknown) => {
  if (el) columnRefs.value[columnId] = el
}

// On mount: parse the URL's sorts param and apply each entry to
// its column via setSortMode. The KanbanColumn's watcher then
// re-emits the change, populating columnSorts via the
// handleColumnSortChange path below.
//
// IMPORTANT: we ALSO fire fetchKanbanTasks DIRECTLY (not via the
// columnSorts watcher chain) with the restored sort. The
// workspacesStore's SSE handler ALSO fires an initial fetch with
// the default sort ('updated_at desc') on mount — this races with
// our restore. By firing our fetch with the restored sort
// BEFORE the SSE handler's first re-fetch lands, the user sees
// the right order on initial render. The column's setSortMode
// triggers the visual re-sort client-side regardless.
//
// Guarded: tests that don't mock vue-router (e.g. legacy
// KanbanView.createAndRun.spec.ts) call this component without
// useRouter/useRoute setup. The route/router are null in that
// case; skip the URL restore gracefully.
onMounted(() => {
  const routeObj = (() => {
    try {
      return route
    } catch {
      return null
    }
  })()
  if (!routeObj) return
  const sortsRaw = routeObj.query?.sorts as string | undefined
  if (!sortsRaw) return
  const entries = parseSortsParam(sortsRaw)
  // Mirror into columnSorts immediately — no need to wait for
  // column refs to populate. The watcher on columnSorts will
  // write the URL (no-op since it's already correct) and trigger
  // a debounced fetch, but we ALSO fire the fetch directly so it
  // happens NOW (before the SSE handler's default-sort fetch
  // lands).
  const next: Record<string, SortEntry> = {}
  for (const entry of entries) {
    next[entry.columnId] = entry
  }
  columnSorts.value = next

  // Wait for the next tick so the column refs are populated, then
  // call setSortMode on each column for visual consistency.
  void nextTick(() => {
    for (const entry of entries) {
      const col = columnRefs.value[entry.columnId] as
        | { setSortMode?: (s: string, d: string) => void }
        | null
        | undefined
      if (col && typeof col.setSortMode === 'function') {
        col.setSortMode(entry.sortBy, entry.direction)
      }
    }
  })

  // Fire the fetch directly with the most-recently-changed sort
  // (last in the entries array — preserves insertion order).
  // Use the LAST non-default sort (manual doesn't have a server
  // equivalent).
  const lastNonDefault = [...entries].reverse().find(
    (e) => !(e.sortBy === 'position' && e.direction === 'asc'),
  )
  if (!lastNonDefault) return
  const apiSortBy = lastNonDefault.sortBy === 'position'
    ? undefined
    : lastNonDefault.sortBy as 'created_at' | 'updated_at' | 'name'
  void workspacesStore.fetchKanbanTasks(
    props.workspaceId,
    effectiveItemId.value,
    100,
    undefined,
    undefined,
    apiSortBy,
    lastNonDefault.direction,
  )
})

// Watcher on columnSorts changes → debounced fetch + URL write.
// Triggered by the sort-change emit from each KanbanColumn.
let sortFetchDebounceTimer: ReturnType<typeof setTimeout> | null = null

const clearSortFetchDebounce = () => {
  if (sortFetchDebounceTimer !== null) {
    clearTimeout(sortFetchDebounceTimer)
    sortFetchDebounceTimer = null
  }
}

watch(columnSorts, (next) => {
  // URL write (synchronous — the user sees the URL update
  // immediately).
  const encoded = encodeSortsParam(Object.values(next))
  const query: Record<string, string> = { view: 'workspace' }
  if (props.workspaceId) query.workspaceId = props.workspaceId
  if (effectiveItemId.value) query.itemId = effectiveItemId.value
  if (encoded) query.sorts = encoded
  router.replace({ path: '/app', query })

  // Debounced fetch — fires only for non-default sorts, using the
  // latest-changed sort as the backend sort param. The backend
  // returns all tasks sorted; each column's cardsInColumn then
  // applies its own client-side sort on top.
  clearSortFetchDebounce()
  sortFetchDebounceTimer = setTimeout(() => {
    sortFetchDebounceTimer = null
    const entries = Object.values(columnSorts.value)
    const last = entries[entries.length - 1]
    if (!last) return
    if (last.sortBy === 'position' && last.direction === 'asc') return
    // The store's sortBy param excludes 'position' (no server
    // equivalent); narrow at the call site so the type checker
    // accepts the union.
    const apiSortBy = last.sortBy === 'position'
      ? undefined
      : last.sortBy as 'created_at' | 'updated_at' | 'name'
    void workspacesStore.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      100,
      undefined,
      undefined,
      apiSortBy,
      last.direction,
    )
  }, 300)
})

onUnmounted(() => {
  clearSortFetchDebounce()
})

// Handler for the column's sort-change emit. Updates the map
// (which triggers the watcher above).
const handleColumnSortChange = (
  columnId: string,
  payload: { sortBy: SortEntry['sortBy']; direction: SortEntry['direction'] },
) => {
  columnSorts.value = {
    ...columnSorts.value,
    [columnId]: { columnId, sortBy: payload.sortBy, direction: payload.direction },
  }
}

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleAddColumn = () => {
  emit('addColumn')
}

const handleOpenSettings = () => {
  emit('openSettings')
}

// ─── "Set project root" banner (backfill UX) ─────────────────────────────
//
// When a kanban has `path = null` (the user created it before the path
// field existed on the create endpoint), every chat session in this
// kanban's tasks is cwd-less — git/file tools fail with "no such
// directory". Surface a warning banner with a single click that
// opens the folder picker and persists the chosen path via
// workspacesStore.updateKanbanItemPath.
//
// The banner is purely informational (yellow tint, no destructive
// action). It hides once a path is set. The picker reuses the
// AddKanbanDialog's picker to keep the UX consistent — same data
// source, same select-pick-cancel flow.
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import { updateSession as apiUpdateSession } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'

const showPathPicker = ref(false)
const pathPickerBusy = ref(false)
const pathPickerError = ref<string | null>(null)

const loadItemsForPathPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}

const handleProjectRootSelected = async (path: string) => {
  showPathPicker.value = false
  if (!path) return
  pathPickerBusy.value = true
  pathPickerError.value = null
  try {
    await workspacesStore.updateKanbanItemPath(
      props.workspaceId,
      props.item.id,
      path,
    )
  } catch (err) {
    pathPickerError.value = err instanceof Error ? err.message : String(err)
  } finally {
    pathPickerBusy.value = false
  }
}

// ─── Task-detail dialog (kanban-task-detail-dialog — Chunk 4) ───────────
//
// The dialog is mounted locally in this component (NOT in AppLayout)
// because we already have the active kanban's columns + tasks in scope
// and resolving the matching column from `task.kanban_column_id` is
// trivial. Mounting it in AppLayout would force AppLayout to also know
// about the kanban's column structure, which is more complex.
//
// State flow:
//   - `activeTaskDetailId` — the id of the task whose details the user
//     wants to edit. Set when KanbanColumn's @view-task-detail fires.
//   - `activeTaskDetail` — the live Task object (resolved via `.find`).
//     Reactively updates if the store modifies the task mid-edit.
//   - `activeTaskDetailColumn` — the column hosting the task (nullable
//     for tasks with no kanban_column_id yet).
//   - `showTaskDetail` — drives the dialog's open/closed state.
const activeTaskDetailId = ref<string | null>(null)
const showTaskDetail = ref(false)

const activeTaskDetail = computed<Task | null>(() => {
  if (!activeTaskDetailId.value) return null
  return (props.item.tasks ?? []).find((t) => t.id === activeTaskDetailId.value) ?? null
})

const activeTaskDetailColumn = computed<KanbanColumnType | null>(() => {
  const t = activeTaskDetail.value
  if (!t || !t.kanban_column_id) return null
  return (props.item.kanban_columns ?? []).find((c) => c.id === t.kanban_column_id) ?? null
})

const handleViewTaskDetail = (taskId: string) => {
  activeTaskDetailId.value = taskId
  showTaskDetail.value = true
  // Refetch the task list so the dialog shows server-truth on open.
  // The KanbanTaskDetailDialog reads props.task.is_auto_retry_until_stop
  // to render the unattended-mode toggle, and that field can drift
  // out of sync across clients (e.g. another nalar instance
  // toggled the flag, or a sub-agent PUT ran unattended on a
  // shared session). The workspaces store re-fetches the whole
  // task list for the parent item, plucks this task, and patches
  // the cached copy in place. Best-effort — a failure is logged
  // and the dialog still opens with the cached value.
  void workspacesStore.refreshTask(
    props.workspaceId,
    props.itemId || props.item.id,
    taskId,
  )
}

// Dialog save handler — delegates to the store action which runs the
// optimistic update + API call + rollback-on-error. We close the
// dialog only on success; on error we keep it open so the user can
// retry without re-typing.
const handleTaskDetailSave = async (payload: {
  name: string
  description: string
  tags?: string[]
}) => {
  if (!activeTaskDetailId.value) return
  try {
    await workspacesStore.updateTaskDetails(
      props.workspaceId,
      props.itemId || props.item.id,
      activeTaskDetailId.value,
      payload,
    )
    showTaskDetail.value = false
    activeTaskDetailId.value = null
  } catch (err) {
    console.error('Failed to save task details:', err)
    // Keep the dialog open so the user can retry / fix
  }
}

// Unattended-mode toggle handler (edit mode only). Persists
// immediately via PUT /api/llm/session/<id> — the flag lives on
// the sessions table (task.id == session.id for routine tasks per
// the project convention), NOT on workspace_item_tasks. We do NOT
// close the dialog on toggle (it's an iOS-style immediate switch,
// not a Save-button commit). On PUT failure we log + show the
// error inline; the next SSE re-fetch will correct the toggle's
// visual state.
const handleUnattendedToggle = async (payload: { value: '0' | '1'; previous: '0' | '1' }) => {
  const taskId = activeTaskDetailId.value
  if (!taskId) return
  try {
    await apiUpdateSession(taskId, { isAutoRetryUntilStop: payload.value })
  } catch (err) {
    console.error('Failed to toggle unattended mode:', err)
    // On failure, the SSE re-fetch (or the dialog re-open via
    // activeTaskDetailId) will paint the correct server-truth
    // value into the toggle. We intentionally don't try to roll
    // back the toggle's local state from here — the dialog's
    // `unattended.value` is the source of truth while the dialog
    // is open, and the user can re-toggle if they want.
  }
}

// ─── Create-task dialog (kanban-add-task-via-detail-dialog — Chunk 1) ────
//
// When the user clicks "+ Add" on a kanban column, we open the SAME
// KanbanTaskDetailDialog in `mode="create"` (rather than the small
// AddTaskDialog the picker used to open). This unifies the create
// and edit flows — same form, same column metadata strip, same
// validation — and routes the new task to the column the user
// actually clicked (which the old flow silently dropped).
//
// Backend note: createTask doesn't accept a kanban_column_id yet
// (the backend auto-assigns to the first column at MAX+1). After
// the create returns, we call moveTaskToColumn to put the task in
// the user's chosen column at position 0 (top). The extra round
// trip is acceptable; the move is cheap.
//
// State:
//   - `activeCreateColumnId` — column the user clicked "+ Add" on.
//   - `showCreateDialog` — drives the dialog's open/closed state.
//   - `createBusy` — disables the Save button while the create +
//     move are in flight (the dialog itself doesn't have a busy
//     state; we surface in-flight via the Save button text).
//   - `createError` — bound to the dialog's `errorMessage` prop;
//     non-null on save failure so the dialog shows the red banner.
const activeCreateColumnId = ref<string | null>(null)
const showCreateDialog = ref(false)
const createBusy = ref(false)
const createError = ref<string | null>(null)

// Resolve the column object for the dialog's `column` prop. Returns
// null until/unless `activeCreateColumnId` is set; the column is
// looked up in the kanban's columns list which is already in scope.
const activeCreateColumn = computed<KanbanColumnType | null>(() => {
  if (!activeCreateColumnId.value) return null
  return (props.item.kanban_columns ?? []).find(
    (c) => c.id === activeCreateColumnId.value,
  ) ?? null
})

// Bound to <KanbanColumn>'s `@add-task`. Sets the target column +
// opens the create dialog. Resets any previous error so a fresh
// open doesn't carry over a stale banner.
const handleViewCreateTask = (columnId: string) => {
  activeCreateColumnId.value = columnId
  createError.value = null
  showCreateDialog.value = true
}

// Create-task submit handler. Called by the dialog's `@create` or
// `@create-and-run` emit. The mode discriminator drives the second
// half of the flow:
//   - 'create'           — today's behavior (create + move + close)
//   - 'create_and_run'   — also queues title + description as the
//                          first user message and starts the agent
//                          in the background. The user stays on the
//                          kanban view (no chat dialog opens); they
//                          can click the new task card to open the
//                          chat view any time.
//
// On error: keep the dialog open and surface the error message via
// the dialog's `errorMessage` prop (the user can retry without
// re-typing).
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
//   + 2026-08-06-kanban-no-base64-in-desc (pendingFiles upload step)
//   + 2026-08-06-no-need-go-chatview (do NOT navigate to chatview on
//     success path — keep the user on the kanban)
const handleCreateTaskSave = async (payload: {
  mode: 'create' | 'create_and_run'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  tags?: string[]
  // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty
  // string = backend default / "Default (top-level config)". Threaded
  // through to runAgentOnNewTask only (Path A — plain create doesn't
  // persist the choice; user can set from chatview later).
  selectedProfile?: string
  // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces
  // 2026-08-06-kanban-no-base64-in-desc). Files the dialog staged
  // in create mode (KanbanDescriptionEditor.pendingFiles). The editor
  // never writes the base64 payload into `description` — we
  // convert each file to a `data:<mime>;base64,...` URL here AFTER
  // `addTask` returns the new taskId, and pass the array as
  // `imageUrls` to runAgentOnNewTask when mode === 'create_and_run'.
  // The description stays plain text — no upload, no `![name](url)`
  // markdown. Simplification vs the older upload-then-URL flow:
  //   - no GET attachment endpoint hit (avoids the wildcard route bug)
  //   - no broken-image placeholder on the kanban card
  //   - chatview still renders thumbnails (from message.image_urls)
  // Empty array (not undefined) when no images were attached.
  pendingFiles?: PreviewFile[]
}) => {
  if (!activeCreateColumnId.value) return
  createBusy.value = true
  createError.value = null
  const wsId = props.workspaceId
  const itId = props.itemId || props.item.id
  const desiredColumnId = activeCreateColumnId.value
  try {
    const taskId = await workspacesStore.addTask(wsId, itId, {
      name: payload.name,
      description: payload.description,
      // Forward the unattended toggle's value from the create
      // dialog (Option A: backend atomically inserts a sessions
      // row + sets the flag when this is '1').
      isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
      // Migration 067 — forward tags from the dialog (the
      // KanbanTagsInput has already validated + deduped). The store
      // + api layer JSON-encode + send; backend persists.
      tags: payload.tags,
    })
    if (!taskId) {
      createError.value = 'Failed to create task — please retry.'
      return
    }

    // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces
    // 2026-08-06-kanban-no-base64-in-desc). Convert each pending file
    // the user pasted/picked while in create mode to a base64 data
    // URL via FileReader.readAsDataURL, collecting them in upload
    // order. We do NOT upload, we do NOT patch the description — the
    // description stays plain text, and the data URLs are forwarded
    // as imageUrls to runAgentOnNewTask below (create_and_run mode).
    // The chatview's user-message template (ChatView.vue:2062-2080)
    // renders them as clickable thumbnails above the text — same UX
    // as pasting an image directly into the chat input.
    //
    // Failure mode: if a FileReader throws (rare — disk/file
    // corruption), we abort the move / run flow and surface the error
    // via createError so the dialog stays open. The user can retry
    // without re-typing.
    const pendingFiles = payload.pendingFiles ?? []
    const fileToBase64 = (file: File): Promise<string> =>
      new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result as string)
        reader.onerror = reject
        reader.readAsDataURL(file)
      })
    let uploadedImageUrls: string[] = []
    if (pendingFiles.length > 0) {
      try {
        uploadedImageUrls = await Promise.all(
          pendingFiles.map((entry) => fileToBase64(entry.file)),
        )
      } catch (err) {
        console.error(
          '[handleCreateTaskSave] file-to-base64 conversion failed:',
          err,
        )
        createError.value = `Image conversion failed: ${
          err instanceof Error ? err.message : String(err)
        }`
        return
      }
    }

    // Move the new task to the column the user clicked. The
    // backend's auto-assign put it in the first column; moveTaskToColumn
    // overwrites that. Position 0 = top of the column.
    await workspacesStore.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)

    // NEW (plan: 2026-08-06-kanban-create-task-run-agent). When the
    // user clicked "Create task & run agent", queue the title +
    // description as the first user message and route to the chat
    // view. The queued message is `title + "\n\n" + description` when
    // description is non-empty, else just the title (Q1 = B, Q2 = 2b
    // from the brainstorm).
    if (payload.mode === 'create_and_run') {
      const queueMessage =
        payload.description.trim() !== ''
          ? `${payload.name}\n\n${payload.description}`
          : payload.name
      const result = await workspacesStore.runAgentOnNewTask(
        wsId,
        itId,
        taskId,
        {
          queueMessage,
          cwd: props.item.path || '',
          isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
          // NEW (plan: 2026-08-06-kanban-task-profile-selector).
          // Empty/undefined defaults to '' (= backend default).
          selectedProfile: payload.selectedProfile ?? '',
          // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview).
          // Base64 data URLs for the images the user pasted in the
          // create-mode description. The store forwards them to
          // api.sendChatMessage as image_urls (4th arg), and the
          // chatview renders them as clickable thumbnails above the
          // text content. Empty array when no images — the store
          // forwards it as-is (NOT coerced to undefined), which the
          // API contract accepts as "zero attachments". See
          // workspacesStoreRunAgentImageUrls.spec.ts for the wire.
          imageUrls: uploadedImageUrls,
        },
      )
      if (result?.status !== 'send') {
        // Partial success: task was created but the agent didn't
        // start. Surface a toast so the user knows to click the
        // card to retry manually. Never strand the user.
        //
        // NOTE (2026-08-06, "no need go chatview"): on the SUCCESS
        // path we deliberately do NOT emit `selectTask` — the user
        // asked to stay on the kanban view after clicking "Create
        // task & run agent" instead of being routed into the chat
        // dialog. The agent keeps running in the background; the
        // user can click the task card on the kanban any time to
        // open the chat view.
        useNotificationStore().notifyError(
          'Task created — agent did not start',
          'Click the card to retry, or check the nalar logs.',
        )
      }
    }

    showCreateDialog.value = false
    activeCreateColumnId.value = null
  } catch (err) {
    console.error('Failed to create kanban task:', err)
    createError.value = err instanceof Error ? err.message : String(err)
  } finally {
    createBusy.value = false
  }
}
</script>

<template>
  <section
    class="kanban-view flex flex-col h-full min-h-0"
    :data-kanban-item-id="item.id"
    :data-kanban-view="item.id"
    data-kanban-host
  >
    <!--
      Layout (kanban-chat-as-dialog plan, 2026-08-06): KanbanView now
      renders ONLY the full-width board. The chat task is mounted at
      AppLayout level as a centered modal dialog (KanbanChatDialog).
      When the user clicks a task, the kanban stays rendered and the
      dialog opens on top via Teleport — KanbanView is not unmounted,
      so the kanban's horizontal scroll position survives naturally.
    -->
    <!-- ─── Header ────────────────────────────────────────────────────── -->
    <header
      class="flex items-center gap-3 px-3 py-2 shrink-0"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <h3
        class="text-sm font-semibold truncate flex-1"
        style="color: var(--semantic-text);"
        :data-testid="`kanban-view-${item.id}-title`"
      >
        <InlineEditableText
          :value="item.name"
          :placeholder="'unnamed kanban'"
          :ariaLabel="'kanban name'"
          :testId="`kanban-view-${item.id}-rename`"
          display-class="text-sm font-semibold"
          @save="(newName) => emit('renameItem', newName)"
        />
      </h3>

      <!--
        "Set project root" banner — surfaces only when the kanban
        has `path = null` (i.e. it was created before the path field
        existed on the create endpoint). Without a path, every chat
        session in this kanban's tasks is cwd-less and git/file
        tools fail with "no such directory". The button opens the
        same FilePickerDialog used by AddKanbanDialog / AddItemDialog.

        Hidden once a path is set. The CSS uses `path ? null`-
        equivalent check via the explicit v-if (the API returns
        `path: null` for unset kanbans; we treat null AND undefined
        AND empty-string as "needs backfill" defensively).
      -->
      <button
        v-if="!item.path"
        type="button"
        @click="showPathPicker = true"
        :disabled="pathPickerBusy"
        class="shrink-0 px-2 py-1 rounded text-xs font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
        style="
          background-color: rgba(234, 179, 8, 0.18);
          color: rgb(202, 138, 4);
          border: 1px solid rgba(234, 179, 8, 0.4);
        "
        :data-testid="`kanban-view-${item.id}-set-project-root`"
        title="Set a project root so chat sessions have a working directory"
      >
        <span aria-hidden="true">⚠️</span>
        <span class="ml-1">{{ pathPickerBusy ? 'Setting…' : 'Set project root' }}</span>
      </button>
      <KanbanSearchInput v-model="searchQuery" />

      <button
        type="button"
        class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text-muted);
        "
        :data-testid="`kanban-view-${item.id}-open-settings`"
        @click="handleOpenSettings"
        title="Open board settings (add columns, edit descriptions)"
      >
        <span aria-hidden="true">⚙️</span>
        <span class="ml-1">Settings</span>
      </button>

    </header>

    <!--
      Search "no matches" banner (kanban task search, Chunk 6). Renders
      only when the backend returned an empty task list AND the user
      has a non-empty search query. Empty-string query is excluded so
      the banner doesn't appear on a freshly-opened empty board.
      Dismissed automatically when the search is cleared or any task
      matches.
    -->
    <div
      v-if="tasks.length === 0 && searchQuery.trim() !== ''"
      class="px-3 py-2 text-xs shrink-0"
      style="color: var(--semantic-text-dim);"
      :data-testid="`kanban-view-${item.id}-no-search-matches`"
    >
      No tasks match "{{ searchQuery }}"
    </div>

    <!-- ─── Columns row (horizontal scroll) ──────────────────────────── -->
    <!--
      Horizontal scroll position is persisted to localStorage so the
      kanban stays where the user scrolled it across the standalone
      <-> 3-column layout transition in AppLayout. See
      useKanbanScrollRestore composable + the comment block in the
      <script setup>. Do NOT remove `ref="kanbanColumnsContainer"`
      without also removing the composable call — the two are paired.
    -->
    <div
      ref="kanbanColumnsContainer"
      class="flex-1 min-h-0 overflow-x-auto overflow-y-hidden"
      style="
        scrollbar-width: thin;
      "
      :data-testid="`kanban-view-${item.id}-columns`"
    >
      <div class="flex gap-3 p-3 h-full items-stretch">
        <KanbanColumn
          v-for="column in sortedColumns"
          :key="column.id"
          :ref="setColumnRef(column.id)"
          :column="column"
          :tasks="tasks"
          :workspace-id="workspaceId"
          :item-id="itemId || item.id"
          :cwd="item.path || ''"
          @add-task="handleViewCreateTask"
          @move-task="(payload) => emit('moveTask', payload)"
          @rename-column="(payload) => emit('renameColumn', payload)"
          @delete-column="(columnId) => emit('deleteColumn', columnId)"
          @reorder-column="(payload) => emit('reorderColumn', payload)"
          @request-rename-column="(columnId) => emit('requestRenameColumn', columnId)"
          @request-delete-column="(columnId) => emit('requestDeleteColumn', columnId)"
          @select-task="(id) => emit('selectTask', id)"
          @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
          @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
          @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
          @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
          @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
          @view-task-detail="handleViewTaskDetail"
          @sort-change="(payload) => handleColumnSortChange(column.id, payload)"
        />
      </div>
    </div>
  </section>
<!--
    FilePickerDialog for the "Set project root" banner. Mounted at the
    bottom of the template so it sits in the same Teleport target as
    the rest of the kanban's modals. Same data source wiring as
    AddKanbanDialog's picker — kept duplicated (not extracted) to
    avoid coupling the two pickers.
  -->
  <FilePickerDialog
    v-model="showPathPicker"
    mode="folder"
    :load-items="loadItemsForPathPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="false"
    title="Select Project Root for this Kanban"
    @select="handleProjectRootSelected"
  />
  <!--
    KanbanTaskDetailDialog (kanban-task-detail-dialog feature). Mounted
    at the kanban level (not in AppLayout) because resolving the
    matching column for the active task needs the kanban's column list
    that's already in scope here. The dialog itself teleports its DOM
    to <body> internally; this mount only controls its v-model:show.
  -->
  <KanbanTaskDetailDialog
    v-model:show="showTaskDetail"
    :task="activeTaskDetail"
    :column="activeTaskDetailColumn"
    :cwd="item.path || ''"
    :workspace-id="workspaceId"
    @save="handleTaskDetailSave"
    @update-unattended="handleUnattendedToggle"
  />
  <!--
    Second KanbanTaskDetailDialog mount for the "+ Add" → create flow.
    Same component, mode="create" + task=null makes it render the
    blank form with a "New task" header and "Create task" button.
    errorMessage is bound to `createError` so a failed create shows
    a red banner inside the dialog (the dialog stays open so the user
    can retry without re-typing the name + description).
  -->
  <KanbanTaskDetailDialog
    v-model:show="showCreateDialog"
    mode="create"
    :task="null"
    :column="activeCreateColumn"
    :cwd="item.path || ''"
    :workspace-id="workspaceId"
    :error-message="createError"
    @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create' })"
    @create-and-run="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })"
  />
</template>

<style scoped>
/* Custom scrollbar styling for the horizontal column row.
   WebKit / Blink browsers (and the nalar Electron shell). */
.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar {
  height: 8px;
}

.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar-track {
  background: transparent;
}

.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 4px;
}

.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar-thumb:hover {
  background: var(--semantic-text-dim);
}
</style>
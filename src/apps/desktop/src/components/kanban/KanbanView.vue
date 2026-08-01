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
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import KanbanColumn from './KanbanColumn.vue'
import KanbanSearchInput from './KanbanSearchInput.vue'
import KanbanTaskDetailDialog from './KanbanTaskDetailDialog.vue'
import ChatView from '../views/ChatView.vue'
import InlineEditableText from '../preview/InlineEditableText.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { useKanbanScrollRestore } from '../../composables/useKanbanScrollRestore'
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

// Lazy-load the kanban's columns on mount + whenever the item id
// changes (e.g. user navigates from one kanban to another without
// unmounting the component). The workspaces/items endpoint does NOT
// embed columns — kanbans can have arbitrarily many and we want a
// lazy load (mirrors the folder-item `fetchFolderContents` pattern).
// Without this, the board renders empty on every page reload even
// though the seeded 3 default columns exist in the DB.
const effectiveItemId = computed(() => props.itemId || props.item.id)

// ─── Chat pane branch (kanban-embed-chatview plan, Task 2) ────────────
//
// When `activeTask` is set AND it belongs to this kanban, the kanban
// renders the chatview next to the board (replacing AppLayout's old
// 3-column branch — the kanban now owns the chat pane). The chat's
// `@close` event is forwarded as `@close-chat` so AppLayout can
// handle URL routing + state cleanup (URL stays source of truth).
const activeTask = computed(() => workspacesStore.activeTask)
const activeTaskWorkspaceItemId = computed(() => workspacesStore.activeTaskWorkspaceItemId)
const showChatPane = computed(
  () => !!(activeTask.value && activeTaskWorkspaceItemId.value === effectiveItemId.value),
)

// ─── Kanban column resize (kanban-embed-chatview plan, Task 3) ─────────
//
// Drag-resize the kanban column in the board+chat layout. The user
// grabs the 1px handle between the kanban and the chatview, drags
// left/right, and the kanban grows/shrinks within a clamped range.
// The chatview column absorbs the leftover space (it has
// `flex: 1 1 0`). The width persists to localStorage so a refresh
// keeps the user's preferred layout.
//
// Moved verbatim from AppLayout.vue:763-895 (kanban-embed-chatview
// plan, Task 3) — same UX, same storage key, just a different owner.
// The selector `[data-kanban-three-column] > :first-child` becomes
// `[data-kanban-with-chat] > :first-child` (the chat-pane branch's
// outer wrapper inside this component).
//
// Bounds rationale (preserved from AppLayout):
//   - MIN 0px: the user can collapse the kanban column entirely,
//     letting the chatview absorb the full main area. The 1px
//     resize handle stays grabbable at width=0 so the kanban can
//     be brought back by dragging right. (Floor was previously
//     280px to keep kanban columns readable; user feedback
//     2026-07-04 preferred unbounded.)
//   - MAX 720px: beyond this the chatview shrinks to <30% of the
//     main area on typical 1080p+ displays, making the chat feel
//     cramped. The chat needs at least 480px to be usable.
const KANBAN_MIN_WIDTH = 0
const KANBAN_MAX_WIDTH = 720
const KANBAN_DEFAULT_WIDTH = 40 // % of main area, used when no localStorage value exists
const KANBAN_WIDTH_STORAGE_KEY = 'kanban-column-width'

const loadKanbanColumnWidth = (): number | null => {
  if (typeof localStorage === 'undefined') return null
  const saved = localStorage.getItem(KANBAN_WIDTH_STORAGE_KEY)
  if (saved === null) return null
  const parsed = parseInt(saved, 10)
  if (isNaN(parsed) || parsed <= 0) return null
  return parsed
}

const kanbanColumnWidth = ref<number | null>(loadKanbanColumnWidth())
const isKanbanResizing = ref(false)
const kanbanResizeStartX = ref(0)
const kanbanResizeStartWidth = ref(0)

const startKanbanResize = (e: MouseEvent | TouchEvent) => {
  isKanbanResizing.value = true
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  kanbanResizeStartX.value = clientX
  const rendered = kanbanResizeStartWidth.value
  if (rendered <= 0) {
    const el = document.querySelector(
      '[data-kanban-with-chat] > :first-child',
    ) as HTMLElement | null
    kanbanResizeStartWidth.value = el?.getBoundingClientRect().width ?? 400
  }
  document.addEventListener('mousemove', handleKanbanResize)
  document.addEventListener('mouseup', stopKanbanResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'col-resize'
  e.preventDefault()
}

const handleKanbanResize = (e: MouseEvent | TouchEvent) => {
  if (!isKanbanResizing.value) return
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  const deltaX = clientX - kanbanResizeStartX.value
  const newWidth = Math.max(
    KANBAN_MIN_WIDTH,
    Math.min(KANBAN_MAX_WIDTH, kanbanResizeStartWidth.value + deltaX),
  )
  kanbanColumnWidth.value = newWidth
}

const stopKanbanResize = () => {
  if (!isKanbanResizing.value) return
  isKanbanResizing.value = false
  document.removeEventListener('mousemove', handleKanbanResize)
  document.removeEventListener('mouseup', stopKanbanResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
  if (kanbanColumnWidth.value !== null) {
    try {
      localStorage.setItem(KANBAN_WIDTH_STORAGE_KEY, String(kanbanColumnWidth.value))
    } catch {
      // localStorage may throw in private-mode or quota-exceeded
      // scenarios; silently ignore so the in-memory drag still
      // works for the current session.
    }
  }
}

const kanbanColumnStyle = computed(() => {
  if (kanbanColumnWidth.value !== null) {
    return {
      width: `${kanbanColumnWidth.value}px`,
      'min-width': `${KANBAN_MIN_WIDTH}px`,
      'max-width': `${KANBAN_MAX_WIDTH}px`,
      'flex-shrink': '0',
    }
  }
  return {
    flex: `0 1 ${KANBAN_DEFAULT_WIDTH}%`,
    'min-width': `${KANBAN_MIN_WIDTH}px`,
    'max-width': `${KANBAN_MAX_WIDTH}px`,
  }
})

// `close-chat` emit is added to the existing defineEmits() below
// (the script already has one). The chat-pane branch forwards
// ChatView's @close as @close-chat so AppLayout can clear the
// active task + navigate back to view=workspace.

const loadColumns = () => {
  if (props.workspaceId && effectiveItemId.value) {
    void workspacesStore.fetchKanbanColumns(props.workspaceId, effectiveItemId.value)
  }
}

onMounted(loadColumns)
watch(() => [props.workspaceId, effectiveItemId.value], loadColumns)

// ─── Horizontal scroll position preservation ──────────────────────────
//
// KanbanView is mounted in TWO separate v-else-if branches in
// AppLayout.vue: standalone (line ~1551) and 3-column
// (line ~1458 inside `data-kanban-three-column`). When the user
// clicks a task, the standalone mount is destroyed and a fresh
// KanbanView mounts inside the 3-column branch — Vue 3 does not
// reuse the component instance across v-else-if branches at
// different parents, so the new instance's `overflow-x-auto`
// columns row starts at scrollLeft = 0. That made the board jump
// back to the leftmost column every time a task was opened or
// closed, forcing the user to re-scroll to their column of
// interest (e.g. "merged" at the far right).
//
// The composable persists scrollLeft to localStorage on
// `scrollend` (fast path) + a 250 ms debounced `scroll` (fallback)
// and restores it on `onMounted` after two `requestAnimationFrame`
// ticks (so the columns have widths). Survives the standalone
// <-> 3-column transition in both directions.
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
import { getSystemFolder, listFolder, type FolderEntry, uploadTaskAttachment } from '../../api'
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
//                          first user message and routes to the chat
//                          view via the existing selectTask emit.
//
// On error: keep the dialog open and surface the error message via
// the dialog's `errorMessage` prop (the user can retry without
// re-typing).
//
// Plan: docs/superpowers/plans/2026-08-06-kanban-create-task-run-agent.md
//   + 2026-08-06-kanban-no-base64-in-desc (pendingFiles upload step)
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
  // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Files the
  // dialog staged in create mode (KanbanDescriptionEditor.pendingFiles).
  // The editor never writes the base64 payload into `description` —
  // we upload each file here AFTER `addTask` returns the new
  // taskId, then PATCH the description with `![name](<url>)` markdown.
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

    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Upload each
    // pending file the user pasted/picked while in create mode,
    // then patch the description with the server URLs. The
    // dialog's `description` was passed as text-only (no base64) —
    // we append the `![name](<url>)` markdown lines here so the
    // final description is self-contained.
    //
    // Failure mode: if the upload throws, we abort the move / run
    // flow (the task exists but with no description patch yet) and
    // surface the error via createError so the dialog stays open.
    // The user can retry without re-typing.
    const pendingFiles = payload.pendingFiles ?? []
    if (pendingFiles.length > 0) {
      const markdownLines: string[] = []
      for (const entry of pendingFiles) {
        try {
          const { url } = await uploadTaskAttachment(taskId, entry.file)
          markdownLines.push(`![${entry.file.name}](${url})`)
        } catch (err) {
          console.error(
            '[handleCreateTaskSave] attachment upload failed:',
            err,
          )
          createError.value = `Image upload failed (${entry.file.name}): ${
            err instanceof Error ? err.message : String(err)
          }`
          return
        }
      }
      const finalDescription =
        payload.description.trim() === ''
          ? markdownLines.join('\n')
          : `${payload.description}\n${markdownLines.join('\n')}`
      await workspacesStore.updateTaskDetails(wsId, itId, taskId, {
        description: finalDescription,
      })
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
        },
      )
      if (result?.status === 'send') {
        // Reuse the existing selectTask emit so the AppLayout ->
        // Sidebar chain handles setActiveTask + router.replace.
        // 'send' is the backend's status string for a successful
        // session create (see session_create.zig:115 — the worker
        // is given the queued message and will start processing).
        emit('selectTask', taskId)
      } else {
        // Partial success: task was created but the agent didn't
        // start. Surface a toast so the user knows to click the
        // card to retry manually. Never strand the user.
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
      Layout branches (kanban-embed-chatview plan, Task 2):
        - !showChatPane → full-width board (the old standalone layout)
        - showChatPane   → board on the left, ChatView on the right
                           (replaces AppLayout's old 3-column block).
      The two branches share the same header + columns-row markup;
      duplication is intentional for this first cut (relocation only,
      no redesign). A follow-up can extract a sub-component if the
      duplication grows.
    -->
    <template v-if="!showChatPane">
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
        />
      </div>
    </div>
    </template>

    <!--
      Active-task branch: board + chat side by side (kanban-embed-chatview
      plan, Task 2). Replaces the 3-column block that used to live in
      AppLayout.vue:1739-1825. Resize handle is added in Task 3.
    -->
    <div
      v-else
      class="flex-1 flex min-h-0"
      data-kanban-with-chat
    >
      <div
        class="flex flex-col h-full min-h-0"
        :style="kanbanColumnStyle"
        style="border-right: 1px solid var(--color-border)"
      >
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
          <KanbanSearchInput v-model="searchQuery" />
        </header>
        <div
          ref="kanbanColumnsContainer"
          class="flex-1 min-h-0 overflow-x-auto overflow-y-hidden"
          style="scrollbar-width: thin;"
          :data-testid="`kanban-view-${item.id}-columns`"
        >
          <div class="flex gap-3 p-3 h-full items-stretch">
            <KanbanColumn
              v-for="column in sortedColumns"
              :key="column.id"
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
            />
          </div>
        </div>
      </div>
      <!-- Resize handle (Task 3). 4px-wide hit area (w-2 in Tailwind) -->
      <div
        class="shrink-0 w-2 cursor-col-resize relative flex items-center justify-center bg-[var(--color-violet)]/15 hover:bg-[var(--color-violet)]/40 transition-colors"
        :class="isKanbanResizing ? '!bg-[var(--color-violet)]/60' : ''"
        data-kanban-resize-handle
        data-testid="kanban-resize-handle"
        title="Drag to resize"
        @mousedown="startKanbanResize"
      >
        <svg
          width="14"
          height="2"
          viewBox="0 0 14 2"
          fill="currentColor"
          class="text-[var(--color-violet)] opacity-70"
          aria-hidden="true"
        >
          <circle cx="3" cy="1" r="1" />
          <circle cx="7" cy="1" r="1" />
          <circle cx="11" cy="1" r="1" />
        </svg>
      </div>
      <div class="flex-1 flex flex-col h-full min-w-0 min-h-0">
        <ChatView
          v-if="activeTask"
          :key="'task-' + activeTask.id"
          :chat-id="activeTask.id"
          :chat-name="activeTask.name"
          :type="'task'"
          :cwd="item.path || ''"
          :task-id="activeTask.id"
          :task-name="activeTask.name"
          :project-name="item.name || ''"
          :show-header="true"
          @close="emit('closeChat')"
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
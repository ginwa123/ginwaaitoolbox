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
import { computed, onMounted, ref, watch } from 'vue'
import KanbanColumn from './KanbanColumn.vue'
import KanbanTaskDetailDialog from './KanbanTaskDetailDialog.vue'
import InlineEditableText from '../preview/InlineEditableText.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useKanbanScrollRestore } from '../../composables/useKanbanScrollRestore'
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

// Create-task submit handler. Called by the dialog's `@create` emit.
// On success: close the dialog + clear the target column. On error:
// keep the dialog open and surface the error message via the dialog's
// `errorMessage` prop (the user can retry without re-typing).
const handleCreateTaskSave = async (payload: {
  mode: 'create'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  tags?: string[]
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
    // Move the new task to the column the user clicked. The
    // backend's auto-assign put it in the first column; moveTaskToColumn
    // overwrites that. Position 0 = top of the column.
    await workspacesStore.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)
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
  >
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
    @create="handleCreateTaskSave"
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
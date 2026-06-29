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
      add-task      [{ columnId: string }]
      move-task     [{ taskId, columnId, position }]
      rename-column [{ columnId, name }]
      delete-column [columnId]
      reorder-column [{ columnId, targetColumnId }]
      // Pass-through from KanbanColumn:
      select-task, delete-task, rename-task, edit-routine,
      run-routine, pin-task
      request-rename-column, request-delete-column (host opens
      KanbanColumnEditor on these)

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
import InlineEditableText from './InlineEditableText.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'

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

const emit = defineEmits<{
  addColumn: []
  addTask: [{ columnId: string }]
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
import { getSystemFolder, listFolder, type FolderEntry } from '../api'
import FilePickerDialog from './FilePickerDialog.vue'

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
    <div
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
          @add-task="(columnId) => emit('addTask', { columnId })"
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
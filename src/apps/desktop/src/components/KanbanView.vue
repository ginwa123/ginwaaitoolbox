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
      // Pass-through from KanbanColumn:
      select-task, delete-task, rename-task, edit-routine,
      run-routine, pin-task
      request-rename-column, request-delete-column (host opens
      KanbanColumnEditor on these)
-->
<script setup lang="ts">
import { computed } from 'vue'
import KanbanColumn from './KanbanColumn.vue'
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

const emit = defineEmits<{
  addColumn: []
  addTask: [{ columnId: string }]
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
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
        {{ item.name }}
      </h3>
      <button
        type="button"
        class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity"
        style="
          background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
          color: var(--color-bg);
        "
        :data-testid="`kanban-view-${item.id}-add-column`"
        @click="handleAddColumn"
      >
        <span aria-hidden="true">+</span>
        <span class="ml-1">Column</span>
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
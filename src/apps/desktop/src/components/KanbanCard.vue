<!--
  KanbanCard — a single draggable card on a kanban column.

  Wraps the existing <WorkspaceItemTaskCard> with a draggable div
  that sets the kanban-specific MIME type on dragstart, so the
  <KanbanColumn> drop zone can read it back on drop and emit
  `move-task`. We deliberately use a dedicated MIME type
  (`application/x-kanban-task-id`) instead of `text/plain` so the
  payload doesn't collide with the sidebar's other drag handlers
  (item-reorder uses `application/x-item-id`, pinned-task-reorder
  uses `application/x-pinned-task-id`). See WorkspaceItem.vue:204
  and WorkspaceList.vue:336 for the same pattern.

  Why wrap rather than re-render: <WorkspaceItemTaskCard> already
  owns the per-task card UI (icon, name, action buttons, routine vs.
  standard branch, description preview, meta row). Re-rendering its
  internals would duplicate logic and diverge from the sidebar list
  view over time. The wrap approach keeps a single source of truth
  for the per-task row.

  Public API:
    props:  task (Task), workspaceId (string), itemId (string)
    emits:  dragstart (taskId), dragend ()
            — all events emitted by WorkspaceItemTaskCard are
              re-emitted verbatim to the host (KanbanColumn /
              KanbanView) so the kanban tree can route them to the
              store actions.

  Visual: A slight dim + slight tilt on drag for clear feedback
  (the source <KanbanColumn> also fades the source card via its
  own dim state if we choose to add that in the future).
-->
<script setup lang="ts">
import WorkspaceItemTaskCard from './WorkspaceItemTaskCard.vue'
import type { Task, WorkspaceItem } from '../stores/workspaces'

const props = defineProps<{
  task: Task
  workspaceId: string
  itemId: string
  // Optional: the parent WorkspaceItem (for forwarded events from
  // <WorkspaceItemTaskCard> that need the full item context —
  // currently unused, but accepted for forward compatibility if a
  // future routine-task action needs the item.path).
  item?: WorkspaceItem
}>()

const emit = defineEmits<{
  dragstart: [taskId: string]
  dragend: []
  // Pass-through events from <WorkspaceItemTaskCard>.
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
}>()

const handleDragStart = (event: DragEvent) => {
  // Set a dedicated MIME type so the drop handler in KanbanColumn can
  // read it back without colliding with the sidebar's other DnD
  // payloads. `effectAllowed = 'move'` gives the cursor the move-hint
  // arrow during drag.
  if (event.dataTransfer) {
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('application/x-kanban-task-id', props.task.id)
  }
  emit('dragstart', props.task.id)
}

const handleDragEnd = () => {
  emit('dragend')
}
</script>

<template>
  <div
    class="kanban-card"
    :data-task-id="task.id"
    :data-kanban-card="task.id"
    draggable="true"
    @dragstart="handleDragStart"
    @dragend="handleDragEnd"
  >
    <WorkspaceItemTaskCard
      :task="task"
      :workspace-id="workspaceId"
      :item-id="itemId"
      @select-task="(id) => emit('selectTask', id)"
      @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
      @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
      @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
      @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
      @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
    />
  </div>
</template>

<style scoped>
/* Subtle dim + tilt while dragging. The browser's native drag image
   is the source element's snapshot, so the source also keeps the
   original appearance — this style applies to the source element
   AFTER dragstart has fired (via the `:active` pseudo while the
   user is mid-drag). */
.kanban-card {
  cursor: grab;
}

.kanban-card:active {
  cursor: grabbing;
}

/* During drag, the browser inserts a transparent placeholder at
   the source's original position. We can fade the inner content via
   the standard HTML5 drag class (`[data-dragging="true"]` is set by
   the parent KanbanColumn on dragstart; see KanbanColumn.vue).
   No fade here directly — KanbanColumn sets `isDragging` on this
   row's `:style` binding for the unified visual feedback. */
</style>
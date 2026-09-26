<!--
  KanbanTaskRow — a single compact task row inside <KanbanRowView>.

  Row mode's per-task unit. It pairs the shared sidebar row
  (<WorkspaceItemTaskRow>, 32 px, same `useTaskActions` contract) with
  the kanban-only "open details" affordance, which the sidebar row does
  not have.

  Why a wrapper rather than a `variant` prop on <KanbanCard>:
  <KanbanCard> exists to pair the drag wrapper with the ~96 px
  <WorkspaceItemTaskCard>; adding a second child plus a height switch
  would make one component own two unrelated layouts. A small wrapper
  is cheaper to read and to test — the same argument DesignPageRow
  makes for not reusing WorkspaceItemTaskRow for design pages.

  Public API:
    props:  task (Task), workspaceId (string), itemId (string), cwd? (string)
    emits:  selectTask, openTaskInBackground, deleteTask, renameTask,
            pinTask, viewTaskDetail
-->
<script setup lang="ts">
import WorkspaceItemTaskRow from '../workspace/WorkspaceItemTaskRow.vue'
import type { Task } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    task: Task
    workspaceId: string
    itemId: string
    cwd?: string
  }>(),
  { cwd: '' },
)

const emit = defineEmits<{
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  viewTaskDetail: [taskId: string]
}>()
</script>

<template>
  <div class="group/kanban-row flex items-center gap-1" :data-kanban-row="props.task.id">
    <WorkspaceItemTaskRow
      :task="props.task"
      :workspace-id="props.workspaceId"
      :item-id="props.itemId"
      :cwd="props.cwd"
      @select-task="(id) => emit('selectTask', id)"
      @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
      @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
      @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
      @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
    />
    <!--
      "Open details" — the kanban-only affordance. Hidden until the row
      is hovered so the list stays quiet, but always focusable so
      keyboard users can reach it.
    -->
    <button
      type="button"
      class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/kanban-row:opacity-60 hover:opacity-100 focus-visible:opacity-100 transition-opacity"
      style="color: var(--semantic-text-dim)"
      :data-testid="`kanban-row-${props.task.id}-details`"
      title="Open task details"
      aria-label="Open task details"
      @click.stop="emit('viewTaskDetail', props.task.id)"
    >
      <span class="text-base leading-none" aria-hidden="true">⋯</span>
    </button>
  </div>
</template>

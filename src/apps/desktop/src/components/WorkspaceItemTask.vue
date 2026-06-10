<script setup lang="ts">
// Extracted from WorkspaceItem.vue on 2026-06-10. This component owns
// ONLY the per-task row inside the expanded workspace-item panel — the
// item row (chevron / name / hover buttons) and the expansion state
// stay in WorkspaceItem. Event payload is identical to the pre-split
// contract; WorkspaceItem re-emits these three events up to
// WorkspaceList unchanged.

import { inject, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Task } from '../stores/workspaces'

// Re-inject processingState from App.vue (same key as WorkspaceItem and
// ChatsList consume). Keyed by task.id == session_id. Reading it
// directly here — rather than threading it down as a prop from
// WorkspaceItem — keeps the contract identical to the other sidebar
// consumers and avoids prop drilling.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const workspacesStore = useWorkspacesStore()

const props = defineProps<{
  task: Task
  workspaceId: string
  itemId: string
}>()

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
}>()

const handleSelectTask = () => {
  emit('selectTask', props.task.id)
}

const handleDeleteTask = (event: Event) => {
  // Stop the click from bubbling up to the parent <button> (which
  // would call selectTask on the same task). Same rationale as the
  // rename handler below.
  event.stopPropagation()
  emit('deleteTask', props.workspaceId, props.itemId, props.task.id)
}

const handleRenameTask = (event: Event) => {
  // Stop the click from bubbling up to the parent <button>. See
  // handleDeleteTask for the full rationale.
  event.stopPropagation()
  emit('renameTask', props.workspaceId, props.itemId, props.task.id, props.task.name)
}
</script>

<template>
  <button
    class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
    :style="{
      color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
      backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
    }"
    @click="handleSelectTask"
  >
    <!-- Spinner while worker is processing this task (mirrors
         ChatsList.vue:489-497, scaled down to fit 12px text). Bullet
         is hidden while the spinner is shown so the row has a single,
         clear visual marker. -->
    <span
      v-if="processingState[task.id]"
      class="w-4 h-4 flex items-center justify-center shrink-0"
      data-testid="task-spinner"
    >
      <div
        class="w-3 h-3 border-2 rounded-full animate-spin"
        style="border-color: var(--color-yellow); border-top-color: transparent"
      ></div>
    </span>
    <!-- Bullet point (only when not processing) -->
    <span
      v-else
      class="w-1.5 h-1.5 rounded-full shrink-0"
      :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
    />
    <!-- Task name -->
    <span class="flex-1 truncate">{{ task.name }}</span>
    <!-- Rename task button (pencil). Hover-revealed alongside the
         delete button. Blue hover to differentiate from the red delete
         hover. -->
    <button
      @click="handleRenameTask($event)"
      class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-blue-400"
      style="color: var(--semantic-text-dim);"
      title="Rename Task"
    >
      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
      </svg>
    </button>
    <!-- Delete task button -->
    <button
      @click="handleDeleteTask($event)"
      class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-red-400"
      style="color: var(--semantic-text-dim);"
    >
      <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
      </svg>
    </button>
  </button>
</template>

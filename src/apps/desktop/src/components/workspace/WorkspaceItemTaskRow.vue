<!--
  WorkspaceItemTaskRow — the single-line compact per-task row used by
  the sidebar list inside <WorkspaceItem>.

  Split from <WorkspaceItemTask> on 2026-07-02. The card variant moved
  to <WorkspaceItemTaskCard> (kanban-only). This file owns ONLY the
  row layout — the legacy single-line flexbox that the sidebar has used
  since 2026-06-10.

  Behavior (event payload, routine branch, drop indicator, active
  styling, pin toggle, edit/run/delete hover buttons) is shared with
  the card via the `useTaskActions` composable. See that file for the
  contract.

  Public API:
    props:  task (Task), workspaceId (string), itemId (string),
            dropIndicator? ('above' | 'below' | null)
    emits:  selectTask, deleteTask, renameTask, editRoutine,
            runRoutine, pinTask  (same shapes as before)
-->
<script setup lang="ts">
// Extracted from WorkspaceItem.vue on 2026-06-10. This component owns
// ONLY the per-task row inside the expanded workspace-item panel —
// the item row (chevron / name / hover buttons) and the expansion
// state stay in WorkspaceItem. Event payload is identical to the
// pre-split contract; WorkspaceItem re-emits these events up to
// WorkspaceList unchanged.
//
// 2026-07-02: split the card variant out into
// WorkspaceItemTaskCard.vue. The shared logic (event handlers +
// routine computeds) now lives in composables/useTaskActions.ts.
import { inject, ref, computed, type Ref } from 'vue'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { useTaskActions, type TaskComponentProps } from '../../composables/useTaskActions'
import SessionSlider from '../SessionSlider.vue'

// Re-inject processingState from App.vue (same key WorkspaceItem and
// ChatsList consume). Keyed by task.id == session_id. Reading it
// directly here — rather than threading it down as a prop from
// WorkspaceItem — keeps the contract identical to the other sidebar
// consumers and avoids prop drilling.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const props = defineProps<TaskComponentProps>()

// URL-driven "what is the main content area showing?". Active styling
// for this task row derives from the URL
// (?view=workspace&itemId=Y/chat/task_X) rather than from
// workspacesStore.activeTaskId. The store flag is still mutated by
// AppLayout for view-routing (it must stay — removing it would break
// the kanban-side task navigation), but the visual "is this row
// active?" is now sourced from the URL so refresh / deep links /
// browser back / forward all keep the row's highlight consistent.
//
// SIMPLIFY-URL-BROWSER (2026-08-15): the legacy `kind: 'task'`
// variant has been dropped from useCurrentMainView. The chat-open
// state is encoded as `chatTaskId` on the `kind: 'workspace'`
// variant. The bare `itemId` field on workspace is what the parent
// workspace item row reads — we don't compare it here.
const currentMainView = useCurrentMainView()
const isActive = computed(() =>
  currentMainView.value.kind === 'workspace' &&
    currentMainView.value.chatTaskId === props.task.id,
)

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // (task-routines plan): emitted by the pencil on a routine task.
  // The parent opens EditRoutineDialog.
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  // Emitted by the Run Now button. The parent calls
  // workspacesStore.runRoutine(...) and routes to the chat view.
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  // (pinned-tasks feature): emitted by the pin/unpin button. Payload
  // carries the new is_pinned state so the store doesn't have to
  // re-read the task prop.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
}>()

// Shared logic — event handlers, routine computeds, drop indicator.
// See composables/useTaskActions.ts for the contract.
const {
  isRoutine,
  statusColor,
  statusClass,
  nextRunTooltip,
  dropIndicatorBoxShadow,
  handleSelectTask,
  handleDeleteTask,
  handleRenameTask,
  handleEditRoutine,
  handleRunRoutine,
  handlePinToggle,
} = useTaskActions(props, emit)
</script>

<template>
  <button
    class="relative flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
    :data-task-id="task.id"
    :data-drop-indicator="dropIndicator ?? undefined"
    data-task-row
    :style="{
      color: isActive ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
      backgroundColor: isActive ? 'var(--semantic-active-bg)' : 'transparent',
      boxShadow: dropIndicatorBoxShadow,
    }"
    @click="handleSelectTask"
  >
    <!-- ───── ROUTINE branch ───── -->
    <template v-if="isRoutine">
      <!-- (Processing spinner removed — replaced by SessionSlider at
           the bottom of the button. Visible iff processingState[task.id]
           === true; hidden otherwise. Self-positions absolutely.) -->
      <!-- Clock icon (with next-run tooltip). Always visible for
           routine rows — was v-else to the spinner (mutually
           exclusive), but with the spinner gone the clock always
           renders now. -->
      <span
        class="shrink-0"
        :title="nextRunTooltip"
        data-testid="routine-clock"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
      </span>
      <!-- Status dot (routine only). Tiny 6x6 dot reflects the
           routine's last_status. Shown in BOTH variants — it's a
           status indicator that adds information without taking
           much space. -->
      <span
        class="w-1.5 h-1.5 rounded-full shrink-0"
        :class="statusClass"
        :style="{ backgroundColor: statusColor }"
        data-testid="routine-status-dot"
      />
      <span class="flex-1 truncate">{{ task.name }}</span>
      <!-- Pin indicator (always visible when pinned). -->
      <span
        v-if="task.is_pinned"
        class="w-3 h-3 flex items-center justify-center shrink-0 text-yellow-400"
        title="Pinned"
        data-testid="task-pin-indicator"
      >
        <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
      </span>
      <!-- Pin/unpin toggle (hover-revealed). -->
      <button
        @click="handlePinToggle($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg]"
        :class="task.is_pinned ? 'text-yellow-400' : 'text-[--semantic-text-dim] hover:text-yellow-400'"
        :title="task.is_pinned ? 'Unpin task' : 'Pin task'"
        data-testid="task-pin-toggle"
      >
        <svg v-if="task.is_pinned" class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24">
          <path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
        <svg v-else class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
      </button>
      <!-- Pencil — for routine tasks this opens EditRoutineDialog -->
      <button
        @click="handleEditRoutine($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-blue-400"
        style="color: var(--semantic-text-dim);"
        title="Edit Routine"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
      <!-- Run Now play-icon button (between edit and delete) -->
      <button
        @click="handleRunRoutine($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-green-400"
        style="color: var(--semantic-text-dim);"
        title="Run now"
        data-testid="run-routine-btn"
      >
        <svg class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24">
          <path d="M8 5v14l11-7z" />
        </svg>
      </button>
      <!-- Delete task button (hover-revealed) -->
      <button
        @click="handleDeleteTask($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-red-400"
        style="color: var(--semantic-text-dim);"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </template>

    <!-- ───── STANDARD branch (existing behavior) ───── -->
    <template v-else>
      <!-- (Processing spinner removed — replaced by SessionSlider at
           the bottom of the button.) -->
      <!-- Row variant: bullet renders as before for the sidebar's
           compact list. Hidden while the LLM slider is visible so
           the row shows a SINGLE visual marker (either the bullet
           when idle, or the slider when processing) — same
           mutually-exclusive contract the old spinner/bullet pair
           had, just with the indicator relocated to the bottom of
           the row. -->
      <span
        v-if="!isRoutine && !processingState[task.id]"
        class="w-1.5 h-1.5 rounded-full shrink-0"
        :style="{ backgroundColor: isActive ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
      />
      <!-- Pin indicator (always visible when pinned). -->
      <span
        v-if="task.is_pinned"
        class="w-3 h-3 flex items-center justify-center shrink-0 text-yellow-400"
        title="Pinned"
        data-testid="task-pin-indicator"
      >
        <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
      </span>
      <span class="flex-1 truncate">{{ task.name }}</span>
      <!-- Pin/unpin toggle (hover-revealed). -->
      <button
        @click="handlePinToggle($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg]"
        :class="task.is_pinned ? 'text-yellow-400' : 'text-[--semantic-text-dim] hover:text-yellow-400'"
        :title="task.is_pinned ? 'Unpin task' : 'Pin task'"
        data-testid="task-pin-toggle"
      >
        <svg v-if="task.is_pinned" class="w-3.5 h-3.5" fill="currentColor" viewBox="0 0 24 24">
          <path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
        <svg v-else class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
      </button>
      <button
        @click="handleRenameTask($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-blue-400"
        style="color: var(--semantic-text-dim);"
        title="Rename Task"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
      <button
        @click="handleDeleteTask($event)"
        class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-red-400"
        style="color: var(--semantic-text-dim);"
      >
        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </template>

    <!-- Per-session LLM slider at the bottom edge of this row.
         Self-positions absolutely (the button has `relative`).
         Visible iff processingState[task.id] === true; hidden
         otherwise. Replaces the per-row yellow spinner circle that
         used to live in the leftmost slot (was lines 116-126 and
         214-223 in this file). Same signal as the workspace-item
         level slider in <WorkspaceItem> — the workspace-item
         level covers "any task on this item is busy"; this covers
         "this specific task is busy". Both can render at once. -->
    <SessionSlider :session-id="task.id" test-id="task-spinner" />
  </button>
</template>
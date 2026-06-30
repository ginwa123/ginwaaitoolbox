<script setup lang="ts">
// Extracted from WorkspaceItem.vue on 2026-06-10. This component owns
// ONLY the per-task row inside the expanded workspace-item panel — the
// item row (chevron / name / hover buttons) and the expansion state
// stay in WorkspaceItem. Event payload is identical to the pre-split
// contract; WorkspaceItem re-emits these three events up to
// WorkspaceList unchanged.
//
// Chunk 7 of task-routines: the row now branches on `task.task_type`.
// Standard tasks render the original bullet + rename/delete. Routine
// tasks render a clock icon, a status dot reflecting `last_status`,
// a "Run now" play-icon button on hover, and a tooltip with the next
// fire time. The pencil on a routine task emits `editRoutine` (not
// `renameTask`) so the parent opens EditRoutineDialog (which carries
// schedule + initial_prompt) instead of the simple RenameTaskModal.

import { inject, ref, computed, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Task, RoutineMeta } from '../stores/workspaces'

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

const props = withDefaults(defineProps<{
  task: Task
  workspaceId: string
  itemId: string
  // NEW (pinned-tasks feature): where to render the 2px yellow
  // drop indicator on this row. Set by the parent <WorkspaceItem>
  // while the user is dragging another pinned row over this one
  // — 'above' draws the line on the top edge (insert-before),
  // 'below' on the bottom edge (insert-after), null means no
  // indicator. The line is a 2px box-shadow so it doesn't affect
  // the row's layout (no margin/height shift between drag states).
  dropIndicator?: 'above' | 'below' | null
  // NEW (change-task-to-card-kanban plan): rendering variant.
  // 'row' (default) renders the legacy single-line compact row used
  // in the sidebar list. 'card' renders a bordered box with optional
  // description preview — used by <KanbanCard> inside kanban columns.
  // The default keeps the existing UX byte-identical for every
  // non-kanban call site (WorkspaceItem.vue:472, 491).
  variant?: 'row' | 'card'
}>(), {
  variant: 'row',
})

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // NEW (Chunk 7 of task-routines plan): emitted by the pencil
  // on a routine task. The parent opens EditRoutineDialog.
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  // NEW: emitted by the Run Now button. The parent calls
  // workspacesStore.runRoutine(...) and routes to the chat view.
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  // NEW (pinned-tasks feature): emitted by the pin/unpin button.
  // Payload carries the new is_pinned state so the store doesn't
  // have to re-read the task prop.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
}>()

// Convenience: is this task a routine? Defaults to false (the
// legacy behavior) for tasks with no `task_type` field.
const isRoutine = computed(
  () => props.task.task_type === 'routine' && props.task.routine !== undefined,
)

const statusColor = computed<string>(() => {
  if (!isRoutine.value) return 'transparent'
  const s = props.task.routine!.last_status
  if (s === 'success') return '#22c55e' // green-500
  if (s === 'failed') return '#ef4444'  // red-500
  if (s === 'running') return '#eab308' // yellow-500 (spinning via class)
  return '#9ca3af' // gray-400 — never fired
})

const statusClass = computed<string>(() => {
  if (!isRoutine.value) return ''
  return props.task.routine!.last_status === 'running' ? 'animate-spin' : ''
})

// Format the next-fire tooltip. The backend stores
// `next_run_at` as "YYYY-MM-DD HH:MM:SS" (UTC). The label is
// "Next: in 23 min (15:00)" — we compute the relative delta
// from `Date.now()` and the absolute HH:MM in UTC.
const nextRunTooltip = computed<string>(() => {
  if (!isRoutine.value) return ''
  const r: RoutineMeta = props.task.routine!
  // Parse "YYYY-MM-DD HH:MM:SS" as UTC. Use a single Date ctor.
  const next = new Date(r.next_run_at.replace(' ', 'T') + 'Z')
  if (Number.isNaN(next.getTime())) return `Next: ${r.next_run_at}`
  const ms = next.getTime() - Date.now()
  const hh = String(next.getUTCHours()).padStart(2, '0')
  const mm = String(next.getUTCMinutes()).padStart(2, '0')
  const time = `${hh}:${mm}`
  if (ms <= 0) return `Next: any moment (${time})`
  const mins = Math.round(ms / 60000)
  if (mins < 60) return `Next: in ${mins} min (${time})`
  const hours = Math.floor(mins / 60)
  const remMins = mins % 60
  if (hours < 24) return `Next: in ${hours} h ${remMins} min (${time})`
  const days = Math.floor(hours / 24)
  const remHours = hours % 24
  return `Next: in ${days} d ${remHours} h (${time})`
})

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

const handleEditRoutine = (event: Event) => {
  event.stopPropagation()
  emit('editRoutine', props.workspaceId, props.itemId, props.task.id)
}

const handleRunRoutine = (event: Event) => {
  event.stopPropagation()
  emit('runRoutine', props.workspaceId, props.itemId, props.task.id)
}

const handlePinToggle = (event: Event) => {
  // Stop the click from bubbling up to the parent <button> (which
  // would call selectTask on the same task). Same rationale as
  // the other action handlers above.
  event.stopPropagation()
  // Flip the local optimistic state — the store action will echo
  // the same flip, so the parent's `task.is_pinned` will be
  // updated to match. If the API call fails, the store rolls back
  // and our local state is overwritten on the next render.
  emit('pinTask', props.workspaceId, props.itemId, props.task.id, !props.task.is_pinned)
}

// NEW (pinned-tasks feature): compute the box-shadow for the row's
// drop indicator. Uses box-shadow (not border) so the visual cue
// doesn't shift the row's height between drag/no-drag states.
// 'above' -> 2px line on the top edge, 'below' -> 2px line on the
// bottom edge, null -> none.
const dropIndicatorBoxShadow = computed<string>(() => {
  if (props.dropIndicator === 'above') return 'inset 0 2px 0 0 #facc15' // yellow-400
  if (props.dropIndicator === 'below') return 'inset 0 -2px 0 0 #facc15'
  return 'none'
})

// NEW (change-task-to-card-kanban plan): outer container class for
// the root <button>. 'row' is the legacy compact single-line layout
// (byte-identical to today for sidebar consumers); 'card' is the
// kanban-column layout — bordered box with more padding, vertical
// stack, and hover-raised violet border. The border uses border-width
// 1px so the layout doesn't shift between hover and idle states.
const containerClass = computed<string>(() => {
  if (props.variant === 'card') {
    // flex-col + items-stretch so the description preview (rendered
    // below the top row via a sibling <p>) takes the full card width.
    // Hover lifts the border to violet + bumps the shadow; the border
    // stays 1px in both states so layout doesn't jitter.
    return 'flex flex-col gap-1 p-2.5 rounded-md text-xs group/task cursor-pointer transition-all duration-200 border shadow-sm hover:shadow-md bg-[--semantic-card-bg] border-[--color-border] hover:border-[--color-violet]'
  }
  // Legacy row layout — kept byte-identical so existing tests + the
  // sidebar consumer (WorkspaceItem.vue:472, 491) are unaffected.
  return 'flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200'
})
</script>

<template>
  <button
    :class="containerClass"
    :data-task-id="task.id"
    :data-drop-indicator="dropIndicator ?? undefined"
    :data-task-row="variant === 'row' ? '' : null"
    :data-task-card="variant === 'card' ? '' : null"
    :style="{
      color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : (variant === 'card' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)'),
      backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
      boxShadow: dropIndicatorBoxShadow,
    }"
    @click="handleSelectTask"
  >
    <!-- Top row (always rendered): icon/bullet + name + action icons.
         In card variant the outer flex is column, so we add an
         inner flex-row to keep the existing icon-name-actions layout.
         In row variant the outer flex is row, so the inner wrapper
         collapses — its `items-center gap-2` mirrors the legacy class. -->
    <div class="flex items-center gap-2 min-w-0">
    <!-- ───── ROUTINE branch ───── -->
    <template v-if="isRoutine">
      <!-- Spinner while worker is processing this task (mirrors ChatsList). -->
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
      <!-- Clock icon (with next-run tooltip) -->
      <span
        v-else
        class="w-4 h-4 flex items-center justify-center shrink-0"
        :title="nextRunTooltip"
        data-testid="routine-clock"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
      </span>
      <!-- Status dot (next to the name) -->
      <span
        class="w-1.5 h-1.5 rounded-full shrink-0"
        :class="statusClass"
        :style="{ backgroundColor: statusColor }"
        data-testid="routine-status-dot"
      />
      <!-- Pin indicator (always visible when pinned) -->
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
      <!-- Task name -->
      <span class="flex-1 truncate">{{ task.name }}</span>
      <!-- Pin/unpin toggle (show on hover) -->
      <button
        @click="handlePinToggle($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity"
        :class="task.is_pinned ? 'text-yellow-400' : 'text-[--semantic-text-dim] hover:text-yellow-400'"
        :title="task.is_pinned ? 'Unpin task' : 'Pin task'"
        data-testid="task-pin-toggle"
      >
        <svg v-if="task.is_pinned" class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
        <svg v-else class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
      </button>
      <!-- Pencil — for routine tasks this opens EditRoutineDialog -->
      <button
        @click="handleEditRoutine($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-blue-400"
        style="color: var(--semantic-text-dim);"
        title="Edit Routine"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
      </button>
      <!-- Run Now play-icon button (between rename and delete) -->
      <button
        @click="handleRunRoutine($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-green-400"
        style="color: var(--semantic-text-dim);"
        title="Run now"
        data-testid="run-routine-btn"
      >
        <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path d="M8 5v14l11-7z" />
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
    </template>

    <!-- ───── STANDARD branch (existing behavior) ───── -->
    <template v-else>
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
      <span
        v-else
        class="w-1.5 h-1.5 rounded-full shrink-0"
        :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
      />
      <!-- Pin indicator (always visible when pinned) -->
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
      <!-- Pin/unpin toggle (show on hover) -->
      <button
        @click="handlePinToggle($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity"
        :class="task.is_pinned ? 'text-yellow-400' : 'text-[--semantic-text-dim] hover:text-yellow-400'"
        :title="task.is_pinned ? 'Unpin task' : 'Pin task'"
        data-testid="task-pin-toggle"
      >
        <svg v-if="task.is_pinned" class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
        <svg v-else class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z" />
        </svg>
      </button>
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
      <button
        @click="handleDeleteTask($event)"
        class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-red-400"
        style="color: var(--semantic-text-dim);"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </template>
    </div>
    <!-- Description preview (NEW — change-task-to-card-kanban plan):
         Card variant only. Surfaces Task.description (already on the
         data model, never rendered before) below the icon-row inside
         the card. v-if gates BOTH conditions so empty/undefined
         descriptions produce zero padding (the column's space-y-1
         between cards handles the visual gap). Truncated with
         text-ellipsis; the full text is available via the card title
         tooltip in a future enhancement.
         data-testid locks in a stable selector for tests. -->
    <p
      v-if="variant === 'card' && task.description"
      class="text-[11px] leading-snug pl-5 pr-1 truncate"
      style="color: var(--semantic-text-dim);"
      data-testid="task-description"
    >
      {{ task.description }}
    </p>
  </button>
</template>

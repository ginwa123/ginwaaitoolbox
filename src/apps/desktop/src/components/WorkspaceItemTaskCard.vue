<!--
  WorkspaceItemTaskCard — the bordered card layout used by the kanban
  board inside <KanbanCard> → <KanbanColumn>.

  Split from <WorkspaceItemTask> on 2026-07-02. The row variant moved
  to <WorkspaceItemTaskRow> (sidebar list). This file owns the modern-
  minimalist kanban-card layout: a visible 1px gray border + card
  background + optional description preview, last-updated meta row,
  and a Jira-style left-edge type accent (violet for routine, blue
  for memory). Hover swaps the gray border for a violet ring.

  Behavior (event payload, routine branch, drop indicator, active
  styling, pin toggle, edit/run/delete hover buttons) is shared with
  the row via the `useTaskActions` composable. See that file for the
  contract.

  Public API:
    props:  task (Task), workspaceId (string), itemId (string),
            dropIndicator? ('above' | 'below' | null)
    emits:  selectTask, deleteTask, renameTask, editRoutine,
            runRoutine, pinTask  (same shapes as before)
-->
<script setup lang="ts">
// Extracted from WorkspaceItemTask.vue on 2026-07-02. The shared
// logic (event handlers + routine computeds) now lives in
// composables/useTaskActions.ts; this file owns ONLY the card
// layout and the card-specific computeds (description preview, meta
// row, Jira-style type accent).
import { inject, ref, computed, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { useTaskActions, type TaskComponentProps } from '../composables/useTaskActions'

// Re-inject processingState from App.vue (same key WorkspaceItem and
// ChatsList consume). Keyed by task.id == session_id.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const workspacesStore = useWorkspacesStore()

const props = defineProps<TaskComponentProps>()

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
}>()

// Shared logic — event handlers, routine computeds, drop indicator.
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

// (card-ux-v3 — Jira-style priority-bar pattern). A thin 3px colored
// stripe down the left edge of the card that reflects the task's
// type. Standard tasks get NO stripe (cleanest default); routine
// tasks get a violet stripe; memory tasks get a blue stripe.
// Implemented as an inset box-shadow so it doesn't affect the card's
// layout (no width change) and stacks naturally with the
// dropIndicator box-shadow.
//
// Returns a string suitable for use as the `boxShadow` CSS value,
// or `''` for the no-stripe case (the caller's `||` chain keeps
// the dropIndicator in place when the type stripe is absent).
function typeAccentShadow(): string {
  const t = props.task.task_type
  if (t === 'routine') return 'inset 3px 0 0 0 rgb(167, 139, 250)' // violet-400
  if (t === 'memory') return 'inset 3px 0 0 0 rgb(96, 165, 250)'   // blue-400
  return ''
}

// Combined box-shadow for the card. Layered values: type accent
// (Jira-style left stripe) + drop indicator (yellow line for
// pinned-region drag).
const cardBoxShadow = computed<string>(() => {
  const accent = typeAccentShadow()
  const drop = dropIndicatorBoxShadow.value
  if (accent && drop && drop !== 'none') return `${drop}, ${accent}`
  if (accent) return accent
  return drop
})

// Human-readable "time since" formatter for the meta row. Accepts:
//   - a JS Date instance
//   - an ISO datetime string (the most common backend wire format)
//   - a unix-ms number
// Returns '' for null/undefined inputs so the template can guard
// with v-if and avoid rendering an empty pill.
function formatRelativeTime(input: Date | string | number | null | undefined): string {
  if (input === null || input === undefined) return ''
  let d: Date
  if (input instanceof Date) {
    d = input
  } else if (typeof input === 'string') {
    // Tolerate the "YYYY-MM-DD HH:MM:SS" format the backend uses for
    // routine.next_run_at by replacing the space with 'T' and adding
    // an explicit 'Z' (UTC). For ISO strings ('...Z' / '...+00:00')
    // the Date ctor handles them natively.
    const normalized = input.includes('T') ? input : input.replace(' ', 'T')
    d = new Date(normalized.endsWith('Z') || /[+-]\d{2}:?\d{2}$/.test(normalized) ? normalized : normalized + 'Z')
  } else {
    d = new Date(input)
  }
  const ms = Date.now() - d.getTime()
  if (Number.isNaN(ms)) return ''
  const abs = Math.abs(ms)
  // Future timestamps render as "in X" — defensive; the canonical
  // input is `updatedAt` which should always be past. Future values
  // are still rendered consistently instead of throwing.
  const sign = ms < 0 ? '-' : ''
  if (abs < 45_000) return 'just now' // <45s rounds to "just now"
  const min = Math.floor(abs / 60_000)
  if (min < 60) return `${sign}${min}m ago`
  const hr = Math.floor(min / 60)
  if (hr < 24) return `${sign}${hr}h ago`
  const day = Math.floor(hr / 24)
  if (day === 1) return `${sign}yesterday`
  if (day < 7) return `${sign}${day}d ago`
  if (day < 30) return `${sign}${Math.floor(day / 7)}w ago`
  // Older than ~a month: show an absolute date so the user has a
  // stable reference. toLocaleDateString respects the browser's
  // locale; pinned to en-US short for the kanban (consistent across
  // teammates, no surprise formats like "5/7/26" vs "7 May").
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

// The most-recent update timestamp available. Falls back to
// `createdAt` when `updatedAt` is missing. Returns null when neither
// is present (older task fixtures), which the meta row uses to skip
// the time pill.
const lastUpdated = computed<Date | string | null>(() => {
  if (props.task.updatedAt) return props.task.updatedAt
  if (props.task.createdAt) return props.task.createdAt
  return null
})

// The rendered "X ago" string. Computed once per lastUpdated change
// so the card doesn't re-format on every re-render. Empty string
// when no timestamp is present.
const lastUpdatedLabel = computed<string>(() =>
  formatRelativeTime(lastUpdated.value),
)

// The user-facing task-type label shown in the meta row. Returns
// 'routine' for routine tasks, 'memory' for memory tasks, or null
// for plain standard tasks (no badge — the type is implied by the
// absence of a badge).
const typeBadge = computed<string | null>(() => {
  const t = props.task.task_type
  if (t === 'routine') return 'routine'
  if (t === 'memory') return 'memory'
  return null
})
</script>

<template>
  <button
    class="flex flex-col gap-2 p-3 rounded-lg text-xs group/task cursor-pointer transition-all duration-200 border border-[--color-border] hover:border-[--color-violet] bg-[--semantic-card-bg] shadow-sm hover:shadow-md"
    :data-task-id="task.id"
    :data-drop-indicator="dropIndicator ?? undefined"
    data-task-card
    :style="{
      color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text)',
      backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
      boxShadow: cardBoxShadow,
    }"
    @click="handleSelectTask"
  >
    <!-- Top row. A more modern, minimalist layout — title is the
         hero, icons are subtle. The bullet/dot is hidden in card
         variant (visual noise); only the routine clock, status dot,
         and pin indicator stay because they communicate information.
         The action icons (pin toggle, edit, run, delete) are all
         hover-revealed with a small subtle background pill on hover. -->
    <div class="flex items-center gap-2 min-w-0">
      <!-- ───── ROUTINE branch ───── -->
      <template v-if="isRoutine">
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
          class="shrink-0 text-[--color-violet]"
          :title="nextRunTooltip"
          data-testid="routine-clock"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
        </span>
        <!-- Status dot (routine only). Tiny 6x6 dot reflects the
             routine's last_status. card-ux-v2 keeps it visible in
             card variant too (a status indicator that adds
             information without taking much space). -->
        <span
          class="w-1.5 h-1.5 rounded-full shrink-0"
          :class="statusClass"
          :style="{ backgroundColor: statusColor }"
          data-testid="routine-status-dot"
        />
        <!-- Task name (THE HERO in card variant). Bigger, bolder,
             with a tighter line-height. -->
        <span
          class="flex-1 min-w-0 text-sm font-medium leading-snug truncate"
        >{{ task.name }}</span>
        <!-- Pin indicator (always visible when pinned). Moved to
             the right side of the name in card variant for a
             cleaner reading order: title first, status icons after. -->
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
        <!-- Pin/unpin toggle (hover-revealed, more subtle). -->
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

      <!-- ───── STANDARD branch ───── -->
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
        <!-- Card variant: bullet is HIDDEN (the card itself signals
             a task — the dot is visual noise in the modern-
             minimalist design). The v-else-if is mutually exclusive
             with the spinner above (never both at once). -->
        <!-- (intentionally no bullet span here in card variant) -->
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
        <span
          class="flex-1 min-w-0 text-sm font-medium leading-snug truncate"
        >{{ task.name }}</span>
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
    </div>
    <!-- Description preview. line-clamp-2 for a more minimalist
         feel, text-xs, leading-relaxed for better breathing room.
         Color uses --semantic-text-muted for a softer, less
         attention-grabbing tone. -->
    <p
      v-if="task.description"
      class="text-[11px] leading-relaxed pr-1 line-clamp-2"
      style="color: var(--semantic-text-muted);"
      data-testid="task-description"
    >
      {{ task.description }}
    </p>
    <!-- Meta row. Just the last-updated time + a single subtle type
         label when relevant. The row gets a hairline top border with
         extra top padding for clear visual separation. -->
    <div
      v-if="lastUpdatedLabel || typeBadge"
      class="flex items-center gap-1.5 pt-1 text-[10px] flex-wrap"
      style="color: var(--semantic-text-dim);"
      data-testid="task-meta"
    >
      <!-- Last-updated time pill. Single SVG clock icon + text.
           Renders only when lastUpdatedLabel is non-empty. -->
      <span
        v-if="lastUpdatedLabel"
        class="inline-flex items-center gap-1"
        data-testid="task-meta-updated"
        :title="typeof lastUpdated === 'string' ? lastUpdated : (lastUpdated instanceof Date ? lastUpdated.toISOString() : '')"
      >
        <svg class="w-3 h-3 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
        </svg>
        <span>{{ lastUpdatedLabel }}</span>
      </span>
      <!-- Task-type subtle label. Rendered as plain dim text (no
           colored pill background) for a more minimalist feel. The
           routine clock icon is already shown in the top row for
           routine tasks; the meta label is just a secondary text
           marker. -->
      <span
        v-if="typeBadge"
        class="inline-flex items-center gap-1"
        :data-testid="`task-meta-type-${typeBadge}`"
        :title="typeBadge === 'routine' ? 'Scheduled task' : 'Memory note'"
      >
        <span aria-hidden="true">·</span>
        <span>{{ typeBadge }}</span>
      </span>
    </div>
  </button>
</template>
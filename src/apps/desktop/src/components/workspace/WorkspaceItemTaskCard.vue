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
import { useWorkspacesStore } from '../../stores/workspaces'
import { useTaskActions, type TaskComponentProps } from '../../composables/useTaskActions'
import MarkdownDescription from '../kanban/MarkdownDescription.vue'

// Kanban task tags palette (Migration 067 — plan
// docs/superpowers/plans/2026-07-28-kanban-task-tags.md). Same 6
// colors as KanbanTagsInput.vue so the card chips and dialog
// chips share colors. djb2 hash of the lowercase tag selects
// the index deterministically.
const TAG_PALETTE = [
  { bg: 'rgba(139, 92, 246, 0.18)', border: 'rgba(139, 92, 246, 0.45)', text: '#a78bfa' },
  { bg: 'rgba(59, 130, 246, 0.18)', border: 'rgba(59, 130, 246, 0.45)', text: '#60a5fa' },
  { bg: 'rgba(34, 197, 94, 0.18)', border: 'rgba(34, 197, 94, 0.45)', text: '#4ade80' },
  { bg: 'rgba(245, 158, 11, 0.18)', border: 'rgba(245, 158, 11, 0.45)', text: '#fbbf24' },
  { bg: 'rgba(249, 115, 22, 0.18)', border: 'rgba(249, 115, 22, 0.45)', text: '#fb923c' },
  { bg: 'rgba(239, 68, 68, 0.18)', border: 'rgba(239, 68, 68, 0.45)', text: '#f87171' },
] as const

function tagChipStyle(tag: string): Record<string, string> {
  let hash = 5381
  for (const c of tag.toLowerCase()) {
    hash = ((hash << 5) + hash + c.charCodeAt(0)) >>> 0
  }
  const idx = hash % TAG_PALETTE.length
  const c = TAG_PALETTE[idx] ?? TAG_PALETTE[0]
  return {
    backgroundColor: c.bg,
    border: `1px solid ${c.border}`,
    color: c.text,
  }
}

// Re-inject processingState from App.vue (same key WorkspaceItem and
// ChatsList consume). Keyed by task.id == session_id.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const workspacesStore = useWorkspacesStore()

const props = withDefaults(defineProps<TaskComponentProps>(), {
  cwd: '',
})

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the full task-detail dialog (kanban-task-detail-dialog
  // feature). The host (KanbanView) opens the dialog locally with
  // the matching task — we only emit the id.
  viewTaskDetail: [taskId: string]
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

// Local-only handler — opens the per-task detail dialog. NOT in
// useTaskActions because that composable is shared with the row
// variant (sidebar list) which doesn't render the info button. CRITICAL:
// we must stopPropagation so the click doesn't also bubble up to the
// card-root <button>'s @click="handleSelectTask" — otherwise both the
// dialog AND the chat would open on the same click.
const handleViewTaskDetail = (event: MouseEvent) => {
  event.stopPropagation()
  event.preventDefault()
  emit('viewTaskDetail', props.task.id)
}

// (card-ux-v3 — Jira-style priority-bar pattern). A thin 3px colored
// stripe down the left edge of the card that reflects the task's
// type. Standard tasks get NO stripe (cleanest default); routine
// tasks get a violet stripe; memory tasks get a blue stripe.
// Implemented as an inset box-shadow so it doesn't affect the card's
// layout (no width change) and stacks naturally with the
// dropIndicator box-shadow and the v6 3D base shadow.
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

// (card-ux-v6) Replaces the v5 visible 1px border with a layered
// 3D box-shadow. Three layers compose the "card floating on the
// board" feel without a hard outline:
//
//   1. Outer drop shadow at idle   — soft 1+2px offset, dark rgba,
//      lifts the card off the column visually. Hover swaps to a
//      bigger 4+2px shadow with brighter bevel for a "picking
//      up the card" feel.
//   2. Inset 1px bevel highlight   — low-opacity white stroke that
//      simulates a beveled edge in dark mode. Visible without a
//      harsh line; without it the card looks flat against the
//      dark column.
//   3. (Composed in cardBoxShadow below) Type accent + dropIndicator
//      inset shadows sit on TOP of the 3D base to keep the Jira-style
//      left stripe and the pinned-region drag line working
//      unchanged.
//
// CSS box-shadow stacking: FIRST value drawn on top. Outer shadows
// come first (they're the dominant visual), inset accents last.
const baseCardShadow =
  '0 1px 3px 0 rgba(0, 0, 0, 0.5), ' +
  '0 1px 2px -1px rgba(0, 0, 0, 0.4), ' +
  'inset 0 0 0 1px rgba(255, 255, 255, 0.06)'

const hoverCardShadow =
  '0 4px 6px -1px rgba(0, 0, 0, 0.55), ' +
  '0 2px 4px -2px rgba(0, 0, 0, 0.4), ' +
  'inset 0 0 0 1px rgba(255, 255, 255, 0.1)'

// Local hover state — drives the shadow transition. Pure UX, no
// business logic.
const isHovered = ref(false)

// Combined box-shadow for the card. Layered values, in CSS stacking
// order (first on top): 3D base + Jira-style type accent (left
// stripe) + yellow drop indicator (pinned-region drag).
//
// On hover the 3D base swaps to its hover variant; transition-shadow
// in the template class animates the swap smoothly.
const cardBoxShadow = computed<string>(() => {
  const accent = typeAccentShadow()
  const drop = dropIndicatorBoxShadow.value
  const base = isHovered.value ? hoverCardShadow : baseCardShadow
  const layers: string[] = [base]
  if (accent) layers.push(accent)
  if (drop && drop !== 'none') layers.push(drop)
  return layers.join(', ')
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

// Visible tags for the chip row (Migration 067). Caps at 3 to
// keep the card compact; the "+N more" affordance covers the rest.
// `task.tags` is `[]` for tasks without tags — the v-if on the
// tags row in the template handles the "no tags" case.
const VISIBLE_TAGS_MAX = 3
const visibleTags = computed<string[]>(() => {
  const tags = props.task.tags ?? []
  return tags.slice(0, VISIBLE_TAGS_MAX)
})
const extraTagsCount = computed<number>(() => {
  const tags = props.task.tags ?? []
  return Math.max(0, tags.length - VISIBLE_TAGS_MAX)
})

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

// Git-branch badge (plan:
//   docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
// Returns the branch name to display, or null when:
//   - the task has no git_branch field (undefined / null)
//   - the backend returned an empty string (not a git repo, detached
//     HEAD, spawn failure)
// Null results in NO badge rendered (graceful no-op for non-git
// workspaces / tasks without worktree + non-git cwd).
const gitBranchBadge = computed<string | null>(() => {
  const b = props.task.git_branch
  if (typeof b !== 'string') return null
  if (b.length === 0) return null
  return b
})
</script>

<template>
  <button
    class="flex flex-col gap-2 p-3 w-full rounded-lg text-xs group/task cursor-pointer transition-shadow duration-200"
    :data-task-id="task.id"
    :data-drop-indicator="dropIndicator ?? undefined"
    data-task-card
    :style="{
      color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text)',
      backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'var(--semantic-card-bg)',
      boxShadow: cardBoxShadow,
    }"
    @click="handleSelectTask"
    @mouseenter="isHovered = true"
    @mouseleave="isHovered = false"
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
        <!-- Info / view detail button (hover-revealed). Opens the
             KanbanTaskDetailDialog via the host (KanbanView). -->
        <button
          @click="handleViewTaskDetail($event)"
          class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-cyan-400"
          style="color: var(--semantic-text-dim);"
          title="View task details"
          data-testid="view-task-detail-btn"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
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
        <!-- Kanban notification icon (Chunk 6 of
             docs/plans/2026-07-26-kanban-task-notification-icon.md).
             8px orange-400 dot with a 4-pulse glow when the AI has
             finished a turn (finish_reason=stop) and the user
             hasn't engaged with the task since. Rendered AFTER
             the spinner slot (so v-if precedence: spinner wins
             when the worker is active, even mid-repaint during a
             state transition) and BEFORE the pin indicator (so
             the reading order is "current activity → awaiting
             review → pinned state → name"). Tooltip explains the
             state for screen-reader / hover users.

             The pulse keyframe lives in the scoped <style> block
             below — see `needs-review-pulse`. animation-iteration-
             count: 4 means the dot pulses 4 times then settles to
             a steady glow; iteration-fill-mode: forwards keeps the
             final 0% state (steady, no glow) so the user has a
             consistent "always visible" affordance. -->
        <span
          v-else-if="task.needs_human_review && task.last_finish_reason === 'stop'"
          class="w-2 h-2 rounded-full shrink-0"
          style="background-color: rgb(251, 146, 60); box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6); animation: needs-review-pulse 2.4s ease-out 4 forwards;"
          title="AI finished — awaiting your review"
          data-testid="task-needs-review"
        />
        <!-- Kanban notification icon (Chunk 6) — green "reviewed"
             checkmark. Shown when last_finish_reason='stop' AND
             needs_human_review=false (i.e. user has touched the
             task since the AI finished). Defensive: we also gate
             on last_finish_reason==='stop' so a stale
             needs_human_review=false + finish_reason='tool_calls'
             state doesn't paint a phantom "reviewed" checkmark
             during a session-status flip. -->
        <span
          v-else-if="task.last_finish_reason === 'stop'"
          class="shrink-0 text-green-500"
          title="Reviewed"
          data-testid="task-reviewed"
        >
          <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2.5">
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
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
        <!-- Info / view detail button (hover-revealed). Opens the
             KanbanTaskDetailDialog via the host (KanbanView). -->
        <button
          @click="handleViewTaskDetail($event)"
          class="shrink-0 w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:bg-[--semantic-active-bg] hover:text-cyan-400"
          style="color: var(--semantic-text-dim);"
          title="View task details"
          data-testid="view-task-detail-btn"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
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
    <!-- Description preview. Renders the markdown via <MarkdownDescription>
         (which handles bold/italic/headings/images/@path chips). The
         container caps the height at ~3rem + line-clamp-2 so long
         descriptions don't bloat the card. The `w-full text-left` pair
         is preserved from the previous plain-text version to keep the
         description left-aligned within the flex-col parent (line-clamp
         display quirk). -->
    <div
      v-if="task.description"
      class="text-[11px] leading-relaxed pr-1 w-full text-left line-clamp-2"
      style="color: var(--semantic-text-muted); max-height: 3rem; overflow: hidden;"
      data-testid="task-description"
    >
      <MarkdownDescription
        :source="task.description"
        :cwd="cwd"
        max-height="3rem"
        :test-id="`task-description-rendered`"
      />
    </div>
    <!-- Tags row (Migration 067 — kanban task tags feature).
         Up to 3 chips visible; "+N more" link if more (opens the
         detail dialog). Same djb2-hash 6-color palette as the
         KanbanTagsInput component so the card chips and dialog
         chips share colors. -->
    <div
      v-if="task.tags && task.tags.length > 0"
      class="flex items-center gap-1 flex-wrap self-start w-full mt-1"
      data-testid="task-tags-row"
    >
      <span
        v-for="(tag, idx) in visibleTags"
        :key="`${tag}-${idx}`"
        class="inline-flex items-center text-[10px] px-1.5 py-0.5 rounded font-medium"
        :style="tagChipStyle(tag)"
        :data-testid="`task-tag-chip-${tag}`"
      >
        {{ tag }}
      </span>
      <button
        v-if="extraTagsCount > 0"
        type="button"
        class="text-[10px] underline"
        style="color: var(--semantic-text-dim);"
        @click.stop="emit('viewTaskDetail', task.id)"
        :data-testid="`task-tags-more`"
      >
        +{{ extraTagsCount }} more
      </button>
    </div>
    <!-- Meta row. Just the last-updated time + a single subtle type
         label when relevant. The row gets a hairline top border with
         extra top padding for clear visual separation. `self-start`
         keeps the row pinned to the left edge if a future flex parent
         defaults to centered alignment. -->
    <div
      v-if="lastUpdatedLabel || typeBadge || gitBranchBadge"
      class="flex items-center gap-1.5 pt-1 text-[10px] flex-wrap self-start w-full"
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
      <!-- Git-branch badge (plan:
           docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
           Shows the task's current git branch (worktree branch when
           bound, else the workspace's current branch). Backend
           computes via `git -C <cwd> symbolic-ref --short HEAD` per
           request; null when cwd is not a git repo or HEAD is
           detached. GitHub-style fork/branch SVG icon (12px) +
           branch name, truncated for long names. Tooltip shows the
           full branch name on hover. -->
      <span
        v-if="gitBranchBadge"
        class="inline-flex items-center gap-1 max-w-[8rem] truncate"
        :title="gitBranchBadge"
        data-testid="task-git-branch"
      >
        <svg
          class="w-3 h-3 shrink-0"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
          />
        </svg>
        <span class="truncate">{{ gitBranchBadge }}</span>
      </span>
    </div>
  </button>
</template>

<style scoped>
/* Chunk 6 of kanban-task-notification-icon: orange "awaiting review"
   dot pulse. 4 short pulses (~10s total) when the icon first
   appears, then settles to a steady orange dot. Each cycle:
     - 0%:   box-shadow radius 0px,   opacity 0.6 (steady, ready)
     - 70%:  box-shadow radius 12px,  opacity 0 (ripple dissipates)
   The animation: shorthand on the element pairs:
     animation-iteration-count: 4     (4 pulses then stop)
     animation-fill-mode: forwards    (keep the final 0% state
                                       so the user has a consistent
                                       "always visible" affordance
                                       afterwards — no glow, just
                                       the steady dot)
     animation-timing-function: ease-out  (ripple starts fast,
                                          dissipates slowly —
                                          organic, not mechanical)
*/
@keyframes needs-review-pulse {
  0% {
    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
  }
  70% {
    box-shadow: 0 0 0 12px rgba(251, 146, 60, 0);
  }
  100% {
    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0);
  }
}
</style>
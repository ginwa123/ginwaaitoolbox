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

// NEW (card-ux-v2): convenience flag for the template. Caches
// `props.variant === 'card'` so the template doesn't repeat the
// comparison 6+ times. Pure computed — no behavior change.
const isCardVariant = computed(() => props.variant === 'card')

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
// modern-minimalist kanban-card layout — generous padding, soft
// border, subtle hover lift. Updated in card-ux-v2:
//   - p-3 (was p-2.5) — more breathing room
//   - gap-2.5 (was gap-1.5) — more vertical rhythm
//   - border stays 1px (no layout shift on hover); opacity-60 softens it
//   - shadow-sm idle + shadow-md on hover for a refined lift
//   - rounded-md (slightly more rounded for a softer feel)
const containerClass = computed<string>(() => {
  if (props.variant === 'card') {
    return 'flex flex-col gap-2.5 p-3 rounded-lg text-xs group/task cursor-pointer transition-all duration-200 border shadow-sm hover:shadow-md bg-[--semantic-card-bg] border-[--color-border] hover:border-[--color-violet]'
  }
  // Legacy row layout — kept byte-identical so existing tests + the
  // sidebar consumer (WorkspaceItem.vue:472, 491) are unaffected.
  return 'flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200'
})

// NEW (card-ux-v2 plan): human-readable "time since" formatter for
// the meta row. Mirrors the `nextRunTooltip` formatter in style but
// in the opposite direction ("X ago" vs "in X"). Accepts:
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

// NEW (card-ux-v2 plan): the most-recent update timestamp available.
// The Task interface has `updatedAt?: Date` (ISO string from the
// backend, parsed by callers — see llm_history.zig / api/index.ts).
// Falls back to `createdAt` when `updatedAt` is missing. Returns
// null when neither is present (older task fixtures), which the
// meta row uses to skip the time pill.
const lastUpdated = computed<Date | string | null>(() => {
  if (props.task.updatedAt) return props.task.updatedAt
  if (props.task.createdAt) return props.task.createdAt
  return null
})

// NEW (card-ux-v2 plan): the rendered "X ago" string. Computed once
// per lastUpdated change so the card doesn't re-format on every
// re-render. Empty string when no timestamp is present (the meta
// row's v-if gates the pill on truthy values).
const lastUpdatedLabel = computed<string>(() =>
  formatRelativeTime(lastUpdated.value),
)

// NEW (card-ux-v2 plan): the user-facing task-type label shown in
// the meta row. Returns 'routine' for routine tasks, 'memory' for
// memory tasks, or null for plain standard tasks (no badge — the
// type is implied by the absence of a badge). The Task interface
// in stores/workspaces.ts declares the union 'standard' | 'routine'
// | 'memory'; we treat 'standard' (and missing/undefined) as null.
const typeBadge = computed<string | null>(() => {
  const t = props.task.task_type
  if (t === 'routine') return 'routine'
  if (t === 'memory') return 'memory'
  return null
})

// NEW (card-ux-v2 plan): does this card have any meta content
// (updated-time, pin, or type badge)? Gates the meta row's <div>
// so cards with no meta don't render an empty row + divider.
const hasMeta = computed<boolean>(() =>
  Boolean(
    lastUpdatedLabel.value ||
      props.task.is_pinned ||
      typeBadge.value !== null,
  ),
)
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
    <!-- Top row (always rendered). card-ux-v2: a more modern,
         minimalist layout — title is the hero, icons are subtle.
         In card variant the bullet/dot is hidden (visual noise);
         only the routine clock, status dot, and pin indicator stay
         because they communicate information. The action icons
         (pin toggle, edit, run, delete) are all hover-revealed with
         a small subtle background pill on hover for a more refined
         affordance. In row variant the entire block falls through
         to the legacy single-line layout (the inner wrapper's
         flex-row collapses cleanly when the outer container is
         also row-flex). -->
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
        <!-- Clock icon (with next-run tooltip). Mutually exclusive
             with the spinner above (v-else) — when the worker is
             processing this task, only the spinner renders. In
             card variant we tint the clock violet for a touch of
             accent color. -->
        <span
          v-else
          class="shrink-0"
          :class="isCardVariant ? 'text-[--color-violet]' : ''"
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
             much space. card-ux-v2 keeps it visible (the previous
             draft hid it in card variant, which broke the
             workspaceItemTaskRoutine tests that expect the dot
             in the default row variant; the dot now renders
             uniformly across variants). -->
        <span
          class="w-1.5 h-1.5 rounded-full shrink-0"
          :class="statusClass"
          :style="{ backgroundColor: statusColor }"
          data-testid="routine-status-dot"
        />
        <!-- Task name (THE HERO in card variant). Bigger, bolder,
             with a tighter line-height. The class branches on
             variant so the row variant keeps its existing text-xs
             (no layout shift) and the card variant gets a more
             readable text-sm + font-medium treatment. -->
        <span
          :class="isCardVariant
            ? 'flex-1 min-w-0 text-sm font-medium leading-snug truncate'
            : 'flex-1 truncate'"
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
        <!-- Pin/unpin toggle (hover-revealed, more subtle). card-ux-v2
             adds a soft background pill on hover for a more refined
             affordance. Still opacity-0 by default (so the card
             reads clean) but the background fades in alongside the
             icon. -->
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
        <!-- card-ux-v2: in CARD variant the bullet dot is HIDDEN
             (the card itself signals a task — the dot is visual
             noise in the modern-minimalist design). In ROW variant
             the bullet renders as before for the sidebar's
             compact list. Uses v-else-if so it's mutually exclusive
             with the spinner above (never both at once). -->
        <span
          v-else-if="!isCardVariant"
          class="w-1.5 h-1.5 rounded-full shrink-0"
          :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
        />
        <!-- Pin indicator (always visible when pinned). card-ux-v2:
             moved to the right of the name in card variant for
             better reading order; kept on the left in row variant
             to preserve the existing compact layout. -->
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
          :class="isCardVariant
            ? 'flex-1 min-w-0 text-sm font-medium leading-snug truncate'
            : 'flex-1 truncate'"
        >{{ task.name }}</span>
        <!-- Pin/unpin toggle (hover-revealed). card-ux-v2: 6x6
             pill button with subtle background-on-hover for a more
             refined affordance. -->
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
    <!-- Description preview (card variant only). card-ux-v2:
         modernized — line-clamp-2 (was 3 — 2 lines is more
         minimal), text-xs (was 12px), leading-relaxed for better
         breathing room, no left-indent so it reads as a card body.
         Color uses --semantic-text-muted for a softer, less
         attention-grabbing tone. The text-[10px] description in
         card variant (was 12px) matches the meta row's size for a
         consistent "small text" zone. -->
    <p
      v-if="isCardVariant && task.description"
      class="text-[11px] leading-relaxed pr-1 line-clamp-2"
      style="color: var(--semantic-text-muted);"
      data-testid="task-description"
    >
      {{ task.description }}
    </p>
    <!-- Meta row (card-ux-v2 modernized). Just the last-updated
         time + a single subtle pin/loop indicator when relevant.
         The 3-pill layout (time + pinned + type badge) is too busy
         for modern-minimalist — we now render the time as the
         only persistent element, with the pin/type shown only when
         the card has a non-standard type (routine clock already
         shows in the top row, so we skip the meta-row duplicate).
         The row gets a hairline top border with extra top padding
         for clear visual separation. -->
    <div
      v-if="isCardVariant && (lastUpdatedLabel || typeBadge)"
      class="flex items-center gap-1.5 pt-2 mt-0.5 text-[10px] flex-wrap"
      style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim);"
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
      <!-- Task-type subtle label. card-ux-v2: rendered as plain
           dim text (no colored pill background) for a more
           minimalist feel. The routine clock icon is already
           shown in the top row for routine tasks; the meta label
           is just a secondary text marker. -->
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

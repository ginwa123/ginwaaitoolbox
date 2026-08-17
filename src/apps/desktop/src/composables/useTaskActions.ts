/**
 * useTaskActions — shared logic for the per-task row / card components.
 *
 * Extracted from <WorkspaceItemTask> on 2026-07-02 when the single-file
 * variant prop was split into two thin presentation components
 * (WorkspaceItemTaskRow.vue for the sidebar list, WorkspaceItemTaskCard
 * .vue for the kanban card). The components now share this composable
 * for:
 *
 *   - The six event handlers (select / delete / rename / edit-routine /
 *     run / pin). The handlers emit the same payload shape the parent
 *     (<WorkspaceItem> and <KanbanCard>) re-emits verbatim — see
 *     docs/plans/2026-07-01-change-task-to-card-kanban.md.
 *   - The routine-specific computeds (isRoutine, statusColor,
 *     statusClass, nextRunTooltip) that decorate both the sidebar row
 *     and the kanban card identically.
 *   - The drop-indicator box-shadow so pinned-region drag visuals work
 *     in both views.
 *
 * The composable does NOT own:
 *   - Layout / template — that's the caller's job (row vs card).
 *   - Active-task styling (color/backgroundColor) — the parent
 *     component reads workspacesStore.activeTaskId directly via
 *     :style on its root button.
 *   - Card-only computeds (description, meta row, type-accent) — those
 *     are private to WorkspaceItemTaskCard.vue.
 */
import { computed, inject, ref, type Ref } from 'vue'
import type { Task, RoutineMeta } from '../stores/workspaces'

/** Common props every per-task component accepts. */
export interface TaskComponentProps {
  task: Task
  workspaceId: string
  itemId: string
  /**
   * Where to render the 2px yellow drop indicator on this row/card.
   * Set by the parent <WorkspaceItem> while the user is dragging
   * another pinned row over this one — 'above' draws the line on the
   * top edge (insert-before), 'below' on the bottom edge (insert-after),
   * null means no indicator.
   */
  dropIndicator?: 'above' | 'below' | null
  /**
   * Absolute path used as the root for `@`-trigger file pickers in
   * descendant editors / markdown renderers. Optional — task-list
   * callers in <WorkspaceItem> don't pass it (no kanban context). The
   * kanban column passes it through so `@/path` references in the
   * card's description resolve against the kanban's filesystem path.
   */
  cwd?: string
}

/**
 * Loose emit signature — accepts any `defineEmits` return value.
 *
 * Vue's `defineEmits` returns a UNION of function overloads (one per
 * event name) whose first parameter is a literal string, e.g.
 * `((evt: "deleteTask", ws: string, item: string, id: string) => void)
 *  & ((evt: "renameTask", ws: string, item: string, id: string, name: string) => void)
 *  & ...`. Passing that union to a function expecting a single
 * signature `(event: string, ...args: any[]) => void` triggers a
 * TS2345 ("string is not assignable to 'deleteTask'") error because
 * the overload's first parameter is narrower than `string`.
 *
 * Using `any` on both the event name AND the args keeps the composable
 * callable from any defineEmits-style emit without casts at the call
 * site. The handlers inside the composable still pass typed args to
 * `emit(...)`, so the contract is preserved end-to-end.
 */
 
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
export type EmitFn = (event: any, ...args: any[]) => void

/** Surface returned by the composable. */
export interface UseTaskActionsReturn {
  // Reactive state read by the template.
  isRoutine: Ref<boolean>
  statusColor: Ref<string>
  statusClass: Ref<string>
  nextRunTooltip: Ref<string>
  dropIndicatorBoxShadow: Ref<string>

  // Event handlers — call from `@click` etc. The handler stops the
  // event's propagation so a click on a nested action button does not
  // also fire `selectTask` on the root row.
  handleSelectTask: () => void
  handleDeleteTask: (event: Event) => void
  handleRenameTask: (event: Event) => void
  handleEditRoutine: (event: Event) => void
  handleRunRoutine: (event: Event) => void
  handlePinToggle: (event: Event) => void
}

export function useTaskActions(
  props: TaskComponentProps,
  emit: EmitFn,
): UseTaskActionsReturn {
  // Re-inject processingState from App.vue (same key WorkspaceItem and
  // ChatsList consume). Keyed by task.id == session_id. Reading it
  // here — even though the row/card templates also re-inject it
  // directly — establishes the contract and matches the pre-split
  // WorkspaceItemTask.vue behavior. The `void` keeps linters from
  // flagging the unused binding.
  const processingState = inject<Ref<Record<string, boolean>>>(
    'processingState',
    ref<Record<string, boolean>>({}),
  )
  void processingState

  // Convenience: is this task a routine? Defaults to false (the legacy
  // behavior) for tasks with no `task_type` field.
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

  // Compute the box-shadow for the row/card's drop indicator. Uses
  // box-shadow (not border) so the visual cue doesn't shift the row's
  // height between drag/no-drag states. 'above' -> 2px line on the top
  // edge, 'below' -> 2px line on the bottom edge, null -> none.
  const dropIndicatorBoxShadow = computed<string>(() => {
    if (props.dropIndicator === 'above') return 'inset 0 2px 0 0 #facc15' // yellow-400
    if (props.dropIndicator === 'below') return 'inset 0 -2px 0 0 #facc15'
    return 'none'
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
    // would call selectTask on the same task). Same rationale as the
    // other action handlers above.
    event.stopPropagation()
    // Flip the local optimistic state — the store action will echo
    // the same flip, so the parent's `task.is_pinned` will be
    // updated to match. If the API call fails, the store rolls back
    // and our local state is overwritten on the next render.
    emit('pinTask', props.workspaceId, props.itemId, props.task.id, !props.task.is_pinned)
  }

  return {
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
  }
}
<script setup lang="ts">
import { inject, onMounted, onUnmounted, ref, type Ref } from 'vue'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import type { Workspace, WorkspaceItem } from '../../stores/workspaces'
 
import WorkspaceItemComponent from './WorkspaceItem.vue'
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
import * as api from '../../api'
import SessionSlider from '../SessionSlider.vue'

// Bind the workspaces prop so the drag-and-drop handler can read it.
// In <script setup>, defineProps returns a `props` object that you
// must destructure or reference — the template gets the prop
// names auto-imported, but the script does not.
const props = defineProps<{
  workspaces: Workspace[]
  activeWorkspaceItemId: string | null
}>()

// Inject processingState from App.vue (same key WorkspaceItem,
// ChatsList, ChatView consume). Keyed by task.id == session_id, so we
// scan a workspace's items→tasks for any key present in the map to
// know "is anything in this workspace currently busy with a worker?".
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const emit = defineEmits<{
  toggleWorkspace: [workspaceId: string]
  selectItem: [workspaceId: string, itemId: string]
  deleteWorkspace: [workspaceId: string]
  renameWorkspace: [workspaceId: string, currentName: string]
  deleteItem: [workspaceId: string, itemId: string]
  requestAddItem: [workspaceId: string, itemType: string]
  addWorkspace: []
  addTask: [workspaceId: string, item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): design
  // page events from <WorkspaceItem> (which forwards them from
  // <DesignPageRow>). Sidebar handles the actual store calls.
  selectDesignPage: [workspaceId: string, itemId: string, pageId: string]
  deleteDesignPage: [workspaceId: string, itemId: string, pageId: string]
  addDesignPage: [workspaceId: string, itemId: string]
  // NEW (rename-design-pages plan, 2026-08-06): ⋮ menu "Rename"
  // item forwards the page from WorkspaceItem → WorkspaceList → Sidebar.
  // Sidebar opens RenameDesignPageModal + calls the store action.
  renameDesignPage: [workspaceId: string, itemId: string, pageId: string, currentName: string]
  // NEW (Chunk 7 of task-routines plan): emitted by
  // <WorkspaceItem> when the routine-task branch in
  // <WorkspaceItemTask> fires the routine's pencil or Run Now
  // button. Sidebar handles these — calls the store action and
  // opens EditRoutineDialog.
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  loadMoreTasks: [workspaceId: string, itemId: string]
  // Drag-and-drop reordering. Emitted on a successful drop with the
  // new top-to-bottom array of workspace IDs. The Sidebar parent
  // forwards this to `workspacesStore.reorderWorkspaces` which
  // performs the optimistic update + API call + rollback on error.
  reorderWorkspaces: [orderedIds: string[]]
  // Drag-and-drop reordering for items of a single workspace.
  // Emitted on a successful drop with the workspace id and the new
  // top-to-bottom array of item IDs. The Sidebar parent forwards
  // this to `workspacesStore.reorderWorkspaceItems` which performs
  // the optimistic update + API call + rollback on error. Scoped
  // to a single workspace (cross-workspace drops are no-ops).
  reorderWorkspaceItems: [workspaceId: string, orderedItemIds: string[]]
  // NEW (pinned-tasks feature, plan:
  // docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md):
  // pin/unpin and drag-reorder of the pinned subset, forwarded
  // from <WorkspaceItem>. Sidebar handles these and calls the
  // store. The signature is intentionally identical to the
  // WorkspaceItem's `pinTask` / `reorderPinnedTasks` events so the
  // pass-through is a one-liner.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  reorderPinnedTasks: [workspaceId: string, itemId: string, orderedIds: string[]]
}>()

const sidebarStore = useSidebarStore()
const activeAddMenu = ref<string | null>(null)

// Scroll container ref
const workspacesScrollRef = ref<HTMLElement | null>(null)

 
// Loading state
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const workspacesLoading = ref(false)

// ─── Drag-and-drop state (workspace reordering) ────────────────────────────
// `draggingId` is the workspace currently being dragged (used to dim
// the source row); `dragOverId` is the row the cursor is hovering
// (used to draw the drop indicator). `null` means "not dragging /
// not hovering". The HTML5 DnD API doesn't expose a single
// is-dragging flag, so we maintain our own. See
// docs/plans/2026-06-12-workspace-drag-and-drop.md.
const draggingId = ref<string | null>(null)
const dragOverId = ref<string | null>(null)
// When the cursor is hovering over `dragOverId`, this boolean
// records whether the cursor is in the BOTTOM half of that row
// (true → insert AFTER, draw a bottom-line indicator) or the TOP
// half (false → insert BEFORE, draw a top-line indicator).
// Mirrors dragOverItemInsertAfter for the item-level reorder.
const dragOverInsertAfter = ref(false)

// ─── Drag-and-drop state (item reordering) ────────────────────────────────
// Mirrors the workspace-level state, scoped to a single workspace's
// items. `draggingItemId` + `draggingItemWorkspaceId` track the
// source; `dragOverItemId` tracks the current drop target.
// `draggingItemWorkspaceId` is needed so a cross-workspace drop can
// be detected and silently no-op'd (defense in depth — the HTML5
// DnD API doesn't have a built-in "are these from the same
// container?" check). See
// docs/plans/2026-06-16-workspace-item-position-reorder.md.
const draggingItemId = ref<string | null>(null)
const draggingItemWorkspaceId = ref<string | null>(null)
const dragOverItemId = ref<string | null>(null)
// When the cursor is hovering over `dragOverItemId`, this boolean
// records whether the cursor is in the BOTTOM half of that row
// (true) or the TOP half (false). The drop handler uses this to
// decide "insert after the target" vs "insert before the target"
// — see handleItemDrop for the index math. The template also
// reads this to draw a top-line vs bottom-line drop indicator so
// the user can see WHERE the drop will land. Without this, a
// top-to-bottom drop would land one slot too far down (the
// pre-fix bug) AND the user wouldn't be able to see why.
const dragOverItemInsertAfter = ref(false)

// Close dropdown when clicking outside
const handleClickOutside = (event: MouseEvent) => {
  const target = event.target as HTMLElement
  if (!target.closest('[data-workspace-menu]')) {
    activeAddMenu.value = null
  }
}

// Handle scroll for infinite scroll pagination
const handleWorkspacesScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const scrollBottom = target.scrollHeight - target.scrollTop - target.clientHeight
  // Load more when user scrolls to within 100px of bottom
  if (scrollBottom < 100) {
    console.log('[WorkspaceList] Scroll triggered')
  }
}

onMounted(() => {
  document.addEventListener('click', handleClickOutside)
})

onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
})

const toggleWorkspacesSection = () => {
  sidebarStore.toggleWorkspacesExpanded()
}

const toggleAddMenu = (workspaceId: string) => {
  if (activeAddMenu.value === workspaceId) {
    activeAddMenu.value = null
  } else {
    activeAddMenu.value = workspaceId
  }
}

const handleWorkspaceClick = (workspaceId: string) => {
  emit('toggleWorkspace', workspaceId)
}

// First processing task's id across all items in this workspace
// (= session_id per Migration 052 convention, same key `processingState`
// uses). Returns null when nothing is running. Used to mount ONE slider
// at the workspace-row level when ANY task is busy — replaces the
// old yellow spinner circle that used to float on the leftmost slot.
// Mirrors `firstProcessingTaskId` in <WorkspaceItem>.
const firstProcessingTaskIdInWorkspace = (
  workspace: Workspace,
): string | null => {
  const state = processingState.value
  for (const item of workspace.items) {
    const tasks = item.tasks
    if (!tasks || tasks.length === 0) continue
    for (const task of tasks) {
      if (state[task.id]) return task.id
    }
  }
  return null
}

const handleItemClick = (workspaceId: string, itemId: string) => {
  emit('selectItem', workspaceId, itemId)
}

const handleDeleteWorkspace = (workspaceId: string) => {
  emit('deleteWorkspace', workspaceId)
}

const handleRenameWorkspace = (workspaceId: string, currentName: string) => {
  emit('renameWorkspace', workspaceId, currentName)
}

const handleDeleteItem = (workspaceId: string, itemId: string) => {
  emit('deleteItem', workspaceId, itemId)
}

const handleAddItem = (workspaceId: string, itemType: string) => {
  activeAddMenu.value = null
  emit('requestAddItem', workspaceId, itemType)
}

const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  emit('addTask', workspaceId, item)
}

const handleSelectTask = (taskId: string) => {
  emit('selectTask', taskId)
}

const handleDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  emit('deleteTask', workspaceId, itemId, taskId)
}

const handleRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  emit('renameTask', workspaceId, itemId, taskId, currentName)
}

// NEW (Chunk 7 of task-routines plan): pass-through for the
// routine-task events emitted by <WorkspaceItem>. Same
// pure-forwarding pattern as the standard-task handlers above.
const handleEditRoutine = (
  workspaceId: string,
  itemId: string,
  taskId: string,
) => {
  emit('editRoutine', workspaceId, itemId, taskId)
}

const handleRunRoutine = (
  workspaceId: string,
  itemId: string,
  taskId: string,
) => {
  emit('runRoutine', workspaceId, itemId, taskId)
}

const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  emit('loadMoreTasks', workspaceId, itemId)
}

// ─── Drag-and-drop handlers (workspace reordering) ────────────────────────
// The HTML5 DnD API is the simplest fit: no dep, native browser
// support, and the project already uses native DOM events for the
// sidebar resize handle (Sidebar.vue:91-116). State is held in
// `draggingId` / `dragOverId` above; visual feedback is applied via
// `:class` bindings on the row (see template below).

const handleDragStart = (workspaceId: string, event: DragEvent) => {
  draggingId.value = workspaceId
  if (event.dataTransfer) {
    // 'move' is the cursor hint; the actual data payload is the
    // workspace id (string), which we read in handleDrop to
    // identify the source. We use a dedicated MIME type so the
    // payload doesn't collide with the item-reorder payload
    // (set by handleItemDragStart via bubbling from inside the
    // item rows) — both handlers fire on the same dragstart in
    // that case, and `setData('text/plain', ...)` is destructive
    // across handlers.
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('application/x-workspace-id', workspaceId)
  }
}

const handleDragOver = (workspaceId: string, event: DragEvent) => {
  // preventDefault on dragover is REQUIRED to allow the drop. Without
  // it, the browser cancels the drop with a "not allowed" cursor.
  event.preventDefault()
  if (event.dataTransfer) {
    event.dataTransfer.dropEffect = 'move'
  }
  if (dragOverId.value !== workspaceId) {
    dragOverId.value = workspaceId
  }
  // Update the "insert before / after" flag on EVERY dragover so
  // the indicator follows the cursor as it crosses the row's
  // midpoint. Same logic as handleItemDragOver.
  const target = event.currentTarget as HTMLElement | null
  if (target) {
    const rect = target.getBoundingClientRect()
    dragOverInsertAfter.value = event.clientY > rect.top + rect.height / 2
  }
}

const handleDragLeave = (workspaceId: string, event: DragEvent) => {
  // Only clear when the cursor actually leaves the row. The
  // dragleave event fires when crossing child elements too, so we
  // check `relatedTarget` to see if the cursor is still inside the
  // row. If it is, do nothing.
  const target = event.currentTarget as HTMLElement | null
  const related = event.relatedTarget as Node | null
  if (target && related && target.contains(related)) return
  if (dragOverId.value === workspaceId) {
    dragOverId.value = null
    dragOverInsertAfter.value = false
  }
}

const handleDrop = (workspaceId: string, event: DragEvent) => {
  event.preventDefault()
  const sourceId = event.dataTransfer?.getData('application/x-workspace-id')
  if (!sourceId || sourceId === workspaceId) {
    // Drop on self or no source id — no-op.
    return
  }
  // Compute the new order: take all workspaces in current order,
  // splice `sourceId` out, then insert at a position computed
  // from the cursor's Y offset within the target row. Top half =
  // insert BEFORE the target, bottom half = insert AFTER the
  // target (Trello/Jira UX). The previous "always insert at the
  // target's original index" algorithm produced an off-by-one
  // result when the source was at a lower index than the target
  // (top-to-bottom drops landed one slot too far down) and when
  // the source was at a higher index and the user dropped in the
  // bottom half (bottom-to-top drops landed one slot too high).
  // See handleItemDrop for the full worked-example trace.
  const current = props.workspaces.slice()
  const fromIdx = current.findIndex((w) => w.id === sourceId)
  const toIdx = current.findIndex((w) => w.id === workspaceId)
  if (fromIdx === -1 || toIdx === -1) return
  const targetRow = event.currentTarget as HTMLElement | null
  const rect = targetRow?.getBoundingClientRect()
  // When the cursor's clientY isn't usable (e.g. some DnD shims
  // don't propagate it), default to "insert before" — matches
  // the pre-fix behavior for bottom-to-top drops and avoids the
  // off-by-one for top-to-bottom drops, which is the more common
  // UX confusion.
  const insertAfter = rect
    ? event.clientY > rect.top + rect.height / 2
    : false
  // Splice returns T[] — destructure the single removed element.
  // `moved` is `Workspace | undefined` (TS noUncheckedIndexedAccess);
  // we already verified the index is in bounds above, so the bang
  // is safe.
  const removed = current.splice(fromIdx, 1)
  const moved = removed[0]
  if (!moved) return
  // Same index math as handleItemDrop — see the comment block
  // there for the worked examples.
  const targetIdxInModified = toIdx > fromIdx ? toIdx - 1 : toIdx
  const insertAt = targetIdxInModified + (insertAfter ? 1 : 0)
  current.splice(insertAt, 0, moved)
  emit('reorderWorkspaces', current.map((w) => w.id))
}

const handleDragEnd = () => {
  // Always clear drag state on dragend, even if the drop was
  // cancelled (e.g. user dropped outside any drop target). Without
  // this, the source row stays dimmed forever.
  draggingId.value = null
  dragOverId.value = null
  dragOverInsertAfter.value = false
}

// ─── Drag-and-drop handlers (item reordering) ──────────────────────────────
// Event delegation pattern: the handlers live on the per-workspace
// `<ul>` (so they're created once per workspace) but the
// draggable + data-* attributes live on each `<li>` inside
// `<WorkspaceItem>`. The handlers use `event.target.closest(...)`
// to find the `<li>` the cursor is over. The `<ul>` is also a
// better anchor than each `<li>` because the `<li>` has children
// (the clickable button, the spinner, etc.) whose DnD events bubble
// up here, so we get one consistent handler for all of them.

const handleItemDragStart = (event: DragEvent) => {
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  const itemId = li.dataset.itemId
  const workspaceId = li.dataset.workspaceId
  if (!itemId || !workspaceId) return
  draggingItemId.value = itemId
  draggingItemWorkspaceId.value = workspaceId
  if (event.dataTransfer) {
    // Dedicated MIME type so the item payload doesn't collide with
    // workspace or pinned-task payloads. Without this, the
    // WorkspaceItem's pinned-task handler (which fires before us
    // on a pinned-row dragstart via bubbling) would set
    // `text/plain` first, then we'd overwrite it here with the
    // item id, causing the pinned reorder drop to read the item
    // id and silently fail (the task isn't in the item's pinned
    // list — the store rejects the reorder).
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('application/x-item-id', itemId)
  }
}

const handleItemDragOver = (event: DragEvent) => {
  // preventDefault on dragover is REQUIRED to allow the drop (HTML5
  // DnD spec). Without it, the browser cancels the drop with a
  // "not allowed" cursor.
  event.preventDefault()
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  const itemId = li.dataset.itemId
  // Don't show the drop indicator on the source row itself (would
  // look like the drop happened on yourself).
  if (itemId && itemId !== draggingItemId.value) {
    if (dragOverItemId.value !== itemId) {
      dragOverItemId.value = itemId
    }
    // Update the "insert before / after" flag on EVERY dragover
    // (not just when the target row changes) — the cursor can
    // move from the top to the bottom of the same row without
    // `dragOverItemId` updating, and the drop indicator should
    // follow the cursor.
    const rect = li.getBoundingClientRect()
    dragOverItemInsertAfter.value = event.clientY > rect.top + rect.height / 2
  }
}

const handleItemDragLeave = (event: DragEvent) => {
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  // Only clear when the cursor actually leaves the row. The
  // dragleave event fires when crossing child elements too, so we
  // check `relatedTarget` to see if the cursor is still inside
  // the row. If it is, do nothing.
  const related = event.relatedTarget as Node | null
  if (related && li.contains(related)) return
  if (dragOverItemId.value === li.dataset.itemId) {
    dragOverItemId.value = null
    dragOverItemInsertAfter.value = false
  }
}

const handleItemDrop = (event: DragEvent) => {
  event.preventDefault()
  const target = event.target as HTMLElement | null
  const li = target?.closest('[data-item-id]') as HTMLElement | null
  if (!li) return
  const targetItemId = li.dataset.itemId
  const targetWorkspaceId = li.dataset.workspaceId
  if (!targetItemId || !targetWorkspaceId) return
  if (!draggingItemId.value || !draggingItemWorkspaceId.value) return
  // Cross-workspace drop: silently no-op. The user dragged an
  // item from workspace A and dropped on an item in workspace B.
  // The plan scopes reorder to a single workspace; cross-workspace
  // moves are out of scope (would require a separate
  // "moveItemToWorkspace" endpoint).
  if (targetWorkspaceId !== draggingItemWorkspaceId.value) return
  // Drop on self: no-op.
  if (targetItemId === draggingItemId.value) return
  // Find the workspace and compute the new order: take the
  // current items, splice the source out, then insert at a
  // position computed from the cursor's Y offset within the
  // target row. Top half = insert BEFORE the target, bottom
  // half = insert AFTER the target (Trello/Jira UX). This gives
  // users precise control regardless of drag direction and fixes
  // the off-by-one bug in the previous "always insert at the
  // target's original index" algorithm.
  const workspace = props.workspaces.find((w) => w.id === targetWorkspaceId)
  if (!workspace) return
  const items = workspace.items.slice()
  const fromIdx = items.findIndex((i) => i.id === draggingItemId.value)
  const toIdx = items.findIndex((i) => i.id === targetItemId)
  if (fromIdx === -1 || toIdx === -1) return
  const rect = li.getBoundingClientRect()
  // Rect.top + rect.height / 2 is the row's vertical midpoint.
  // clientY > midpoint → cursor in bottom half → insert after.
  // clientY <= midpoint → cursor in top half → insert before.
  const insertAfter = event.clientY > rect.top + rect.height / 2
  const removed = items.splice(fromIdx, 1)
  const moved = removed[0]
  if (!moved) return
  // After `splice(fromIdx, 1)`, items with index >= fromIdx have
  // shifted left by 1 in the modified array. The target row sits
  // at `toIdx - 1` (if toIdx > fromIdx) or `toIdx` (if toIdx <
  // fromIdx). The desired insertion point in the modified array
  // is therefore the target's current index, optionally +1 for
  // "insert after".
  //
  // Examples with [A, B, C, D, E]:
  //   A on D top half    → toIdx=3>fromIdx=0 → ins at 2 → [B,C,A,D,E]
  //   A on D bottom half → toIdx=3>fromIdx=0 → ins at 3 → [B,C,D,A,E]
  //   E on B top half    → toIdx=1<fromIdx=4 → ins at 1 → [A,E,B,C,D]
  //   E on B bottom half → toIdx=1<fromIdx=4 → ins at 2 → [A,B,E,C,D]
  const targetIdxInModified = toIdx > fromIdx ? toIdx - 1 : toIdx
  const insertAt = targetIdxInModified + (insertAfter ? 1 : 0)
  items.splice(insertAt, 0, moved)
  emit('reorderWorkspaceItems', targetWorkspaceId, items.map((i) => i.id))
}

const handleItemDragEnd = () => {
  // Always clear drag state on dragend, even if the drop was
  // cancelled. Without this, the source row stays dimmed forever.
  draggingItemId.value = null
  draggingItemWorkspaceId.value = null
  dragOverItemId.value = null
  dragOverItemInsertAfter.value = false
}
</script>

<template>
  <div class="space-y-1 h-full flex flex-col">
    <!-- Section Header - Clickable to collapse/expand. Minimal
         text-driven header: chevron + uppercase section title on
         the left, "+ Add Workspace" as bare text on the right.
         No SVG icons, no card background, no shadow — just
         typography and a subtle hover tint. -->
    <button
      class="px-3 py-2 flex items-center gap-2 cursor-pointer hover:opacity-80 transition-opacity shrink-0 w-full text-left"
      @click="toggleWorkspacesSection"
    >
      <span
        class="text-xs transition-transform duration-200"
        :style="{ transform: sidebarStore.workspacesExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
        style="color: var(--semantic-text-dim);"
      >▶</span>
      <span
        class="text-xs font-semibold uppercase tracking-wider"
        style="color: var(--semantic-text-dim);"
      >Workspaces</span>
      <button
        v-if="sidebarStore.workspacesExpanded"
        @click.stop="$emit('addWorkspace')"
        class="ml-auto text-xs font-medium transition-opacity duration-150 hover:opacity-100"
        style="color: var(--semantic-text-dim); opacity: 0.7;"
        title="Add Workspace"
        aria-label="Add Workspace"
        data-testid="workspaces-add-workspace-button"
      >
        +
      </button>
    </button>

    <!-- Scrollable Workspace Groups Container -->
    <div 
      ref="workspacesScrollRef"
      @scroll="handleWorkspacesScroll"
      class="flex-1 min-h-0 overflow-y-auto"
    >
      <Transition name="collapse">
        <div v-show="sidebarStore.workspacesExpanded" class="space-y-0.5 pb-2">
          <template v-for="workspace in workspaces" :key="workspace.id">
          <!-- Workspace Header (draggable for reordering) -->
          <div
            class="flex items-center group/workspace rounded-lg transition-all duration-150 border-b border-[--color-border]/40"
            :class="{
              'opacity-50': draggingId === workspace.id,
            }"
            :style="{
              // Drop indicator: top-line if cursor is in the TOP
              // half of the row (drop will land BEFORE), bottom-
              // line if in the BOTTOM half (drop will land AFTER).
              // Mirrors the item-level indicator below.
              boxShadow:
                dragOverId === workspace.id && draggingId !== workspace.id
                  ? dragOverInsertAfter
                    ? '0 2px 0 0 var(--color-violet)'
                    : '0 -2px 0 0 var(--color-violet)'
                  : 'none',
            }"
            data-workspace-menu
            draggable="true"
            @dragstart="handleDragStart(workspace.id, $event)"
            @dragover="handleDragOver(workspace.id, $event)"
            @dragleave="handleDragLeave(workspace.id, $event)"
            @drop="handleDrop(workspace.id, $event)"
            @dragend="handleDragEnd"
          >
        <button
          @click="handleWorkspaceClick(workspace.id)"
          class="relative flex-1 flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-200"
          :style="{
            backgroundColor: 'transparent',
            color: 'var(--semantic-text-muted)',
          }"
        >
          <!-- Grip handle — always visible, gives the user a "you can
               drag this" hint. The whole row is draggable (the parent
               <div> has draggable="true"); the handle is purely
               cosmetic. aria-hidden because the actual drag target is
               the parent row, not this span. -->
          <span
            class="w-3 h-4 flex items-center justify-center text-xs opacity-60 transition-opacity duration-200 shrink-0"
            :style="{ color: 'var(--semantic-text-dim)' }"
            aria-hidden="true"
          >≡</span>
          <!-- (Processing spinner removed — replaced by SessionSlider
               at the bottom of this row.) -->
          <!-- Expand/Collapse Icon -->
          <span
            class="text-xs transition-transform duration-200 w-4 flex justify-center"
            :style="{ transform: workspace.expanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
          >▶</span>
          <!-- Workspace Name (no icon — the chevron alone signals the
               row, and the count badge signals magnitude) -->
          <span class="flex-1 text-left font-medium truncate">{{ workspace.name }}</span>
          <!-- Item Count Badge -->
          <span
            v-if="workspace.items.length > 0"
            class="text-xs opacity-70 shrink-0"
            data-testid="workspace-count-badge"
            style="color: var(--semantic-text-dim);"
          >
            {{ workspace.items.length }}
          </span>
          <!-- Per-session LLM slider at the bottom edge of this row.
               Self-positions (the button has `relative`). Visible iff
               firstProcessingTaskIdInWorkspace(workspace) is truthy
               AND processingState[that id] === true. Replaces the
               9-line yellow spinner circle that used to live at the
               leftmost slot (was lines 605-614 in this file). Same
               pattern as WorkspaceItem.vue's slider — just at the
               workspace level instead of the item level. -->
          <SessionSlider
            v-if="firstProcessingTaskIdInWorkspace(workspace)"
            :session-id="firstProcessingTaskIdInWorkspace(workspace)!"
            test-id="workspace-processing-spinner"
          />
        </button>
        <!-- Rename Workspace Button. Unicode pencil glyph (✎) instead
             of an SVG path. Always visible (no hover gate). -->
        <button
          @click.stop="handleRenameWorkspace(workspace.id, workspace.name)"
          class="w-5 h-5 text-xs leading-none flex items-center justify-center rounded opacity-100 transition-opacity duration-150 hover:text-[--semantic-text] mr-1"
          style="color: var(--semantic-text-dim);"
          title="Rename Workspace"
          aria-label="Rename Workspace"
        >
          ✎
        </button>
        <!-- Delete Workspace Button -->
        <button
          @click="handleDeleteWorkspace(workspace.id)"
          class="w-5 h-5 text-sm leading-none flex items-center justify-center rounded opacity-100 transition-opacity duration-150 hover:text-red-400 mr-1"
          style="color: var(--semantic-text-dim);"
          title="Delete Workspace"
          aria-label="Delete Workspace"
        >
          ×
        </button>
      </div>

      <!-- Workspace Items -->
      <Transition name="slide">
        <ul
          v-if="workspace.expanded"
          class="ml-4 pl-3 space-y-0.5 border-l"
          style="border-color: var(--color-border);"
          @dragstart="handleItemDragStart"
          @dragover="handleItemDragOver"
          @dragleave="handleItemDragLeave"
          @drop="handleItemDrop"
          @dragend="handleItemDragEnd"
        >
          <WorkspaceItemComponent
            v-for="item in workspace.items"
            :key="item.id"
            :item="item"
            :is-active="activeWorkspaceItemId === item.id"
            :workspace-id="workspace.id"
            :is-item-dragging="draggingItemId === item.id"
            :is-item-drag-over="dragOverItemId === item.id && draggingItemId !== item.id"
            :is-item-drag-over-insert-after="dragOverItemInsertAfter"
            class="first:mt-1.5"
            @click="handleItemClick(workspace.id, $event.id)"
            @delete="handleDeleteItem(workspace.id, $event.id)"
            @add-task="handleAddTask(workspace.id, $event)"
            @select-task="handleSelectTask"
            @delete-task="handleDeleteTask"
            @rename-task="handleRenameTask"
            @edit-routine="handleEditRoutine"
            @run-routine="handleRunRoutine"
            @load-more-tasks="handleLoadMoreTasks"
            @pin-task="(ws, item, task, isPinned) => emit('pinTask', ws, item, task, isPinned)"
            @reorder-pinned-tasks="(ws, item, orderedIds) => emit('reorderPinnedTasks', ws, item, orderedIds)"
            @select-design-page="(ws, item, pageId) => emit('selectDesignPage', ws, item, pageId)"
            @delete-design-page="(ws, item, pageId) => emit('deleteDesignPage', ws, item, pageId)"
            @add-design-page="(ws, item) => emit('addDesignPage', ws, item)"
            @rename-design-page="(ws, item, pageId, currentName) => emit('renameDesignPage', ws, item, pageId, currentName)"
          />
          <!-- Add Item Button. Minimal: bare text "+ Add Item" with
               a subtle opacity transition on hover. NO SVG, NO
               dashed border, NO icons in the dropdown menu — just
               text labels for "Add Project" and "Add Kanban".
               (Add Memory was removed in 2026-07-04 — memory
               features remain available as task_type='memory'
               inside items via AddTaskPickerDialog.) -->
          <li class="group/workspace relative" data-workspace-menu>
            <button
              @click.stop="toggleAddMenu(workspace.id)"
              data-testid="workspace-add-item-button"
              class="w-full text-left px-3 py-1.5 text-xs transition-opacity duration-150 hover:opacity-100"
              style="color: var(--semantic-text-dim); opacity: 0.6;"
            >
              + Add Item
            </button>
            <!-- Dropdown Menu -->
            <ul
              v-if="activeAddMenu === workspace.id"
              class="absolute left-0 top-full mt-1 py-1 rounded-md shadow-lg z-50 min-w-[160px]"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
            >
              <li>
                <button
                  disabled
                  class="w-full px-3 py-2 text-left text-sm opacity-40 cursor-not-allowed"
                  style="color: var(--semantic-text);"
                  title="Coming soon"
                  aria-disabled="true"
                  data-testid="workspace-add-project-option"
                >
                  Add Project
                </button>
              </li>
              <li>
                <button
                  @click="handleAddItem(workspace.id, 'kanban')"
                  class="w-full px-3 py-2 text-left text-sm hover:opacity-80 transition-opacity"
                  style="color: var(--semantic-text);"
                >
                  Add Kanban
                </button>
              </li>
              <!-- NEW (design-mode feature, plan:
                   docs/superpowers/plans/2026-06-13-design-mode.md):
                   Third dropdown option for creating a design-mode
                   workspace item. Sidebar.handleAddItem routes the
                   'design' itemType to the new AddDesignDialog. -->
              <li>
                <button
                  @click="handleAddItem(workspace.id, 'design')"
                  class="w-full px-3 py-2 text-left text-sm hover:opacity-80 transition-opacity"
                  style="color: var(--semantic-text);"
                  data-testid="workspace-add-design-option"
                >
                  Add Design (alpha)
                </button>
              </li>
              <!-- Agent Mode (plan 2026-08-15-agent-mode,
                   task_1786962724740_0): fourth dropdown option for
                   creating an Agent workspace item. Sidebar.handleAddItem
                   routes the 'agent' itemType to the new AddAgentDialog. -->
              <li>
                <button
                  @click="handleAddItem(workspace.id, 'agent')"
                  class="w-full px-3 py-2 text-left text-sm hover:opacity-80 transition-opacity"
                  style="color: var(--semantic-text);"
                  data-testid="workspace-add-agent-option"
                >
                  Add Agent
                </button>
              </li>
            </ul>
          </li>
        </ul>
        </Transition>
        </template>
      </div>
    </Transition>
    </div>
  </div>
</template>

<style scoped>
/* Slide transition for workspace items */
.slide-enter-active,
.slide-leave-active {
  transition: all 0.2s ease-out;
  overflow: hidden;
}

.slide-enter-from,
.slide-leave-to {
  opacity: 0;
  max-height: 0;
  transform: translateY(-4px);
}

.slide-enter-to,
.slide-leave-from {
  opacity: 1;
  max-height: 500px;
}

/* Collapse transition for workspaces section */
.collapse-enter-active,
.collapse-leave-active {
  transition: all 0.2s ease-out;
  overflow: hidden;
}

.collapse-enter-from,
.collapse-leave-to {
  opacity: 0;
  max-height: 0;
}

.collapse-enter-to,
.collapse-leave-from {
  opacity: 1;
  max-height: 2000px;
}
</style>

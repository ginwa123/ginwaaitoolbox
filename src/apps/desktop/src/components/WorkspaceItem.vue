<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'
import WorkspaceItemTask from './WorkspaceItemTask.vue'

const workspacesStore = useWorkspacesStore()

// Inject processingState from App.vue. Same contract ChatsList uses:
// keyed by worker session_id (which equals task.id when ChatView is
// mounted for a task — see AppLayout.vue:651 :chat-id="activeTask.id").
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const props = defineProps<{
  item: WorkspaceItem
  isActive: boolean
  workspaceId: string
  // Drag-and-drop visual state, owned by the parent
  // <WorkspaceList> and passed down so the <li> can dim when
  // being dragged and show a violet drop indicator on hover. The
  // handlers themselves live in <WorkspaceList> (event delegation
  // on the <ul>); we just need the visual signal here. See
  // docs/plans/2026-06-16-workspace-item-position-reorder.md.
  isItemDragging?: boolean
  isItemDragOver?: boolean
}>()

const emit = defineEmits<{
  click: [item: WorkspaceItem]
  delete: [item: WorkspaceItem]
  addTask: [item: WorkspaceItem]
  // The three task-level events are emitted by the child
  // <WorkspaceItemTask> and re-emitted verbatim up to WorkspaceList.
  // WorkspaceList's contract with Sidebar is unchanged; this is a
  // pure pass-through (see handleSelectTask / handleDeleteTask /
  // handleRenameTask below).
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // NEW (Chunk 7 of task-routines plan): the routine-task branch
  // in WorkspaceItemTask emits these on the routine's pencil and
  // the Run Now button. We re-emit verbatim up to WorkspaceList,
  // same as the standard-task events above.
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  // The user must click to fetch the next page of tasks for this
  // item. WorkspaceList forwards the event to Sidebar, which calls
  // workspacesStore.loadMoreTasks. See Design Note 6 in
  // docs/plans/2026-06-10-workspace-item-task-pagination.md — the
  // button lives here (not in WorkspaceItemTask.vue) because it is
  // a sibling of the per-task list, not a property of any individual
  // task.
  loadMoreTasks: [workspaceId: string, itemId: string]
  // NEW (pinned-tasks feature, plan:
  // docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md):
  // pin/unpin and drag-reorder of the pinned subset, both forwarded
  // up to WorkspaceList → Sidebar. See handlePinTask /
  // handleReorderPinnedTasks below.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  reorderPinnedTasks: [workspaceId: string, itemId: string, orderedIds: string[]]
}>()

// Computed: check if item is expanded (tasks visible)
const isExpanded = computed(() => {
  return workspacesStore.expandedItemIds[props.item.id] === true
})

// Computed: true if any of this item's tasks is currently being processed
// by a worker. Drives the right-side yellow spinner on the item row so
// the user can see "this project is busy" even when the task list is
// collapsed. Mirrors the same processingState ref the per-task spinner
// and ChatsList already consume (App.vue provides it; key = task.id ==
// session_id).
const hasProcessingTask = computed(() => {
  const tasks = props.item.tasks
  if (!tasks || tasks.length === 0) return false
  const state = processingState.value
  for (const task of tasks) {
    if (state[task.id]) return true
  }
  return false
})

const handleClick = () => {
  // Kanban items render the board in the main content area (see
  // AppLayout.vue's KanbanView branch) — there's no inline list to
  // expand, so skip the toggle. Folders and other non-kanban types
  // keep the existing expand/collapse behavior. The selectItem event
  // still fires for ALL types (handled in WorkspaceList → Sidebar →
  // workspacesStore.setActiveWorkspaceItem), so clicking a kanban
  // still activates it; AppLayout just routes the active item to the
  // kanban board instead of a list.
  if (props.item.item_type !== 'kanban') {
    workspacesStore.toggleExpandedItem(props.item.id)
  }
  // Always emit click for external handling (e.g., navigation to
  // the kanban board via activeWorkspaceItemId).
  emit('click', props.item)
}

const handleDelete = (event: Event) => {
  event.stopPropagation()
  emit('delete', props.item)
}

const handleAddTask = (event: Event) => {
  event.stopPropagation()
  emit('addTask', props.item)
}

// Pass-through handlers: <WorkspaceItemTask> emits these three events
// with the full payload (workspaceId, itemId, taskId, currentName), and
// we forward them up to <WorkspaceList> verbatim. The signatures match
// the existing WorkspaceList / Sidebar contract — see the pre-split
// version of this file for the inline handlers that previously lived
// here. No business logic; pure forwarding.
const handleSelectTask = (taskId: string) => {
  emit('selectTask', taskId)
}

const handleDeleteTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
) => {
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
// routine-task events emitted by <WorkspaceItemTask>. Same
// pure-forwarding pattern as the standard-task handlers above;
// WorkspaceList will re-emit these to Sidebar which calls the
// store action and opens EditRoutineDialog.
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

const handleLoadMoreTasks = (event: Event) => {
  // Stop the click from bubbling up to the parent <button> (which
  // would toggle item expansion). The Load More button lives inside
  // the task-list <div>, which sits next to the main item row, so
  // bubbling isn't strictly necessary today — but it's
  // belt-and-braces against a future refactor that moves this
  // button.
  event.stopPropagation()
  emit('loadMoreTasks', props.workspaceId, props.item.id)
}

// NEW (pinned-tasks feature): pin/unpin forwarded from
// <WorkspaceItemTask>. WorkspaceList re-emits these to Sidebar.
const handlePinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  emit('pinTask', workspaceId, itemId, taskId, isPinned)
}

// NEW (pinned-tasks feature): drag-reorder of the pinned subset.
// The drag handler captures the dragged task's id via data-task-id
// and the drop handler splices the row to the bottom of the
// pinned region. v1: simple "move to bottom on drop" semantics.
const handleReorderPinnedTasks = (orderedIds: string[]) => {
  emit('reorderPinnedTasks', props.workspaceId, props.item.id, orderedIds)
}

// Capture the dragged task's id from the data-task-id attribute on
// the row's root button (added in WorkspaceItemTask.vue). The
// pinned region uses event delegation — the dragstart bubbles
// from the row to the region, which calls closest('[data-task-id]')
// to find the source.
const handlePinnedDragStart = (event: DragEvent) => {
  const target = event.target as HTMLElement | null
  if (!target) return
  const row = target.closest('[data-task-id]') as HTMLElement | null
  if (!row) return
  const taskId = row.dataset.taskId
  if (!taskId) return
  // Use a custom MIME type instead of `text/plain`. The pinned
  // region lives inside a workspace-item `<li>`, and the parent's
  // <WorkspaceList> attaches its own `@dragstart` handler on the
  // outer `<ul>` for item reorder. Both handlers fire on the same
  // dragstart (this one first, then the parent after bubbling),
  // and `setData('text/plain', ...)` is destructive — whichever
  // runs second overwrites the first. Using a dedicated MIME type
  // (`application/x-pinned-task-id`) keeps the payload intact for
  // the drop handler without colliding with the parent's
  // `text/plain` payload.
  event.dataTransfer?.setData('application/x-pinned-task-id', taskId)
  if (event.dataTransfer) {
    event.dataTransfer.effectAllowed = 'move'
  }
}

// dragOver bookkeeping: which pinned row the cursor is currently
// over, and whether the insertion point is above (cursor in the
// row's top half) or below (cursor in the bottom half). Reset on
// dragleave / drop. The state drives both the splice math in
// `handlePinnedDrop` AND the yellow drop-indicator bar in the
// template (rendered as a sibling of each row in the v-for).
const dragOverTaskId = ref<string | null>(null)
const dragInsertBefore = ref(false) // true = insert before the target row

// Per-row drop indicator: 'above' | 'below' | null. Returned to
// the v-for as the `drop-indicator` prop on each WorkspaceItemTask
// so the row can render a 2px yellow border on the appropriate
// edge. Centralizing the conditional in one place keeps the
// template terse and makes the indicator state easy to assert on
// in unit tests.
type DropIndicator = 'above' | 'below' | null
const dropIndicatorFor = (taskId: string): DropIndicator => {
  if (dragOverTaskId.value !== taskId) return null
  return dragInsertBefore.value ? 'above' : 'below'
}

const handlePinnedDragOver = (event: DragEvent) => {
  // preventDefault is REQUIRED to mark this element as a valid drop
  // target. Without it the browser's dragend fires without a drop
  // and the drop event never reaches us. We also use it to update
  // the cursor position for the insertion-point math.
  event.preventDefault()
  const target = event.target as HTMLElement | null
  if (!target) return
  const row = target.closest('[data-task-id]') as HTMLElement | null
  if (!row || !row.dataset.taskId) {
    // Cursor is in the region but not over a row (e.g. on the gap
    // between rows or on the region's padding). Keep the previous
    // target — better than flickering the indicator off then on.
    return
  }
  // If the cursor is over the same row as before, just refresh the
  // before/after decision based on the cursor Y. Otherwise, switch
  // the target and reset the before/after flag.
  if (dragOverTaskId.value !== row.dataset.taskId) {
    dragOverTaskId.value = row.dataset.taskId
    dragInsertBefore.value = true // default; refined below
  }
  const rect = row.getBoundingClientRect()
  const midpoint = rect.top + rect.height / 2
  // When clientY is unavailable (synthetic event from a test), keep
  // the previous value. In normal browser drag flows clientY is
  // always set during dragover.
  const clientY = event.clientY
  if (clientY != null) {
    dragInsertBefore.value = clientY < midpoint
  }
}

const handlePinnedDragLeave = (event: DragEvent) => {
  // Only clear the indicator when the cursor LEAVES the region
  // entirely. If it moves between rows inside the region, dragleave
  // fires too but `relatedTarget` is still inside the region — keep
  // the indicator visible in that case. The dragover handler will
  // update `dragOverTaskId` for the new row.
  const region = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (region && next && region.contains(next)) return
  dragOverTaskId.value = null
}

// On drop, splice the dragged row to the cursor's target position
// (not the end). The optimistic store action will reorder the
// local array and persist via the API.
const handlePinnedDrop = (event: DragEvent) => {
  event.preventDefault()
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  // Read from the custom MIME type written by handlePinnedDragStart.
  // Using `text/plain` here would also work in isolation, but
  // colliding with the parent <WorkspaceList>'s `text/plain`
  // payload (item id) means whichever handler ran last on the
  // dragstart wins. See the long comment in handlePinnedDragStart.
  const draggedId = dataTransfer.getData('application/x-pinned-task-id')
  if (!draggedId) return

  const tasks = props.item.tasks ?? []
  const pinned = tasks.filter((t) => t.is_pinned)
  if (pinned.length === 0) return
  const fromIdx = pinned.findIndex((t) => t.id === draggedId)
  if (fromIdx === -1) return // drag came from outside the pinned region

  // Snapshot the target BEFORE we reset the visual state below.
  // (If we reset first, the splice math falls back to "move to
  // end" even when the user dropped on a different row.)
  const targetId = dragOverTaskId.value
  const insertBefore = dragInsertBefore.value

  // Reset visual state regardless of outcome.
  dragOverTaskId.value = null

  // Default: move to the end (preserves the v1 fallback behavior
  // when no target row is recorded — e.g. a fast drop without a
  // preceding dragover, or a drop on the region's empty padding).
  let toIdx = pinned.length - 1
  if (targetId && targetId !== draggedId) {
    const targetIdx = pinned.findIndex((t) => t.id === targetId)
    if (targetIdx !== -1) {
      // "Cursor in top half" = "I want the dragged row to be just
      // ABOVE the target row" (insertBefore=true). "Cursor in
      // bottom half" = "I want the dragged row to be just BELOW
      // the target row" (insertBefore=false). Adjust the target
      // index for the source removal: if the source is BEFORE the
      // target in the original order, removing it shifts the target
      // left by one. So:
      //   insertBefore=true:  toIdx = targetIdx - (source before target ? 1 : 0)
      //   insertBefore=false: toIdx = targetIdx + 1 - (source before target ? 1 : 0)
      const sourceBeforeTarget = fromIdx < targetIdx
      if (insertBefore) {
        toIdx = sourceBeforeTarget ? targetIdx - 1 : targetIdx
      } else {
        toIdx = sourceBeforeTarget ? targetIdx : targetIdx + 1
      }
    }
  }

  const reordered = pinned.slice()
  const [moved] = reordered.splice(fromIdx, 1)
  if (!moved) return
  reordered.splice(toIdx, 0, moved)
  handleReorderPinnedTasks(reordered.map((t) => t.id))
}
</script>

<template>
  <li
    :class="{ 'opacity-50': isItemDragging }"
    :style="{
      boxShadow: isItemDragOver && !isItemDragging
        ? '0 -2px 0 0 var(--color-violet)'
        : 'none',
    }"
    draggable="true"
    :data-item-id="item.id"
    :data-workspace-id="workspaceId"
  >
    <div class="flex flex-col">
      <!-- Main Item Row -->
      <div class="flex items-center group/item">
        <button
          @click="handleClick"
          class="flex-1 flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-all duration-200"
          :style="isActive
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <!-- Processing spinner (LLM worker is running on one of this
               item's tasks). Sits in the LEFTMOST slot — the same
               position the per-task row's bullet/spinner and the
               ChatsList's processing spinner occupy — so all three
               "busy" indicators in the sidebar live in the same
               visual lane and a glance across the sidebar reveals
               what's running. Same yellow ring, scaled to 4×4 to
               match the item row's text-sm font. -->
          <span
            v-if="hasProcessingTask"
            class="w-4 h-4 flex items-center justify-center shrink-0"
            data-testid="item-processing-spinner"
          >
            <div
              class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
              style="border-color: var(--color-yellow); border-top-color: transparent"
            ></div>
          </span>
          <!-- Chevron icon (expand/collapse) -->
          <svg
            class="w-4 h-4 shrink-0 transition-transform duration-200"
            :class="{ '-rotate-90': !isExpanded }"
            fill="none" viewBox="0 0 24 24" stroke="currentColor"
          >
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
          <!-- Item Name -->
          <span class="truncate">{{ item.name }}</span>
          <!-- Loading spinner (folder contents fetching — independent
               of LLM worker state). Right-side slot. Priority 1 over
               the active dot: takes the slot when the user just
               clicked expand and we're still downloading the
               directory listing. -->
          <span v-if="item.isLoading" class="ml-auto" data-testid="item-loading-spinner">
            <svg class="animate-spin w-3 h-3" viewBox="0 0 24 24" fill="none">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
            </svg>
          </span>
          <!-- Active Indicator (for FolderExplorer selection). Right-side
               slot, hidden while the loading spinner is showing. The
               processing spinner lives in a separate (left) slot and
               does not conflict with this dot. -->
          <span
            v-else-if="isActive"
            class="ml-auto w-1.5 h-1.5 rounded-full"
            style="background-color: var(--color-aqua);"
            data-testid="item-active-dot"
          />
        </button>
        <!-- Add Task + Delete Item buttons (show on hover). Hidden for
             kanban items because (a) kanban adds tasks through its own
             column-based UI, not the generic task picker, and (b)
             deleting a kanban requires column cleanup first — the
             bare delete handler doesn't do that. -->
        <template v-if="item.item_type !== 'kanban'">
          <button
            @click="handleAddTask"
            class="w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/item:opacity-100 transition-opacity duration-200 hover:text-green-400"
            style="color: var(--semantic-text-dim);"
            title="Add Task"
          >
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
          </button>
          <!-- Delete Item Button (show on hover) -->
          <button
            @click="handleDelete"
            class="w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/item:opacity-100 transition-opacity duration-200 hover:text-red-400"
            style="color: var(--semantic-text-dim);"
            title="Delete Item"
          >
            <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </template>
      </div>

      <!-- Tasks List (shown when expanded - allows multiple). Per-task
           row lives in <WorkspaceItemTask> (extracted 2026-06-10);
           events bubble up via the pass-through handlers in the
           <script setup> block. -->
      <div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1.5 space-y-0.5 pl-2 border-l border-[--color-border]/30">
        <!-- Pinned region: drag-and-drop reorders only within this
             list. The drop handler calls handleReorderPinnedTasks.
             Only rendered when at least one task is pinned (so the
             empty container doesn't show for non-pinning users). The
             dragover / dragleave handlers track the cursor's target
             row + position so the drop can splice the dragged row at
             the user's intended index (NOT always the end). -->
        <div
          v-if="item.tasks.some((t) => t.is_pinned)"
          data-testid="pinned-tasks-region"
          class="space-y-0.5"
          @drop.prevent="handlePinnedDrop"
          @dragover="handlePinnedDragOver"
          @dragleave="handlePinnedDragLeave"
          @dragstart="handlePinnedDragStart"
        >
          <WorkspaceItemTask
            v-for="task in item.tasks.filter((t) => t.is_pinned)"
            :key="task.id"
            :task="task"
            :workspace-id="workspaceId"
            :item-id="item.id"
            :data-task-id="task.id"
            :data-pinned="true"
            :drop-indicator="dropIndicatorFor(task.id)"
            draggable="true"
            @select-task="handleSelectTask"
            @delete-task="handleDeleteTask"
            @rename-task="handleRenameTask"
            @edit-routine="handleEditRoutine"
            @run-routine="handleRunRoutine"
            @pin-task="handlePinTask"
          />
        </div>
        <!-- Unpinned region: regular order, no drag. -->
        <WorkspaceItemTask
          v-for="task in item.tasks.filter((t) => !t.is_pinned)"
          :key="task.id"
          :task="task"
          :workspace-id="workspaceId"
          :item-id="item.id"
          :data-task-id="task.id"
          @select-task="handleSelectTask"
          @delete-task="handleDeleteTask"
          @rename-task="handleRenameTask"
          @edit-routine="handleEditRoutine"
          @run-routine="handleRunRoutine"
          @pin-task="handlePinTask"
        />
        <!-- Load More: shown when the backend says there are more
             tasks for this item. Hidden during the load to prevent
             double-clicks. data-testid is used by
             workspaceItemTaskLoadMore.spec.ts. Click-to-load only —
             no scroll / intersection-observer / auto-fetch. -->
        <button
          v-if="item.hasMoreTasks"
          data-testid="load-more-tasks"
          :disabled="item.isLoadingMoreTasks"
          @click="handleLoadMoreTasks"
          class="w-full flex items-center justify-center gap-1.5 px-3 py-1 rounded text-xs transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
          style="color: var(--semantic-text-dim);"
        >
          <span v-if="item.isLoadingMoreTasks" class="w-3 h-3">
            <div
              class="w-3 h-3 border-2 rounded-full animate-spin"
              style="border-color: var(--color-aqua); border-top-color: transparent"
            ></div>
          </span>
          <span>{{ item.isLoadingMoreTasks ? 'Loading…' : 'Load more' }}</span>
        </button>
      </div>
    </div>
  </li>
</template>

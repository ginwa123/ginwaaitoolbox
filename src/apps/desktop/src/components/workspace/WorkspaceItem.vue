<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import type { WorkspaceItem } from '../../stores/workspaces'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { isBackgroundOpenEvent } from '../../helpers/tabTarget'
import WorkspaceItemTaskRow from './WorkspaceItemTaskRow.vue'
import DesignPageRow from './DesignPageRow.vue'
import type { DesignPage } from '../../api'
import SessionSlider from '../SessionSlider.vue'

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
  // When `isItemDragOver` is true, this flag tells the row whether
  // the cursor is in the BOTTOM half (true → drop will land AFTER
  // this row, draw a bottom-line indicator) or the TOP half
  // (false → drop will land BEFORE this row, draw a top-line
  // indicator). Lets the user see WHERE the drop will land so
  // they can fine-tune before releasing the mouse. See
  // WorkspaceList.handleItemDrop for the index math that
  // accompanies this visual.
  isItemDragOverInsertAfter?: boolean
}>()

const emit = defineEmits<{
  click: [item: WorkspaceItem]
  /**
   * Ctrl/Cmd+click / middle click on the row: the parent opens (or focuses) a
   * background tab for this item instead of navigating.
   */
  openItemInBackground: [payload: { workspaceId: string; itemId: string; name: string; itemType?: string }]
  delete: [item: WorkspaceItem]
  addTask: [item: WorkspaceItem]
  // The three task-level events are emitted by the child
  // <WorkspaceItemTaskRow> and re-emitted verbatim up to WorkspaceList.
  // WorkspaceList's contract with Sidebar is unchanged; this is a
  // pure pass-through (see handleSelectTask / handleDeleteTask /
  // handleRenameTask below).
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // The user must click to fetch the next page of tasks for this
  // item. WorkspaceList forwards the event to Sidebar, which calls
  // workspacesStore.loadMoreTasks. See Design Note 6 in
  // docs/plans/2026-06-10-workspace-item-task-pagination.md — the
  // button lives here (not in WorkspaceItemTaskRow.vue) because it is
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
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): design
  // page events from <DesignPageRow> (children of expanded design
  // items). WorkspaceList forwards them to Sidebar which calls the
  // store actions.
  selectDesignPage: [workspaceId: string, itemId: string, pageId: string]
  deleteDesignPage: [workspaceId: string, itemId: string, pageId: string]
  addDesignPage: [workspaceId: string, itemId: string]
  // NEW (rename-design-pages plan, 2026-08-06): ⋮ menu "Rename"
  // item forwards the page to Sidebar which opens the
  // RenameDesignPageModal. Pure pass-through — same pattern as
  // selectDesignPage / deleteDesignPage.
  renameDesignPage: [workspaceId: string, itemId: string, pageId: string, currentName: string]
}>()

// Computed: check if item is expanded (tasks visible)
const isExpanded = computed(() => {
  return workspacesStore.expandedItemIds[props.item.id] === true
})

// URL-driven "what is the main content area showing?". The active row
// styling is now sourced from the URL (?view=workspace&itemId=X) rather
// than the `isActive` prop (which is still passed by the parent for
// backwards-compat with other consumers and for the right-side active
// dot). When the URL changes, the computed re-runs and the row styling
// updates — no watcher needed, the template binding is enough.
//
// NEW (plan: 2026-09-02-kanban-settings-as-page): keep the parent row
// highlighted when the user is on the kanban settings page. The page
// is a sub-state of the kanban (same itemId), so the row should stay
// visually selected until the user navigates elsewhere.
const currentMainView = useCurrentMainView()
const isCurrentMainView = computed(() => {
  const v = currentMainView.value
  if (v.kind === 'workspace' && v.itemId === props.item.id) return true
  if (v.kind === 'kanban-settings' && v.itemId === props.item.id) return true
  return false
})

// Computed: true if any of this item's tasks is currently being processed
// First processing task's id (= session_id per Migration 052 convention,
// so it's the same key `processingState` uses). The SessionSlider reads
// this — when null, the slider is hidden (its computed `isVisible`
// evaluates `!!processingState[sessionId]` and falls back to false for
// the default inject). Used to mount ONE slider at the workspace-item
// row level when ANY task is running, replacing the old yellow spinner
// circle.
const firstProcessingTaskId = computed<string | null>(() => {
  const tasks = props.item.tasks
  if (!tasks || tasks.length === 0) return null
  const state = processingState.value
  for (const task of tasks) {
    if (state[task.id]) return task.id
  }
  return null
})

const handleClick = (event?: MouseEvent) => {
  // Ctrl/Cmd+click and middle click mean "open in a background tab" — the
  // gesture users bring from a browser. Handle it before the expand/navigate
  // behaviour so nothing is activated behind their back.
  if (event && isBackgroundOpenEvent(event)) {
    emit('openItemInBackground', {
      workspaceId: props.workspaceId,
      itemId: props.item.id,
      name: props.item.name,
      itemType: props.item.item_type,
    })
    return
  }
  // Agent/folder/memory items toggle expand/collapse here.
  // Kanban items render the board in the main content area (see
  // AppLayout.vue's KanbanView branch) AND show their tasks inline
  // (2026-09-10: no expand on kanban mode). Only `design` + `kanban` skip the toggle
  // (its chevron is a separate click target via handleChevronToggle
  // so expanding doesn't activate the item). The selectItem event
  // still fires for ALL types (handled in WorkspaceList → Sidebar →
  // workspacesStore.setActiveWorkspaceItem), so clicking a kanban
  // still activates it; AppLayout just routes the active item to the
  // kanban board instead of a list.
  if (props.item.item_type !== 'design' && props.item.item_type !== 'kanban') {
    workspacesStore.toggleExpandedItem(props.item.id)
  }
  // Always emit click for external handling (e.g., navigation to
  // the kanban board via activeWorkspaceItemId).
  emit('click', props.item)
}

// NEW (design-pages-in-workspace-tree plan, 2026-08-06): the chevron
// itself (▶) toggles expand for design items WITHOUT activating
// them. Activating happens on the row body (handleClick above) —
// keeping the two concerns separate matches the Figma sidebar
// pattern (chevron=expand, row=activate).
const handleChevronToggle = (event: Event) => {
  // Stop propagation so the chevron click doesn't ALSO fire the
  // outer row's @click handler (which would activate the design
  // item AND expand it). Pre-fix this was the same behaviour for
  // folders via the click handler, but for design items we want
  // activation only on the row body, not the chevron.
  event.stopPropagation()
  workspacesStore.toggleExpandedItem(props.item.id)
  // Lazy fetch design pages on first expand. The cache lives in
  // `workspacesStore.designPagesByItemId`; if it's already populated
  // or a fetch is in-flight, the store action is a no-op beyond
  // returning the cached promise — no double-fetch on rapid toggle.
  if (workspacesStore.expandedItemIds[props.item.id] === true) {
    void workspacesStore.fetchDesignPages(props.workspaceId, props.item.id)
  }
}

const handleDelete = (event: Event) => {
  event.stopPropagation()
  emit('delete', props.item)
}

const handleAddTask = (event: Event) => {
  event.stopPropagation()
  emit('addTask', props.item)
}

// Pass-through handlers: <WorkspaceItemTaskRow> emits these three events
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

// Per-column pagination (kanban-per-column-pagination plan,
// 2026-08-06): the SIDEBAR's "Load more" button aggregates the
// per-column state. For kanban items, any column with hasMore=true
// flips the sidebar button on; for non-kanban items, falls back to
// the (now-removed) board-wide state — which is `undefined` for
// items that were never paginated board-wide (no behavior change
// for those). Each `KanbanColumn` in the kanban view has its own
// per-column pagination so the sidebar's aggregation here is just a
// convenience for the global "Load more" affordance.
const hasMoreTasksForSidebar = computed(() => {
  const colPagination = props.item.columnPagination
  if (!colPagination) return false
  return Object.values(colPagination).some((s) => s.hasMore)
})
const isLoadingMoreTasksForSidebar = computed(() => {
  const colPagination = props.item.columnPagination
  if (!colPagination) return false
  return Object.values(colPagination).some((s) => s.isLoading)
})

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
// <WorkspaceItemTaskRow>. WorkspaceList re-emits these to Sidebar.
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

// NEW (design-pages-in-workspace-tree plan, 2026-08-06): pass-through
// handlers for design-page events emitted by <DesignPageRow>. Sidebar
// receives them and calls the matching store actions
// (`setActiveDesignPage` / `setActiveWorkspaceItem` /
// `deleteDesignPage` / `addDesignPage`).
//
// For `selectDesignPage` we ALSO activate the parent design item so
// the main content area switches to DesignView — otherwise the page
// would be "selected" but the canvas would still show whatever was
// previously active. The two-step state change mirrors what
// DesignView's chat toggle does (openChat also fires both events).
const handleSelectDesignPage = (page: DesignPage) => {
  // 1. Set the page as active first so the click handler in the
  // store's setActiveWorkspaceItem flow doesn't race.
  workspacesStore.setActiveDesignPage(page.id)
  // 2. Activate the design item (which fires the click emit that
  // WorkspaceList → Sidebar route to the design view). Only do this
  // if it's not already active — otherwise we re-emit and trigger
  // an unnecessary watcher in AppLayout.
  if (workspacesStore.activeWorkspaceItemId !== props.item.id) {
    workspacesStore.setActiveWorkspaceItem(props.item.id)
  }
  // 3. Also activate the page's chat task (each design page has a
  // 1:1 FK to a workspace_item_tasks row, see Migration 066). This
  // makes the AppLayout 3-column branch fire (DesignView + ChatView
  // side-by-side) — without it, only the DesignView alone renders
  // and the user lands on a dark canvas with no visible feedback
  // that the click registered. The chat shows the design chat task
  // (empty state "How can I help you?" if no messages yet, otherwise
  // the conversation history).
  //
  // FIX (chatview-bug, task_1785726648589, follow-up): this was
  // missing from the initial click handler — only the 💬 button in
  // DesignView's toolbar opened the chat, and the user's reported
  // "blank after clicking a design page" symptom was the
  // DesignView-alone branch showing a dark canvas (no elements
  // visible because the active page's elements take a tick to load,
  // or the page has no elements yet). Setting the active task here
  // is the same logic handleDesignOpenChat runs when the user clicks
  // 💬 — we're just doing it earlier (at page-select time) so the
  // chat pane is open from the start.
  if (page.workspace_item_task_id) {
    workspacesStore.setActiveTask(page.workspace_item_task_id)
  }
  // 4. Bubble the event up for any external listener (tests).
  emit('selectDesignPage', props.workspaceId, props.item.id, page.id)
}

const handleDeleteDesignPage = (page: DesignPage) => {
  emit('deleteDesignPage', props.workspaceId, props.item.id, page.id)
}

// NEW (rename-design-pages plan, 2026-08-06): pass-through for the
// "Rename" item from the <DesignPageRow> ⋮ menu. WorkspaceList /
// Sidebar are responsible for opening the modal; we just bubble
// the payload up the chain.
const handleRenameDesignPage = (page: DesignPage) => {
  emit('renameDesignPage', props.workspaceId, props.item.id, page.id, page.name)
}

// "+ Add Page" — emits to Sidebar which calls the store action.
// The store handles the API call + cache update + setting the new
// page as active. WorkspaceList / Sidebar manage the actual fetch
// rather than this component, mirroring how `addTask` is wired
// (this component never calls the store directly for mutations).
const handleAddDesignPage = (event: Event) => {
  event.stopPropagation()
  emit('addDesignPage', props.workspaceId, props.item.id)
}

// Reactive view of the design-pages cache for THIS design item.
// Empty array while the fetch is in-flight or for an item that
// hasn't been expanded yet.
const designPages = computed<DesignPage[]>(() => {
  if (props.item.item_type !== 'design') return []
  return workspacesStore.designPagesByItemId[props.item.id] ?? []
})

// Capture the dragged task's id from the data-task-id attribute on
// the row's root button (added in WorkspaceItemTaskRow.vue). The
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
// the v-for as the `drop-indicator` prop on each WorkspaceItemTaskRow
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
      boxShadow:
        isItemDragOver && !isItemDragging
          ? isItemDragOverInsertAfter
            ? '0 2px 0 0 var(--color-violet)'
            : '0 -2px 0 0 var(--color-violet)'
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
          @click="handleClick($event)"
          class="relative flex-1 flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-all duration-200"
          :style="isCurrentMainView
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);`
            : `color: var(--semantic-text-muted);`"
        >
          <!-- Processing slider (LLM worker is running on one of this
               item's tasks). Mounted at the bottom edge of the row,
               self-positioning (absolute bottom-0). Replaces the old
               yellow spinner circle that used to float on the left.
               The slider reads processingState via the same Vue inject
               the spinner used; visible iff firstProcessingTaskId is
               truthy AND processingState[that id] === true. -->
          <!-- Chevron glyph (expand/collapse) — rendered for all
               item types EXCEPT kanban (2026-09-10: no expand on
               kanban mode) so every other row shows
               the same ▶/▼ affordance. Unicode right-pointing
               caret rotated 90° when expanded, matching the
               WorkspaceList chevron style for visual consistency.
               data-testid="item-row-chevron" so tests can verify
               DOM-order position relative to the spinner (was an
               SVG path before the minimalist-rewrite).
               NEW (design-pages-in-workspace-tree plan, 2026-08-06):
               for `design` items the chevron is its own click target
               (calls handleChevronToggle) — toggles expand WITHOUT
               activating the item. Row body click is still activation.
               Other item types (agent/folder/memory) use the click-handler
               toggle (handleClick above) since they don't have nested
               content to navigate to. -->
          <span
            class="text-xs shrink-0 transition-transform duration-200 cursor-pointer"
            :class="item.item_type === 'design' ? 'hover:opacity-100 opacity-80' : ''"
            data-testid="item-row-chevron"
            :style="{ transform: isExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
            aria-hidden="true"
            @click="item.item_type === 'design' ? handleChevronToggle($event) : null"
          >▶</span>
          <!-- Item Name. Fall back to "Untitled project" when the
               DB row has an empty name (legacy data that predates
               the empty-name server-side validation added in
               2026-07-10; the active-dot + bg styling still applies
               so the row is legible rather than a focus-only
               "empty with a border" rectangle).
               Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md -->
          <span class="truncate">{{ item.name || 'Untitled project' }}</span>
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
          <!-- Per-session LLM slider at the bottom edge of this row.
               Self-positions (absolute bottom-0); the parent button
               already has `position: relative` (added in the same
               edit as the slider). Visible iff firstProcessingTaskId
               is truthy AND processingState[that id] === true.
               Replaces the 9-line yellow spinner circle that used to
               occupy the leftmost slot (was lines 545-554). -->
          <SessionSlider
            v-if="firstProcessingTaskId"
            :session-id="firstProcessingTaskId"
            test-id="item-processing-spinner"
          />
        </button>
        <!-- Add Task + Delete Item buttons. The `+` (Add Task) is
             hidden for kanban items (2026-09-09): kanban tasks are
             created from inside the kanban view (column "+ Add" →
             KanbanTaskDetailDialog), so the sidebar picker would
             bypass the board context. Agent/folder/design items keep
             the `+`. The `×` (Delete Item) stays visible for all
             item_types (see cascade note below).
             Previously
             the kanban and design item_types were excluded from the
             sidebar delete, on the (false) assumption that they had
             their own delete UIs. Neither KanbanView nor DesignView
             expose a "Delete this kanban" or "Delete this design"
             button; the only "delete" affordances inside those views
             are deleteColumn / deleteElement for children. Restored
             the sidebar delete for all item_types:

             - kanban: backend's deleteWorkspaceItem cascades to
               kanban_columns (FK ON DELETE CASCADE) which then cascades
               to workspace_item_tasks.kanban_column_id (FK ON DELETE
               SET NULL — moot since the task rows are deleted by the
               parent cascade anyway). No on-disk state to clean up.
             - design: backend's deleteWorkspaceItem cascades to
               design_pages, and the handler rmdirs the
               .nalar/design/ folder from disk.
             - chat/folder: no children, no on-disk state — plain
               row delete.

             See workspace_items_delete.zig for the disk-cleanup logic
             (only runs for item_type='design'). -->
        <template v-if="true">
          <button
            v-if="item.item_type !== 'kanban'"
            @click="handleAddTask"
            class="w-7 h-7 text-xl leading-none flex items-center justify-center rounded opacity-100 transition-opacity duration-150 hover:text-green-400"
            style="color: var(--semantic-text-dim);"
            title="Add Task"
            aria-label="Add Task"
          >
            +
          </button>
          <!-- Delete Item Button (always visible). Unicode × glyph
               instead of SVG. -->
          <button
            @click="handleDelete"
            class="w-7 h-7 text-xl leading-none flex items-center justify-center rounded opacity-100 transition-opacity duration-150 hover:text-red-400"
            style="color: var(--semantic-text-dim);"
            title="Delete Item"
            aria-label="Delete Item"
          >
            ×
          </button>
        </template>
      </div>

      <!-- Tasks List (shown when expanded - allows multiple). Per-task
           row lives in <WorkspaceItemTaskRow> (extracted 2026-06-10);
           events bubble up via the pass-through handlers in the
           <script setup> block.

           NEW (2026-08-06): design items have chat tasks linked 1:1
           to their design pages (FK from design_pages → workspace_item_tasks).
           Showing those chat tasks here would be noise — the user
           already sees the pages below, and clicking a chat task
           routes to the SAME page (per the per-page chat scoping plan).
           Hide the tasks section entirely for design items so the
           sidebar shows ONLY the design pages. -->
      <div v-if="isExpanded && item.item_type !== 'design' && item.item_type !== 'kanban' && item.tasks && item.tasks.length > 0" class="ml-8 mt-1.5 space-y-0.5 pl-2 border-l border-[--color-border]/30">
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
          <WorkspaceItemTaskRow
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
            @pin-task="handlePinTask"
          />
        </div>
        <!-- Unpinned region: regular order, no drag. -->
        <WorkspaceItemTaskRow
          v-for="task in item.tasks.filter((t) => !t.is_pinned)"
          :key="task.id"
          :task="task"
          :workspace-id="workspaceId"
          :item-id="item.id"
          :data-task-id="task.id"
          @select-task="handleSelectTask"
          @delete-task="handleDeleteTask"
          @rename-task="handleRenameTask"
          @pin-task="handlePinTask"
        />
        <!-- Load More: shown when the backend says there are more
             tasks for this item. Hidden during the load to prevent
             double-clicks. data-testid is used by
             workspaceItemTaskLoadMore.spec.ts. Click-to-load only —
             no scroll / intersection-observer / auto-fetch.
             Per-column pagination (kanban-per-column-pagination
             plan, 2026-08-06): the SIDEBAR's "Load more" still works
             on the board-wide cursor (computed from any column with
             hasMore=true). The kanban view itself uses per-column
             pagination in KanbanColumn.vue. -->
        <button
          v-if="hasMoreTasksForSidebar"
          data-testid="load-more-tasks"
          :disabled="isLoadingMoreTasksForSidebar"
          @click="handleLoadMoreTasks"
          class="w-full flex items-center justify-center gap-1.5 px-3 py-1 rounded text-xs transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
          style="color: var(--semantic-text-dim);"
        >
          <span v-if="isLoadingMoreTasksForSidebar" class="w-3 h-3">
            <div
              class="w-3 h-3 border-2 rounded-full animate-spin"
              style="border-color: var(--color-aqua); border-top-color: transparent"
            ></div>
          </span>
          <span>{{ isLoadingMoreTasksForSidebar ? 'Loading…' : 'Load more' }}</span>
        </button>
      </div>

      <!--
        NEW (design-pages-in-workspace-tree plan, 2026-08-06):

        Design Pages section — rendered for `design` items when the
        user expands them. The pre-fix design pages lived as a
        horizontal tab strip inside DesignView (later moved to a left
        sidebar in DesignView via PR #167, both rejected by the user).
        They now live HERE, indented under their parent design item,
        with the same visual rhythm as the per-task rows above so the
        sidebar reads as a single consistent navigation surface.

        Why a separate section instead of extending the tasks list?
        Design items don't have tasks, so the tasks list block above
        doesn't render for them. Adding design pages to the same
        container would force a single block to handle both the
        pin/unpin/drag-reorder task code AND the page-list code,
        which is what we wanted to avoid by extracting the per-row
        component.

        Behaviour:
          - The chevron toggles expand (handler above).
          - On first expand, `fetchDesignPages` populates the cache.
          - Click a page → `handleSelectDesignPage` (sets active page
            + activates the design item → AppLayout routes to
            DesignView).
          - Click × on a page → `handleDeleteDesignPage` (Sidebar
            calls `workspacesStore.deleteDesignPage`, which updates
            the cache + clears `activeDesignPageId` if needed).
          - "+ Add Page" button → `handleAddDesignPage` (Sidebar
            calls `workspacesStore.addDesignPage`, which returns the
            new page and we set it as active so the canvas shows the
            empty new page).
      -->
      <div
        v-if="isExpanded && item.item_type === 'design'"
        class="ml-8 mt-1.5 space-y-0.5 pl-2 border-l border-[--color-border]/30"
        data-testid="design-pages-section"
      >
        <!-- Per-page rows -->
        <DesignPageRow
          v-for="page in designPages"
          :key="page.id"
          :page="page"
          :workspace-id="workspaceId"
          :item-id="item.id"
          :is-active-page="workspacesStore.activeDesignPageId === page.id"
          @select-page="handleSelectDesignPage"
          @rename-page="handleRenameDesignPage"
          @delete-page="handleDeleteDesignPage"
        />
        <!-- "+ Add Page" button (bare text + hover, matching the
             kanban column "+ Add column" pattern in WorkspaceList's
             "+ Add Item" button). The new page becomes active so the
             user immediately sees the empty canvas. -->
        <button
          type="button"
          @click="handleAddDesignPage"
          class="w-full text-left px-3 py-1 rounded text-xs transition-colors hover:bg-[--semantic-active-bg]"
          style="color: var(--semantic-text-dim); opacity: 0.7;"
          data-testid="design-sidebar-add-page-button"
          :title="`Add a new page to ${item.name}`"
        >
          + Add Page
        </button>
      </div>
    </div>
  </li>
</template>

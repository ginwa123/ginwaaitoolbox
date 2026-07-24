<!--
  KanbanColumn — a single column in a kanban board.

  Layout (top → bottom):
    1. Header  — column name + count badge + "⋮" menu.
                Single-clicking the name starts an inline rename
                (small input, Enter saves, Escape/blur cancels). The
                "⋮" menu offers Rename (re-opens via KanbanColumnEditor)
                and Delete (opens KanbanColumnEditor in delete mode).
                The header is DRAGGABLE — dragging it onto another
                column's header reorders the columns (Trello/Jira
                UX). Uses a dedicated MIME type
                `application/x-kanban-column-id` so it doesn't
                collide with the per-card MIME
                (`application/x-kanban-task-id`).
    2. Cards   — scrollable list of <KanbanCard>, filtered by the
                column id from the `tasks` prop and sorted by
                kanban_position.
    3. Footer  — "+ Add" button → emits `add-task` with the column id.
    4. Drop    — the cards area is a drop zone. dragover.preventDefault
                (required by the HTML5 DnD spec to mark this as a
                valid drop target), drop reads the task id from
                `application/x-kanban-task-id` and emits `move-task`
                with the column id and the drop position.

  Public API:
    props:
      column       KanbanColumn
      tasks        Task[] (the full task list for the parent kanban)
      workspaceId  string (passed through to KanbanCard)
      itemId       string (passed through to KanbanCard)
    emits:
      add-task           [columnId: string]
      move-task          [{ taskId: string, columnId: string, position: number }]
      rename-column      [{ columnId: string, name: string }]
      delete-column      [columnId: string]
      reorder-column     [{ columnId: string, targetColumnId: string }]
      select-task        [taskId: string]
      delete-task        [workspaceId, itemId, taskId]
      rename-task        [workspaceId, itemId, taskId, currentName]
      edit-routine       [workspaceId, itemId, taskId]
      run-routine        [workspaceId, itemId, taskId]
      pin-task           [workspaceId, itemId, taskId, isPinned]
-->
<script setup lang="ts">
import { computed, ref, nextTick, onMounted, onUnmounted, watch } from 'vue'
import KanbanCard from './KanbanCard.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import type { KanbanColumn, Task } from '../../stores/workspaces'

const props = withDefaults(defineProps<{
  column: KanbanColumn
  tasks: Task[]
  workspaceId: string
  itemId: string
  // Absolute path used as the root for `@`-trigger file pickers /
  // file-path resolution in descendant cards. Threaded from
  // <KanbanView> via `props.item.path`.
  cwd?: string
}>(), {
  cwd: '',
})

const emit = defineEmits<{
  addTask: [columnId: string]
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  // The "⋮" menu's rename option should open KanbanColumnEditor in
  // 'rename' mode (the modal UX). The host listens for this and
  // wires it up. Different from the inline rename UX (single-click
  // the name → edit-in-place) — the menu is the modal-based path.
  requestRenameColumn: [columnId: string]
  // The "⋮" menu's delete option opens KanbanColumnEditor in
  // 'delete' mode (confirmation modal). The host listens for this.
  requestDeleteColumn: [columnId: string]
  // Column drag-and-drop reorder. Emitted when a column's header
  // is dragged onto another column's header (the dropped-on column
  // becomes the new "slot" for the dragged column; the host's
  // store action resolves the target position and calls the API).
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  // Pass-through from KanbanCard (which re-emits from WorkspaceItemTask).
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the per-task detail dialog (kanban-task-detail-dialog
  // feature). Re-emitted verbatim from <KanbanCard>.
  viewTaskDetail: [taskId: string]
}>()

// ─── Derived data ──────────────────────────────────────────────────────────

// Cards in this column, sorted by kanban_position ascending. Tasks
// without a kanban_column_id (unassigned) are excluded — they live
// in their own region (out of scope for v1).
const cardsInColumn = computed<Task[]>(() => {
  return props.tasks
    .filter((t) => t.kanban_column_id === props.column.id)
    .slice()
    .sort((a, b) => {
      // Tasks without a kanban_position sort to the end (defensive
      // — the backend always assigns one, but the local store can
      // have a brief moment before the optimistic update lands).
      const ap = a.kanban_position ?? Number.MAX_SAFE_INTEGER
      const bp = b.kanban_position ?? Number.MAX_SAFE_INTEGER
      return ap - bp
    })
})

// ─── Auto-load (lazy) for the per-item task list ─────────────────────────
//
// When the kanban has > 100 tasks (the backend's MAX_PAGE_SIZE), the
// initial fetch in `fetchKanbanTasks` only loads the first page. We
// expose two escape hatches for fetching more:
//
//   1. **Scroll-triggered auto-load** (the common case): an
//      IntersectionObserver watches a 1px-tall sentinel div placed at
//      the bottom of the cards list. When the sentinel becomes visible
//      AND `item.hasMoreTasks`, fire `loadMoreTasks` ONCE (debounced via
//      `hasTriggeredAutoLoad`).
//
//   2. **Click-to-load fallback**: a "Load more" button at the bottom
//      of the column when `hasMoreTasks` is true. Catches keyboard-only
//      users and short columns where the sentinel never enters the
//      viewport on its own.
//
// Both routes call `workspacesStore.loadMoreTasks` (the existing store
// action) — no new store changes. The action's `isLoadingMoreTasks`
// guard (workspaces.ts:1425) makes concurrent calls no-ops.
//
// Plan: docs/superpowers/plans/2026-07-24-kanban-lazy-load-tasks.md
//      Chunk 2 (Task 2.1)
const workspacesStore = useWorkspacesStore()
const autoLoadSentinel = ref<HTMLElement | null>(null)
const hasTriggeredAutoLoad = ref(false)
let autoLoadObserver: IntersectionObserver | null = null

// Resolve the parent WorkspaceItem once. Used to read `hasMoreTasks` /
// `isLoadingMoreTasks` for both the auto-trigger and the manual button.
// Returns null when the store doesn't have this item yet (defensive
// during SSE races / item navigation).
const parentItem = computed(() => {
  if (!props.workspaceId || !props.itemId) return null
  return (
    workspacesStore.workspaces
      .find((ws) => ws.id === props.workspaceId)
      ?.items.find((i) => i.id === props.itemId) ?? null
  )
})

const moreTasksAvailable = computed(() => parentItem.value?.hasMoreTasks ?? false)
const loadingMoreTasks = computed(() => parentItem.value?.isLoadingMoreTasks ?? false)

const handleAutoLoad = () => {
  // Debounce: only fire once per page. Reset via the `cardsInColumn`
  // watcher below when the card count changes (a new page arrived)
  // OR when hasMoreTasks flips false.
  if (hasTriggeredAutoLoad.value) return
  if (!moreTasksAvailable.value) return
  if (loadingMoreTasks.value) return
  if (cardsInColumn.value.length === 0) return // empty column: nothing to scroll past, skip auto
  hasTriggeredAutoLoad.value = true
  void workspacesStore.loadMoreTasks(props.workspaceId, props.itemId)
}

const handleManualLoadMore = () => {
  // Manual fallback — same code path as auto-trigger. Catches
  // keyboard-only users and short columns where the sentinel never
  // enters view. No debounce: the user explicitly asked for more.
  void workspacesStore.loadMoreTasks(props.workspaceId, props.itemId)
}

// Reset the debounce when a new page lands (cardsInColumn grew).
// Re-enables the observer so the next scroll-to-bottom fires another
// loadMore. When hasMoreTasks flips false, the sentinel + button hide
// (v-if) and the observer is disconnected (see the sentinel watcher).
watch(
  () => cardsInColumn.value.length,
  () => {
    hasTriggeredAutoLoad.value = false
  },
)

// Wire the IntersectionObserver when the sentinel mounts (and re-wire
// when the ref is recreated on re-render). Use `watch` + `immediate`
// rather than onMounted alone so the observer picks up the sentinel
// ref on every reactive update that creates a new DOM node for it.
watch(
  autoLoadSentinel,
  (el) => {
    // Always tear down the previous observer before wiring a new one.
    if (autoLoadObserver) {
      autoLoadObserver.disconnect()
      autoLoadObserver = null
    }
    if (!el) return
    // Skip wiring if there's nothing to load — saves a useless observer
    // + the sentinel rendering overhead on every column on every render.
    if (!moreTasksAvailable.value) return
    autoLoadObserver = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            handleAutoLoad()
            break
          }
        }
      },
      // rootMargin '200px' = fire when sentinel is within 200px of the
      // viewport bottom, matching the VirtualScroller's
      // loadMoreThreshold (ChatView.vue:2199). root: null = viewport
      // (the column container's own scrollTop can grow, but the
      // sentinel still enters the document viewport as the user scrolls
      // — works for any scrollable column without per-column root
      // wiring).
      { root: null, rootMargin: '0px 0px 200px 0px', threshold: 0 },
    )
    autoLoadObserver.observe(el)
  },
  { immediate: true },
)

onUnmounted(() => {
  if (autoLoadObserver) {
    autoLoadObserver.disconnect()
    autoLoadObserver = null
  }
})

// ─── Inline rename state ───────────────────────────────────────────────────

const isRenaming = ref(false)
const renameValue = ref('')
const renameInput = ref<HTMLInputElement | null>(null)

const startInlineRename = async () => {
  renameValue.value = props.column.name
  isRenaming.value = true
  await nextTick()
  renameInput.value?.focus()
  renameInput.value?.select()
}

const cancelInlineRename = () => {
  isRenaming.value = false
  renameValue.value = ''
}

const commitInlineRename = () => {
  const trimmed = renameValue.value.trim()
  isRenaming.value = false
  if (!trimmed || trimmed === props.column.name) {
    // No-op: empty or unchanged.
    renameValue.value = ''
    return
  }
  emit('renameColumn', { columnId: props.column.id, name: trimmed })
  renameValue.value = ''
}

// ─── "⋮" menu state ────────────────────────────────────────────────────────

const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)

const toggleMenu = () => {
  menuOpen.value = !menuOpen.value
}

const closeMenu = () => {
  menuOpen.value = false
}

// The header "⋮" menu offers Rename + Delete. Both delegate to the
// host (KanbanView / WorkspaceItem), which opens KanbanColumnEditor
// in the right mode. We close the menu on click; the host is
// responsible for showing the editor.
const handleMenuRename = () => {
  menuOpen.value = false
  emit('requestRenameColumn', props.column.id)
}

const handleMenuDelete = () => {
  menuOpen.value = false
  emit('requestDeleteColumn', props.column.id)
}

// Close the menu when clicking outside. Mirror the pattern in
// WorkspaceList.vue's `handleClickOutside`.
const handleDocumentClick = (event: MouseEvent) => {
  if (!menuOpen.value) return
  const target = event.target as Node | null
  if (menuRef.value && target && !menuRef.value.contains(target)) {
    closeMenu()
  }
}

onMounted(() => {
  document.addEventListener('click', handleDocumentClick)
})
onUnmounted(() => {
  document.removeEventListener('click', handleDocumentClick)
})

// ─── Drag-and-drop state (drop zone) ───────────────────────────────────────
//
// Same pattern as WorkspaceItemTask's pinned-region drop handler:
// track which card the cursor is over (so we can compute the drop
// position) and update visual feedback in real-time. For v1 we
// compute the position as the END of the receiving column on drop
// (matches the plan's "append to end" semantics — the user can
// always reorder within a column in a future iteration).

const isDragOver = ref(false)
const isDragging = ref(false)

const handleDragOver = (event: DragEvent) => {
  // preventDefault is REQUIRED for HTML5 DnD — without it the
  // browser cancels the drop with a "not allowed" cursor. We also
  // check that the drag is a kanban card drag (has the MIME type
  // we set in KanbanCard.handleDragStart), and if not, return early
  // so the cursor shows "no entry" — preventing accidental drops
  // from the pinned-tasks region or the item-reorder handler.
  if (!event.dataTransfer) return
  if (
    !event.dataTransfer.types.includes('application/x-kanban-task-id')
  ) {
    return
  }
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  isDragOver.value = true
}

const handleDragLeave = (event: DragEvent) => {
  // Only clear when the cursor LEAVES the drop zone entirely (not
  // when crossing between cards inside the zone). `currentTarget` is
  // the zone; if `relatedTarget` is still inside, do nothing.
  const zone = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (zone && next && zone.contains(next)) return
  isDragOver.value = false
}

const handleDrop = (event: DragEvent) => {
  event.preventDefault()
  isDragOver.value = false
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const taskId = dataTransfer.getData('application/x-kanban-task-id')
  if (!taskId) return
  // v1: append to the end of the receiving column. The position is
  // the current card count — the backend re-numbers siblings after
  // the insert, so "append" maps to "position = current length".
  const position = cardsInColumn.value.length
  emit('moveTask', {
    taskId,
    columnId: props.column.id,
    position,
  })
}

// Mirror KanbanCard's dragstart so the source card can dim while
// dragging (visual cue). We listen on the cards container with
// event delegation, the same pattern as WorkspaceList's item DnD.
const handleDragStartCapture = () => {
  isDragging.value = true
}
const handleDragEndCapture = () => {
  isDragging.value = false
  isDragOver.value = false
}

// ─── Drag-and-drop state (column reorder) ──────────────────────────────────
//
// Column header drag-and-drop (separate from the per-card DnD above).
// Uses a dedicated MIME type `application/x-kanban-column-id` so the
// payload can't collide with `application/x-kanban-task-id` (cards).
// The dragover/drop handlers on the header only react when the drag
// carries the column MIME — card drags are ignored here, so a card
// drag onto a header doesn't trigger a column reorder.

const isColumnDragOver = ref(false)

const handleColumnDragStart = (event: DragEvent) => {
  // Set the column-specific MIME. Effect is set to 'move' so the
  // cursor shows the move arrow (matches the per-card DnD).
  if (!event.dataTransfer) return
  event.dataTransfer.effectAllowed = 'move'
  event.dataTransfer.setData('application/x-kanban-column-id', props.column.id)
}

const handleColumnDragOver = (event: DragEvent) => {
  // Only accept column drags; ignore card drags (those target the
  // cards container, not the header).
  if (!event.dataTransfer) return
  if (!event.dataTransfer.types.includes('application/x-kanban-column-id')) {
    return
  }
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  isColumnDragOver.value = true
}

const handleColumnDragLeave = (event: DragEvent) => {
  // Only clear when the cursor leaves the header entirely (not when
  // crossing between the header's children). Same pattern as
  // handleDragLeave for the cards drop zone.
  const header = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (header && next && header.contains(next)) return
  isColumnDragOver.value = false
}

const handleColumnDrop = (event: DragEvent) => {
  event.preventDefault()
  isColumnDragOver.value = false
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const draggedColumnId = dataTransfer.getData('application/x-kanban-column-id')
  if (!draggedColumnId) return
  // No-op if the user dropped a column onto itself — emitting
  // reorder would be a wasted API call (and the backend would
  // still renumber, but to the same positions).
  if (draggedColumnId === props.column.id) return
  emit('reorderColumn', {
    columnId: draggedColumnId,
    targetColumnId: props.column.id,
  })
}

// ─── Footer add ────────────────────────────────────────────────────────────

const handleAddClick = () => {
  emit('addTask', props.column.id)
}
</script>

<template>
  <section
    class="kanban-column flex flex-col rounded-lg shrink-0"
    :data-column-id="column.id"
    :data-kanban-column="column.id"
    style="
      width: 280px;
      background-color: var(--semantic-sidebar-bg);
      border: 1px solid var(--color-border);
    "
  >
    <!-- ─── Header ───────────────────────────────────────────────────── -->
    <!-- The header is DRAGGABLE: drag it onto another column's
         header to reorder columns. dragover.preventDefault is
         required for HTML5 DnD to mark this as a valid drop
         target; drop reads `application/x-kanban-column-id` and
         emits `reorderColumn`. The visual feedback is a violet
         outline when another column is being dragged over. -->
    <header
      class="px-3 py-2 flex items-center gap-2 shrink-0"
      :style="
        isColumnDragOver
          ? 'border-bottom: 1px solid var(--color-border); outline: 2px solid var(--color-violet); outline-offset: -2px;'
          : 'border-bottom: 1px solid var(--color-border);'
      "
      :data-testid="`kanban-column-${column.id}-header`"
      draggable="true"
      @dragstart="handleColumnDragStart"
      @dragover="handleColumnDragOver"
      @dragleave="handleColumnDragLeave"
      @drop="handleColumnDrop"
    >
      <!-- Inline-rename input (visible while isRenaming) OR plain name (otherwise) -->
      <input
        v-if="isRenaming"
        ref="renameInput"
        v-model="renameValue"
        type="text"
        :data-testid="`kanban-column-${column.id}-rename-input`"
        class="flex-1 px-2 py-0.5 rounded text-sm outline-none"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        @keyup.enter="commitInlineRename"
        @keyup.escape="cancelInlineRename"
        @blur="commitInlineRename"
      />
      <button
        v-else
        type="button"
        class="flex-1 text-left text-sm font-medium truncate hover:opacity-80"
        style="color: var(--semantic-text);"
        :data-testid="`kanban-column-${column.id}-name`"
        @click="startInlineRename"
      >
        {{ column.name }}
      </button>
      <!-- Count badge -->
      <span
        class="text-xs px-1.5 py-0.5 rounded-full shrink-0"
        style="background-color: var(--color-bg-p1); color: var(--semantic-text-dim);"
        :data-testid="`kanban-column-${column.id}-count`"
      >
        {{ cardsInColumn.length }}
      </span>
      <!-- "⋮" menu trigger + dropdown -->
      <div ref="menuRef" class="relative shrink-0">
        <button
          type="button"
          class="w-6 h-6 flex items-center justify-center rounded hover:opacity-80"
          style="color: var(--semantic-text-dim);"
          :data-testid="`kanban-column-${column.id}-menu-trigger`"
          @click.stop="toggleMenu"
        >
          <span class="text-base leading-none">⋮</span>
        </button>
        <ul
          v-if="menuOpen"
          class="absolute right-0 top-full mt-1 py-1 rounded-md shadow-lg z-10 min-w-[120px]"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
          "
          :data-testid="`kanban-column-${column.id}-menu`"
        >
          <li>
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-sm hover:opacity-80"
              style="color: var(--semantic-text);"
              :data-testid="`kanban-column-${column.id}-menu-rename`"
              @click="handleMenuRename"
            >
              Rename
            </button>
          </li>
          <li>
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-sm hover:opacity-80"
              style="color: #ef4444;"
              :data-testid="`kanban-column-${column.id}-menu-delete`"
              @click="handleMenuDelete"
            >
              Delete
            </button>
          </li>
        </ul>
      </div>
    </header>

    <!-- Description subtitle (Chunk 2 of kanban-column-description-settings).
         Sits between the header row (name + count + menu) and the
         cards drop zone so it reads as a sub-header line. Hidden
         when description is empty/null/undefined — all three falsy
         in v-if, which matches the backend's "empty string = no
         description" sentinel plus legacy KanbanColumn literals. -->
    <p
      v-if="column.description"
      class="text-[11px] px-3 pt-0.5 pb-1.5 truncate"
      style="color: var(--semantic-text-dim);"
      :title="column.description"
      :data-testid="`kanban-column-${column.id}-description`"
    >
      {{ column.description }}
    </p>

    <!-- ─── Cards (drop zone) ────────────────────────────────────────── -->
    <div
      class="flex-1 min-h-0 overflow-y-auto p-2 space-y-1"
      :style="isDragOver
        ? 'background-color: var(--semantic-active-bg); outline: 2px dashed var(--color-violet); outline-offset: -4px;'
        : ''"
      :data-kanban-drop-zone="column.id"
      :data-testid="`kanban-column-${column.id}-cards`"
      @dragover="handleDragOver"
      @dragleave="handleDragLeave"
      @drop="handleDrop"
      @dragstart.capture="handleDragStartCapture"
      @dragend.capture="handleDragEndCapture"
    >
      <KanbanCard
        v-for="task in cardsInColumn"
        :key="task.id"
        :task="task"
        :workspace-id="workspaceId"
        :item-id="itemId"
        :cwd="cwd"
        :style="isDragging ? 'opacity: 0.4;' : ''"
        @select-task="(id) => emit('selectTask', id)"
        @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
        @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
        @edit-routine="(ws, item, id) => emit('editRoutine', ws, item, id)"
        @run-routine="(ws, item, id) => emit('runRoutine', ws, item, id)"
        @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
        @view-task-detail="(id) => emit('viewTaskDetail', id)"
      />
      <!-- Empty placeholder — shown only when there are no cards. Gives
           the drop zone a clear "drop here" affordance. -->
      <div
        v-if="cardsInColumn.length === 0"
        class="text-xs text-center py-6"
        style="color: var(--semantic-text-dim);"
        :data-testid="`kanban-column-${column.id}-empty`"
      >
        No tasks yet
      </div>
      <!-- Auto-load sentinel — a 1px-tall element at the bottom of the
           scrollable cards list. The IntersectionObserver in <script setup>
           watches this and fires workspacesStore.loadMoreTasks when it
           enters the viewport (with a 200px rootMargin for early trigger).
           Hidden when the column has no more tasks to fetch. -->
      <div
        v-if="moreTasksAvailable"
        ref="autoLoadSentinel"
        class="h-px w-full shrink-0"
        aria-hidden="true"
        :data-testid="`kanban-column-${column.id}-auto-load-sentinel`"
      ></div>
      <!-- Manual "Load more" fallback — visible when the backend says
           more tasks exist. Hides during the in-flight load. Catches
           keyboard-only / short-column cases where the sentinel never
           enters the viewport. -->
      <button
        v-if="moreTasksAvailable"
        type="button"
        :disabled="loadingMoreTasks"
        @click="handleManualLoadMore"
        class="w-full flex items-center justify-center gap-1.5 px-3 py-1.5 rounded text-xs transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
        style="color: var(--semantic-text-dim);"
        :data-testid="`kanban-column-${column.id}-load-more`"
      >
        <span v-if="loadingMoreTasks" class="w-3 h-3">
          <div
            class="w-3 h-3 border-2 rounded-full animate-spin"
            style="border-color: var(--color-aqua); border-top-color: transparent"
          ></div>
        </span>
        <span>{{ loadingMoreTasks ? 'Loading…' : 'Load more' }}</span>
      </button>
    </div>

    <!-- ─── Footer "+ Add" button ────────────────────────────────────── -->
    <footer
      class="px-3 py-2 shrink-0"
      style="border-top: 1px solid var(--color-border);"
    >
      <button
        type="button"
        class="w-full flex items-center justify-center gap-1 px-2 py-1.5 rounded text-xs font-medium hover:opacity-80 transition-opacity"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px dashed var(--color-border);
          color: var(--semantic-text-dim);
        "
        :data-testid="`kanban-column-${column.id}-add-task`"
        @click="handleAddClick"
      >
        <span aria-hidden="true">+</span>
        <span>Add</span>
      </button>
    </footer>
  </section>
</template>

<style scoped>
/* Column hover affordance — make the ⋮ menu visible without hover
   on the column itself (the menu trigger is always visible, but
   the column gets a subtle border highlight when hovered to hint
   "interactive".) */
.kanban-column {
  transition: border-color 0.15s ease;
}

.kanban-column:hover {
  border-color: var(--color-violet) !important;
}
</style>
<script setup lang="ts">
import { inject, onMounted, onUnmounted, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import type { Workspace, WorkspaceItem } from '../stores/workspaces'
import WorkspaceItemComponent from './WorkspaceItem.vue'
import * as api from '../api'

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
}>()

const sidebarStore = useSidebarStore()
const activeAddMenu = ref<string | null>(null)

// Scroll container ref
const workspacesScrollRef = ref<HTMLElement | null>(null)

// Loading state
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

// Pure helper: true if any task belonging to any item in this workspace
// is currently in the global processingState map. Used by the template
// to decide whether the workspace row's right-side slot should render
// a yellow spinner (work in flight) or the regular item-count badge
// (idle). O(items × tasks) per workspace per render — fine for the
// realistic sidebar size (a few dozen items at most).
const workspaceHasProcessingItem = (workspace: Workspace): boolean => {
  const state = processingState.value
  for (const item of workspace.items) {
    const tasks = item.tasks
    if (!tasks || tasks.length === 0) continue
    for (const task of tasks) {
      if (state[task.id]) return true
    }
  }
  return false
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
    // identify the source. 'text/plain' is the universal MIME type
    // that works in all browsers and is what HTML5 DnD spec
    // recommends for non-rich-text drags.
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData('text/plain', workspaceId)
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
  }
}

const handleDrop = (workspaceId: string, event: DragEvent) => {
  event.preventDefault()
  const sourceId = event.dataTransfer?.getData('text/plain')
  if (!sourceId || sourceId === workspaceId) {
    // Drop on self or no source id — no-op.
    return
  }
  // Compute the new order: take all workspaces in current order,
  // splice `sourceId` out, insert it at the position of
  // `workspaceId` (the drop target).
  const current = props.workspaces.slice()
  const fromIdx = current.findIndex((w) => w.id === sourceId)
  const toIdx = current.findIndex((w) => w.id === workspaceId)
  if (fromIdx === -1 || toIdx === -1) return
  // Splice returns T[] — destructure the single removed element.
  // `moved` is `Workspace | undefined` (TS noUncheckedIndexedAccess);
  // we already verified the index is in bounds above, so the bang
  // is safe.
  const removed = current.splice(fromIdx, 1)
  const moved = removed[0]
  if (!moved) return
  current.splice(toIdx, 0, moved)
  emit('reorderWorkspaces', current.map((w) => w.id))
}

const handleDragEnd = () => {
  // Always clear drag state on dragend, even if the drop was
  // cancelled (e.g. user dropped outside any drop target). Without
  // this, the source row stays dimmed forever.
  draggingId.value = null
  dragOverId.value = null
}
</script>

<template>
  <div class="space-y-1 h-full flex flex-col">
    <!-- Section Header - Clickable to collapse/expand -->
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
      <div class="flex items-center gap-2 ml-auto">
        <button
          v-if="sidebarStore.workspacesExpanded"
          @click.stop="$emit('addWorkspace')"
          class="w-5 h-5 rounded flex items-center justify-center transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-dim);"
          title="Add Workspace"
        >
          <span class="text-sm">+</span>
        </button>
      </div>
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
            class="flex items-center group/workspace rounded-lg transition-all duration-150"
            :class="{
              'opacity-50': draggingId === workspace.id,
            }"
            :style="{
              boxShadow: dragOverId === workspace.id && draggingId !== workspace.id
                ? '0 -2px 0 0 var(--color-violet)'
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
          class="flex-1 flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-200"
          :style="{
            backgroundColor: workspace.expanded
              ? 'var(--semantic-active-bg)'
              : 'transparent',
            color: workspace.expanded
              ? 'var(--semantic-active-text)'
              : 'var(--semantic-text-muted)',
          }"
        >
          <!-- Grip handle — visible on hover, gives the user a "you can
               drag this" hint. The whole row is draggable (the parent
               <div> has draggable="true"); the handle is purely
               cosmetic. aria-hidden because the actual drag target is
               the parent row, not this span. -->
          <span
            class="w-3 h-4 flex items-center justify-center text-xs opacity-0 group-hover/workspace:opacity-60 transition-opacity duration-200 shrink-0"
            :style="{ color: 'var(--semantic-text-dim)' }"
            aria-hidden="true"
          >≡</span>
          <!-- Processing spinner (one of this workspace's items has a
               task currently being run by a worker). Sits in the
               LEFTMOST slot — the same position the per-task and
               per-item row spinners and the ChatsList processing
               spinner occupy — so all "busy" indicators in the
               sidebar live in the same visual lane. Same yellow
               ring, sized to fit the workspace row's text-sm font. -->
          <span
            v-if="workspaceHasProcessingItem(workspace)"
            class="w-4 h-4 flex items-center justify-center shrink-0"
            data-testid="workspace-processing-spinner"
          >
            <div
              class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
              style="border-color: var(--color-yellow); border-top-color: transparent"
            ></div>
          </span>
          <!-- Expand/Collapse Icon -->
          <span
            class="text-xs transition-transform duration-200 w-4 flex justify-center"
            :style="{ transform: workspace.expanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
          >▶</span>
          <!-- Workspace Name -->
          <span class="flex-1 text-left font-medium truncate">{{ workspace.name }}</span>
          <!-- Item Count Badge -->
          <span
            v-if="workspace.items.length > 0"
            class="text-xs px-1.5 py-0.5 rounded-full"
            data-testid="workspace-count-badge"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-dim);"
          >
            {{ workspace.items.length }}
          </span>
        </button>
        <!-- Rename Workspace Button -->
        <button
          @click.stop="handleRenameWorkspace(workspace.id, workspace.name)"
          class="w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/workspace:opacity-100 transition-opacity duration-200 hover:text-blue-400 mr-1"
          style="color: var(--semantic-text-dim);"
          title="Rename Workspace"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
          </svg>
        </button>
        <!-- Delete Workspace Button -->
        <button
          @click="handleDeleteWorkspace(workspace.id)"
          class="w-6 h-6 flex items-center justify-center rounded opacity-0 group-hover/workspace:opacity-100 transition-opacity duration-200 hover:text-red-400 mr-1"
          style="color: var(--semantic-text-dim);"
          title="Delete Workspace"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
          </svg>
        </button>
      </div>

      <!-- Workspace Items -->
      <Transition name="slide">
        <ul v-if="workspace.expanded" class="ml-4 pl-3 space-y-0.5 border-l" style="border-color: var(--color-border);">
          <WorkspaceItemComponent
            v-for="item in workspace.items"
            :key="item.id"
            :item="item"
            :is-active="activeWorkspaceItemId === item.id"
            :workspace-id="workspace.id"
            @click="handleItemClick(workspace.id, $event.id)"
            @delete="handleDeleteItem(workspace.id, $event.id)"
            @add-task="handleAddTask(workspace.id, $event)"
            @select-task="handleSelectTask"
            @delete-task="handleDeleteTask"
            @rename-task="handleRenameTask"
            @edit-routine="handleEditRoutine"
            @run-routine="handleRunRoutine"
            @load-more-tasks="handleLoadMoreTasks"
          />
          <!-- Add Item Button -->
          <li class="group/workspace relative" data-workspace-menu>
            <button
              @click.stop="toggleAddMenu(workspace.id)"
              class="w-full flex items-center gap-2 px-3 py-1.5 rounded-md text-sm transition-all duration-200"
              style="color: var(--semantic-text-dim);"
            >
              <span class="opacity-50 group-hover/workspace:opacity-100 transition-opacity duration-200">+</span>
              <span class="opacity-50 group-hover/workspace:opacity-100 transition-opacity duration-200 truncate">Add Item</span>
            </button>
            <!-- Dropdown Menu -->
            <ul
              v-if="activeAddMenu === workspace.id"
              class="absolute left-0 top-full mt-1 py-1 rounded-md shadow-lg z-50 min-w-[140px]"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
            >
              <li>
                <button
                  @click="handleAddItem(workspace.id, 'folder')"
                  class="w-full px-3 py-2 text-left text-sm hover:opacity-80 transition-opacity flex items-center gap-2"
                  style="color: var(--semantic-text);"
                >
                  <span>Add Project</span>
                </button>
              </li>
              <li class="opacity-50 pointer-events-none" title="Coming soon">
                <button
                  class="w-full px-3 py-2 text-left text-sm flex items-center gap-2 cursor-not-allowed"
                  style="color: var(--semantic-text-dim);"
                  disabled
                >
                  <span>Add Markdown</span>
                  <span class="text-xs">(Dev)</span>
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

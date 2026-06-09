<script setup lang="ts">
import { inject, onMounted, onUnmounted, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import type { Workspace, WorkspaceItem } from '../stores/workspaces'
import WorkspaceItemComponent from './WorkspaceItem.vue'
import * as api from '../api'

defineProps<{
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
}>()

const sidebarStore = useSidebarStore()
const activeAddMenu = ref<string | null>(null)

// Scroll container ref
const workspacesScrollRef = ref<HTMLElement | null>(null)

// Loading state
const workspacesLoading = ref(false)

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
          <!-- Workspace Header -->
          <div class="flex items-center group/workspace" data-workspace-menu>
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

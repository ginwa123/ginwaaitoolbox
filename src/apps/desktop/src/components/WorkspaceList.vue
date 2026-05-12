<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import type { Workspace, WorkspaceItem } from '../stores/workspaces'
import WorkspaceItemComponent from './WorkspaceItem.vue'

defineProps<{
  workspaces: Workspace[]
  activeWorkspaceItemId: string | null
}>()

const emit = defineEmits<{
  toggleWorkspace: [workspaceId: string]
  selectItem: [workspaceId: string, itemId: string]
  deleteWorkspace: [workspaceId: string]
  deleteItem: [workspaceId: string, itemId: string]
  requestAddItem: [workspaceId: string, itemType: string]
  addWorkspace: []
  addTask: [workspaceId: string, item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
}>()

// Workspaces section collapsible state
const workspacesExpanded = ref(true)
const activeAddMenu = ref<string | null>(null)

// Close dropdown when clicking outside
const handleClickOutside = (event: MouseEvent) => {
  const target = event.target as HTMLElement
  if (!target.closest('[data-workspace-menu]')) {
    activeAddMenu.value = null
  }
}

onMounted(() => {
  document.addEventListener('click', handleClickOutside)
})

onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
})

const toggleWorkspacesSection = () => {
  workspacesExpanded.value = !workspacesExpanded.value
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

const handleItemClick = (workspaceId: string, itemId: string) => {
  emit('selectItem', workspaceId, itemId)
}

const handleDeleteWorkspace = (workspaceId: string) => {
  emit('deleteWorkspace', workspaceId)
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
</script>

<template>
  <div class="space-y-1">
    <!-- Section Header - Clickable to collapse/expand -->
    <div 
      class="px-3 py-2 flex items-center justify-between cursor-pointer hover:opacity-80 transition-opacity"
      @click="toggleWorkspacesSection"
    >
      <span
        class="text-xs font-semibold uppercase tracking-wider"
        style="color: var(--semantic-text-dim);"
      >Workspaces</span>
      <div class="flex items-center gap-2">
        <button
          @click.stop="$emit('addWorkspace')"
          class="w-5 h-5 rounded flex items-center justify-center transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-dim);"
          title="Add Workspace"
        >
          <span class="text-sm">+</span>
        </button>
        <span 
          class="text-xs transition-transform duration-200" 
          :style="{ transform: workspacesExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
          style="color: var(--semantic-text-dim);"
        >▶</span>
      </div>
    </div>

    <!-- Workspace Groups -->
    <Transition name="collapse">
      <div v-show="workspacesExpanded" class="space-y-0.5">
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
          <!-- Expand/Collapse Icon -->
          <span
            class="text-xs transition-transform duration-200 w-4 flex justify-center"
            :style="{ transform: workspace.expanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
          >▶</span>
          <!-- Workspace Icon -->
          <span class="text-base">{{ workspace.icon }}</span>
          <!-- Workspace Name -->
          <span class="flex-1 text-left font-medium truncate">{{ workspace.name }}</span>
          <!-- Item Count Badge -->
          <span
            v-if="workspace.items.length > 0"
            class="text-xs px-1.5 py-0.5 rounded-full"
            style="background-color: var(--color-bg-p1); color: var(--semantic-text-dim);"
          >
            {{ workspace.items.length }}
          </span>
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
                  <span>📁</span>
                  <span>Add Project</span>
                </button>
              </li>
              <li class="opacity-50 pointer-events-none" title="Coming soon">
                <button
                  class="w-full px-3 py-2 text-left text-sm flex items-center gap-2 cursor-not-allowed"
                  style="color: var(--semantic-text-dim);"
                  disabled
                >
                  <span>📝</span>
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

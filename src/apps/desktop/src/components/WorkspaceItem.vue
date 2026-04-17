<script setup lang="ts">
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'

const workspacesStore = useWorkspacesStore()

const props = defineProps<{
  item: WorkspaceItem
  isActive: boolean
  workspaceId: string
}>()

const emit = defineEmits<{
  click: [item: WorkspaceItem]
  delete: [item: WorkspaceItem]
  addTask: [item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
}>()

const handleClick = () => {
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

const handleSelectTask = (taskId: string) => {
  emit('selectTask', taskId)
}

const handleDeleteTask = (event: Event, taskId: string) => {
  event.stopPropagation()
  emit('deleteTask', props.workspaceId, props.item.id, taskId)
}
</script>

<template>
  <li>
    <div class="flex flex-col">
      <!-- Main Item Row -->
      <div class="flex items-center group/item">
        <button
          @click="handleClick"
          class="flex-1 flex items-center gap-2 px-3 py-1.5 rounded-md text-sm transition-all duration-200"
          :style="isActive
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <!-- Item Icon -->
          <span
            class="transition-colors duration-200"
            :style="isActive ? 'opacity: 1;' : 'opacity: 0.5;'"
          >{{ item.icon }}</span>
          <!-- Item Name -->
          <span class="truncate">{{ item.name }}</span>
          <!-- Loading spinner -->
          <span v-if="item.isLoading" class="ml-auto">
            <svg class="animate-spin w-3 h-3" viewBox="0 0 24 24" fill="none">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
            </svg>
          </span>
          <!-- Active Indicator -->
          <span
            v-if="isActive && !item.isLoading"
            class="ml-auto w-1.5 h-1.5 rounded-full"
            style="background-color: var(--color-aqua);"
          />
        </button>
        <!-- Add Task Button (show on hover) -->
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
      </div>

      <!-- Tasks List (shown when active) -->
      <div v-if="isActive && item.tasks && item.tasks.length > 0" class="ml-8 mt-1 space-y-0.5">
        <div
          v-for="task in item.tasks"
          :key="task.id"
          class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
          :style="{
            color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
            backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
          }"
          @click="handleSelectTask(task.id)"
        >
          <!-- Bullet point -->
          <span class="w-1.5 h-1.5 rounded-full shrink-0" :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }" />
          <!-- Task name -->
          <span class="flex-1 truncate">{{ task.name }}</span>
          <!-- Delete task button -->
          <button
            @click="handleDeleteTask($event, task.id)"
            class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity hover:text-red-400"
            style="color: var(--semantic-text-dim);"
          >
            <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      </div>
    </div>
  </li>
</template>

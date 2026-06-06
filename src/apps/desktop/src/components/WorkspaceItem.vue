<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem } from '../stores/workspaces'

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
}>()

const emit = defineEmits<{
  click: [item: WorkspaceItem]
  delete: [item: WorkspaceItem]
  addTask: [item: WorkspaceItem]
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
}>()

// Computed: check if item is expanded (tasks visible)
const isExpanded = computed(() => {
  const expanded = workspacesStore.expandedItemIds[props.item.id] === true
  console.log('[WorkspaceItem] isExpanded recompute:', props.item.id, expanded, 'store:', JSON.stringify(workspacesStore.expandedItemIds))
  return expanded
})

const handleClick = () => {
  // Toggle expanded state for collapse/expand
  workspacesStore.toggleExpandedItem(props.item.id)
  // Also emit click for external handling (e.g., navigation)
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
          <!-- Loading spinner -->
          <span v-if="item.isLoading" class="ml-auto">
            <svg class="animate-spin w-3 h-3" viewBox="0 0 24 24" fill="none">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
            </svg>
          </span>
          <!-- Active Indicator (for FolderExplorer selection) -->
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

      <!-- Tasks List (shown when expanded - allows multiple) -->
      <div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1 space-y-0.5">
        <button
          v-for="task in item.tasks"
          :key="task.id"
          class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
          :style="{
            color: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)',
            backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--semantic-active-bg)' : 'transparent',
          }"
          @click="handleSelectTask(task.id)"
        >
          <!-- Spinner while worker is processing this task (mirrors ChatsList.vue:489-497, scaled down to fit 12px text). Bullet is hidden while the spinner is shown so the row has a single, clear visual marker. -->
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
          <!-- Bullet point (only when not processing) -->
          <span
            v-else
            class="w-1.5 h-1.5 rounded-full shrink-0"
            :style="{ backgroundColor: workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text-dim)' }"
          />
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
        </button>
      </div>
    </div>
  </li>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import WorkspaceList from './WorkspaceList.vue'
import WorkspaceModal from './WorkspaceModal.vue'
import AddItemDialog from './AddItemDialog.vue'
import AddTaskDialog from './AddTaskDialog.vue'
import ConfirmDialog from './ConfirmDialog.vue'
import type { WorkspaceItem } from '../stores/workspaces'

interface NavItem {
  id: string
  label: string
  icon: string
  active?: boolean
}

const emit = defineEmits<{
  navigate: [id: string, chatName?: string]
}>()

const workspacesStore = useWorkspacesStore()

// Nav section collapsible state
const navExpanded = ref(true)

// Chats persistence key
const CHATS_STORAGE_KEY = 'nalar-chats'

// Load persisted chats from localStorage
function loadChats(): NavItem[] {
  try {
    const stored = localStorage.getItem(CHATS_STORAGE_KEY)
    if (stored) {
      return JSON.parse(stored)
    }
  } catch {
    // Ignore errors
  }
  return []
}

// Save chats to localStorage
function saveChats(chats: NavItem[]) {
  try {
    localStorage.setItem(CHATS_STORAGE_KEY, JSON.stringify(chats))
  } catch {
    // Ignore errors
  }
}

const navItems = ref<NavItem[]>(loadChats())

// Add Chat Dialog state
const showAddChatDialog = ref(false)
const newChatName = ref('')
const newChatInput = ref<HTMLInputElement | null>(null)

// Modal state
const showAddWorkspaceModal = ref(false)
const showAddItemDialog = ref(false)
const addItemTargetWorkspaceId = ref<string | null>(null)

// Add Task Dialog state
const showAddTaskDialog = ref(false)
const addTaskTargetWorkspaceId = ref<string | null>(null)
const addTaskTargetItemId = ref<string | null>(null)

// Computed project name for task dialog
const addTaskProjectName = computed(() => {
  if (!addTaskTargetWorkspaceId.value || !addTaskTargetItemId.value) return ''
  const workspace = workspacesStore.workspaces.find((ws) => ws.id === addTaskTargetWorkspaceId.value)
  const item = workspace?.items.find((i) => i.id === addTaskTargetItemId.value)
  return item?.name || ''
})

const toggleNavSection = () => {
  navExpanded.value = !navExpanded.value
}

// Chat management
const openAddChatDialog = () => {
  newChatName.value = ''
  showAddChatDialog.value = true
  setTimeout(() => newChatInput.value?.focus(), 50)
}

const addChat = () => {
  if (newChatName.value.trim()) {
    navItems.value.push({
      id: `chat-${Date.now()}`,
      label: newChatName.value.trim(),
      icon: '💬',
      active: false,
    })
    saveChats(navItems.value)
    showAddChatDialog.value = false
    newChatName.value = ''
  }
}

const confirmDeleteChat = (chatId: string) => {
  openDeleteConfirm({
    title: 'Delete Chat',
    message: 'Are you sure you want to delete this chat? This action cannot be undone.',
    onConfirm: () => removeChat(chatId)
  })
}

const handleDeleteChatConfirm = () => {
  if (chatToDelete.value) {
    removeChat(chatToDelete.value)
  }
  chatToDelete.value = null
}

const removeChat = (chatId: string) => {
  const index = navItems.value.findIndex((item) => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
    saveChats(navItems.value)
    // If it was active, activate the first chat
    if (wasActive && navItems.value.length > 0 && navItems.value[0]) {
      navItems.value[0].active = true
      emit('navigate', navItems.value[0].id)
    }
  }
}

// Active chat info for passing to ChatView
const activeChatName = ref('')

// Delete confirmation dialog
const showDeleteChatDialog = ref(false)
const chatToDelete = ref<string | null>(null)

// Generic delete confirmation dialog
const showDeleteConfirm = ref(false)
const deleteConfirmConfig = ref<{
  title: string
  message: string
  onConfirm: () => void
} | null>(null)

const openDeleteConfirm = (config: { title: string; message: string; onConfirm: () => void }) => {
  deleteConfirmConfig.value = config
  showDeleteConfirm.value = true
}

const handleDeleteConfirm = () => {
  if (deleteConfirmConfig.value?.onConfirm) {
    deleteConfirmConfig.value.onConfirm()
  }
  showDeleteConfirm.value = false
  deleteConfirmConfig.value = null
}

const setActive = (id: string) => {
  const chat = navItems.value.find((item) => item.id === id)
  activeChatName.value = chat?.label || ''
  
  navItems.value = navItems.value.map((item) => ({
    ...item,
    active: item.id === id,
  }))
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  emit('navigate', id, activeChatName.value)
}

// Workspace handlers
const handleToggleWorkspace = (workspaceId: string) => {
  workspacesStore.toggleWorkspace(workspaceId)
}

const handleSelectItem = async (workspaceId: string, itemId: string) => {
  // Clear active task when selecting a new item
  workspacesStore.setActiveTask(null)

  const workspace = workspacesStore.workspaces.find((ws) => ws.id === workspaceId)
  const item = workspace?.items.find((i) => i.id === itemId)

  // If item has a path and hasn't been loaded, fetch contents
  if (item?.path && !item.isLoaded && !item.isLoading) {
    await workspacesStore.fetchFolderContents(workspaceId, itemId)
  }

  // Deactivate main nav items
  navItems.value = navItems.value.map((navItem) => ({
    ...navItem,
    active: false,
  }))
  // Set active workspace item
  workspacesStore.setActiveWorkspaceItem(itemId)
  emit('navigate', 'workspace')
}

const handleDeleteWorkspace = (workspaceId: string) => {
  openDeleteConfirm({
    title: 'Delete Workspace',
    message: 'Are you sure you want to delete this workspace and all its items?',
    onConfirm: () => workspacesStore.removeWorkspace(workspaceId)
  })
}

const handleDeleteItem = (workspaceId: string, itemId: string) => {
  openDeleteConfirm({
    title: 'Delete Project',
    message: 'Are you sure you want to delete this project?',
    onConfirm: () => workspacesStore.removeWorkspaceItem(workspaceId, itemId)
  })
}

const handleAddItem = (workspaceId: string) => {
  addItemTargetWorkspaceId.value = workspaceId
  showAddItemDialog.value = true
}

const handleCreateItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    const itemId = workspacesStore.addWorkspaceItem(addItemTargetWorkspaceId.value, name, path)
    // Fetch folder contents immediately after adding
    if (itemId) {
      await workspacesStore.fetchFolderContents(addItemTargetWorkspaceId.value, itemId)
    }
  }
}

const handleCloseAddItemDialog = () => {
  showAddItemDialog.value = false
  addItemTargetWorkspaceId.value = null
}

const handleAddWorkspace = () => {
  showAddWorkspaceModal.value = true
}

const handleCreateWorkspace = (name: string, icon: string) => {
  workspacesStore.addWorkspace(name, icon)
}

const handleCloseModal = () => {
  showAddWorkspaceModal.value = false
}

// Task handlers
const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  addTaskTargetWorkspaceId.value = workspaceId
  addTaskTargetItemId.value = item.id
  showAddTaskDialog.value = true
}

const handleCreateTask = (name: string, description?: string) => {
  if (addTaskTargetWorkspaceId.value && addTaskTargetItemId.value) {
    workspacesStore.addTask(addTaskTargetWorkspaceId.value, addTaskTargetItemId.value, name, description)
  }
}

const handleCloseAddTaskDialog = () => {
  showAddTaskDialog.value = false
  addTaskTargetWorkspaceId.value = null
  addTaskTargetItemId.value = null
}

const handleDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  openDeleteConfirm({
    title: 'Delete Task',
    message: 'Are you sure you want to delete this task?',
    onConfirm: () => workspacesStore.deleteTask(workspaceId, itemId, taskId)
  })
}

const handleSelectTask = (taskId: string) => {
  workspacesStore.setActiveTask(taskId)
  emit('navigate', 'task')
}
</script>

<template>
  <aside
    class="w-72 h-screen flex flex-col"
    style="background-color: var(--semantic-sidebar-bg); border-right: 1px solid var(--semantic-sidebar-border);"
  >
    <!-- Logo Area -->
    <div
      class="h-16 flex items-center px-5 shrink-0"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-3">
        <div
          class="w-8 h-8 rounded-lg flex items-center justify-center"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));"
        >
          <span
            class="text-sm font-bold"
            style="color: var(--color-bg);"
          >N</span>
        </div>
        <span
          class="text-lg font-semibold tracking-tight"
          style="color: var(--semantic-text);"
        >Nalar</span>
      </div>
    </div>

    <!-- Navigation -->
    <nav class="flex-1 py-4 px-3 overflow-y-auto">
      <!-- Nav Section Header - Clickable to collapse/expand -->
      <div 
        class="px-3 py-2 flex items-center justify-between cursor-pointer hover:opacity-80 transition-opacity mb-1"
        @click="toggleNavSection"
      >
        <span
          class="text-xs font-semibold uppercase tracking-wider"
          style="color: var(--semantic-text-dim);"
        >Chats</span>
        <div class="flex items-center gap-2">
          <button
            @click.stop="openAddChatDialog"
            class="w-5 h-5 rounded flex items-center justify-center transition-colors duration-200 hover:opacity-80"
            style="color: var(--semantic-text-dim);"
            title="Add Chat"
          >
            <span class="text-sm">+</span>
          </button>
          <span 
            class="text-xs transition-transform duration-200" 
            :style="{ transform: navExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
            style="color: var(--semantic-text-dim);"
          >▶</span>
        </div>
      </div>

      <!-- Main Nav Items -->
      <Transition name="collapse">
        <ul v-show="navExpanded" class="space-y-1">
          <li v-for="item in navItems" :key="item.id" class="group/chat">
            <button
              @click="setActive(item.id)"
              class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200"
              :style="item.active
                ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
                : `color: var(--semantic-text-muted);`"
            >
              <span
                class="text-lg transition-transform duration-200"
                :style="!item.active ? 'opacity: 0.7;' : ''"
              >{{ item.icon }}</span>
              <span class="flex-1 text-left truncate">{{ item.label }}</span>
              <span
                v-if="item.active"
                class="w-1.5 h-1.5 rounded-full"
                style="background-color: var(--color-aqua);"
              />
              <!-- Delete Chat Button -->
              <button
                v-if="item.id !== 'chat'"
                @click.stop="confirmDeleteChat(item.id)"
                class="w-5 h-5 rounded flex items-center justify-center opacity-0 group-hover/chat:opacity-100 transition-opacity duration-200 hover:text-red-400"
                style="color: var(--semantic-text-dim);"
                title="Delete Chat"
              >
                <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </button>
          </li>
        </ul>
      </Transition>

      <!-- Divider -->
      <div
        class="my-4 h-px"
        style="background: linear-gradient(90deg, transparent, var(--color-border), transparent);"
      />

      <!-- Workspaces List Component -->
      <WorkspaceList
        :workspaces="workspacesStore.workspaces"
        :active-workspace-item-id="workspacesStore.activeWorkspaceItemId"
        @toggle-workspace="handleToggleWorkspace"
        @select-item="handleSelectItem"
        @delete-workspace="handleDeleteWorkspace"
        @delete-item="handleDeleteItem"
        @request-add-item="handleAddItem"
        @add-workspace="handleAddWorkspace"
        @add-task="handleAddTask"
        @select-task="handleSelectTask"
        @delete-task="handleDeleteTask"
      />
    </nav>

    <!-- Status / Footer -->
    <div
      class="p-4 shrink-0"
      style="border-top: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-3">
        <div
          class="w-9 h-9 rounded-full flex items-center justify-center text-sm font-medium"
          style="background: linear-gradient(135deg, var(--color-green), var(--color-aqua)); color: var(--color-bg);"
        >
          U
        </div>
        <div class="flex-1 min-w-0">
          <p
            class="text-sm font-medium truncate"
            style="color: var(--semantic-text);"
          >User</p>
          <p
            class="text-xs flex items-center gap-1"
            style="color: var(--semantic-text-muted);"
          >
            <span
              class="w-1.5 h-1.5 rounded-full"
              style="background-color: var(--semantic-success);"
            />
            Online
          </p>
        </div>
      </div>
    </div>

    <!-- Add Workspace Modal -->
    <WorkspaceModal
      :show="showAddWorkspaceModal"
      @close="handleCloseModal"
      @create="handleCreateWorkspace"
    />

    <!-- Add Item Dialog -->
    <AddItemDialog
      :show="showAddItemDialog"
      @close="handleCloseAddItemDialog"
      @create="handleCreateItem"
    />

    <!-- Add Task Dialog -->
    <AddTaskDialog
      :show="showAddTaskDialog"
      :project-name="addTaskProjectName"
      @close="handleCloseAddTaskDialog"
      @create="handleCreateTask"
    />

    <!-- Add Chat Dialog -->
    <Teleport to="body">
      <Transition name="modal">
        <div
          v-if="showAddChatDialog"
          class="fixed inset-0 z-50 flex items-center justify-center"
          @click.self="showAddChatDialog = false"
        >
          <!-- Backdrop -->
          <div
            class="absolute inset-0 bg-black/60 backdrop-blur-sm"
            @click="showAddChatDialog = false"
          />

          <!-- Dialog Content -->
          <div
            class="relative w-full max-w-sm mx-4 rounded-xl shadow-2xl"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          >
            <div class="px-5 pt-5 pb-4">
              <h3 class="text-base font-semibold" style="color: var(--semantic-text);">
                New Chat
              </h3>
            </div>

            <div class="px-5 pb-4">
              <input
                ref="newChatInput"
                v-model="newChatName"
                type="text"
                placeholder="Chat name..."
                class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                @keydown.enter="addChat"
                @keydown.escape="showAddChatDialog = false"
              />
            </div>

            <div class="px-5 pb-5 flex justify-end gap-2">
              <button
                @click="showAddChatDialog = false"
                class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
                style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
              >
                Cancel
              </button>
              <button
                @click="addChat"
                :disabled="!newChatName.trim()"
                class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
                style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
              >
                Create
              </button>
            </div>
          </div>
        </div>
      </Transition>
    </Teleport>

    <!-- Delete Chat Confirmation Dialog -->
    <ConfirmDialog
      :show="showDeleteConfirm"
      :title="deleteConfirmConfig?.title || 'Confirm'"
      :message="deleteConfirmConfig?.message || ''"
      confirm-text="Delete"
      @close="showDeleteConfirm = false; deleteConfirmConfig = null"
      @confirm="handleDeleteConfirm"
    />
  </aside>
</template>

<style scoped>
/* Collapse transition for nav section */
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
  max-height: 200px;
}
</style>

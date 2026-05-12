<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import WorkspaceList from './WorkspaceList.vue'
import WorkspaceModal from './WorkspaceModal.vue'
import AddItemDialog from './AddItemDialog.vue'
import ConfirmDialog from './ConfirmDialog.vue'
import type { WorkspaceItem } from '../stores/workspaces'
import * as api from '../api'

interface NavItem {
  id: string
  name: string
  icon: string
  active?: boolean
}

const props = defineProps<{
  collapsed?: boolean
  width?: number
}>()

const emit = defineEmits<{
  navigate: [id: string, chatName?: string]
  'toggle-collapse': []
  resize: [width: number]
}>()

// Expose method to update chat ID (called from parent when session is created)
const updateChatId = (oldId: string, newId: string) => {
  const chatItem = navItems.value.find(item => item.id === oldId)
  if (chatItem) {
    chatItem.id = newId
  }
}

// Expose navItems ref for parent access
defineExpose({
  updateChatId
})

const workspacesStore = useWorkspacesStore()
const sidebarStore = useSidebarStore()

// Sidebar collapse state
const isCollapsed = computed(() => props.collapsed ?? false)
const sidebarWidth = computed(() => props.width ?? 288)
const minWidth = 72 // Icon-only width
const maxWidth = 480

// Resize handle state
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)

const startResize = (e: MouseEvent | TouchEvent) => {
  isResizing.value = true
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  resizeStartX.value = clientX
  resizeStartWidth.value = sidebarWidth.value

  document.addEventListener('mousemove', handleResize)
  document.addEventListener('mouseup', stopResize)
  document.addEventListener('touchmove', handleResize)
  document.addEventListener('touchend', stopResize)

  // Prevent text selection during resize
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'col-resize'
}

const handleResize = (e: MouseEvent | TouchEvent) => {
  if (!isResizing.value) return

  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  const deltaX = clientX - resizeStartX.value
  const newWidth = Math.max(minWidth, Math.min(maxWidth, resizeStartWidth.value + deltaX))

  emit('resize', newWidth)
}

const stopResize = () => {
  isResizing.value = false
  document.removeEventListener('mousemove', handleResize)
  document.removeEventListener('mouseup', stopResize)
  document.removeEventListener('touchmove', handleResize)
  document.removeEventListener('touchend', stopResize)

  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

// Chats container height (for drag-to-resize) - managed by sidebar store
const isChatsResizing = ref(false)
const chatsResizeStartY = ref(0)
const chatsResizeStartHeight = ref(0)

// Chats resize handlers
const chatsContainerRef = ref<HTMLElement | null>(null)

const startChatsResize = (e: MouseEvent | TouchEvent) => {
  isChatsResizing.value = true
  const clientY = 'touches' in e && e.touches[0] ? e.touches[0].clientY : (e as MouseEvent).clientY
  chatsResizeStartY.value = clientY
  chatsResizeStartHeight.value = sidebarStore.chatsHeight

  document.addEventListener('mousemove', handleChatsResize)
  document.addEventListener('mouseup', stopChatsResize)
  document.addEventListener('touchmove', handleChatsResize)
  document.addEventListener('touchend', stopChatsResize)

  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'row-resize'
}

const handleChatsResize = (e: MouseEvent | TouchEvent) => {
  if (!isChatsResizing.value) return

  const clientY = 'touches' in e && e.touches[0] ? e.touches[0].clientY : (e as MouseEvent).clientY
  const sidebarEl = (window.event?.target as HTMLElement)?.closest('aside')
  if (!sidebarEl) return

  const sidebarHeight = sidebarEl.clientHeight - 64 - 48 // minus header and footer
  const deltaY = clientY - chatsResizeStartY.value
  const deltaPercent = (deltaY / sidebarHeight) * 100
  const newHeight = chatsResizeStartHeight.value + deltaPercent

  sidebarStore.setChatsHeight(newHeight)
}

// Handle scroll for infinite scroll pagination
const handleChatsScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const scrollBottom = target.scrollHeight - target.scrollTop - target.clientHeight
  // Load more when user scrolls to within 100px of bottom
  if (scrollBottom < 100 && chatsHasMore.value && !chatsLoading.value) {
    console.log('[Sidebar] Scroll triggered loadMoreChats')
    loadMoreChats()
  }
}

const stopChatsResize = () => {
  isChatsResizing.value = false
  document.removeEventListener('mousemove', handleChatsResize)
  document.removeEventListener('mouseup', stopChatsResize)
  document.removeEventListener('touchmove', handleChatsResize)
  document.removeEventListener('touchend', stopChatsResize)

  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

onUnmounted(() => {
  stopResize()
  stopChatsResize()
})

const toggleCollapse = () => {
  emit('toggle-collapse')
}

// Nav section collapsible state
const navExpanded = ref(true)

// Loading state
const chatsLoading = ref(false)

// Chats list
const navItems = ref<NavItem[]>([])

// Pagination state
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)

// LocalStorage key for persistent sort preference
const SORT_DIRECTION_KEY = 'nalar_chats_sort_direction'

// Sort state for chats (loaded from localStorage for persistence)
const chatsSortBy = ref<'created_at' | 'session_name' | 'agent'>('created_at')
const chatsSortDirection = ref<'asc' | 'desc'>(loadSortDirection())

// Load sort direction from localStorage
function loadSortDirection(): 'asc' | 'desc' {
  const stored = localStorage.getItem(SORT_DIRECTION_KEY)
  if (stored === 'asc' || stored === 'desc') {
    return stored
  }
  return 'desc' // Default to newest
}

// Load chats from API on mount
onMounted(async () => {
  await loadChats()
})

// Load chats with current sort settings (initial load or refresh)
const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  try {
    console.log('[Sidebar] loadChats - calling getChats with limit 10')
    const data = await api.getChats(chatsSortBy.value, chatsSortDirection.value, 10)
    console.log('[Sidebar] loadChats - received data:', { count: data.sessions?.length, hasMore: data.has_more, nextCursor: data.next_cursor })
    navItems.value = (data.sessions || []).map((session) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      icon: '💬',
      active: false,
    }))
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
    console.log('[Sidebar] loadChats - state after load:', { totalItems: navItems.value.length, hasMore: chatsHasMore.value, cursor: chatsNextCursor.value })
  } catch (err) {
    console.error('Failed to load chats:', err)
    navItems.value = []
    chatsHasMore.value = false
    chatsNextCursor.value = null
  } finally {
    chatsLoading.value = false
  }
}

// Load more chats (pagination)
const loadMoreChats = async () => {
  console.log('[Sidebar] loadMoreChats called:', { hasMore: chatsHasMore.value, loading: chatsLoading.value, cursor: chatsNextCursor.value })
  if (!chatsHasMore.value || chatsLoading.value || !chatsNextCursor.value) {
    console.log('[Sidebar] loadMoreChats blocked by condition')
    return
  }
  
  chatsLoading.value = true
  try {
    console.log('[Sidebar] Fetching with cursor:', chatsNextCursor.value)
    const data = await api.getChats(chatsSortBy.value, chatsSortDirection.value, 10, chatsNextCursor.value)
    console.log('[Sidebar] Received data:', { count: data.sessions?.length, hasMore: data.has_more, nextCursor: data.next_cursor })
    const newItems = (data.sessions || []).map((session) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      icon: '💬',
      active: false,
    }))
    navItems.value.push(...newItems)
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
    console.log('[Sidebar] Updated state:', { totalItems: navItems.value.length, hasMore: chatsHasMore.value, cursor: chatsNextCursor.value })
  } catch (err) {
    console.error('Failed to load more chats:', err)
  } finally {
    chatsLoading.value = false
  }
}

// Handle sort change (also saves to localStorage for persistence)
const handleSortChange = async () => {
  localStorage.setItem(SORT_DIRECTION_KEY, chatsSortDirection.value)
  await loadChats()
}

// Dialog states
const showAddWorkspaceModal = ref(false)
const showAddItemDialog = ref(false)
const addItemTargetWorkspaceId = ref<string | null>(null)
// Chat management - direct creation without dialog
// Session is created lazily when user sends first message
const createChat = () => {
  const name = `New Chat ${new Date().toLocaleTimeString()}`

  // Generate local-only ID (session will be created on first message send)
  const newChatId = `session-${Date.now()}`

  // Deactivate all other chats
  navItems.value.forEach(item => item.active = false)

  navItems.value.push({
    id: newChatId,
    name: name,
    icon: '💬',
    active: true,
  })

  // Navigate to the new chat
  activeChatName.value = name
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  emit('navigate', `chat-${newChatId}`, name)
}

const toggleNavSection = () => {
  navExpanded.value = !navExpanded.value
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

const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex((item) => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)

    // Sync with API
    try {
      await api.deleteChat(chatId)
    } catch (err) {
      console.error('Failed to delete chat:', err)
      // Note: We don't rollback on error since the item is already removed from UI
    }

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
  activeChatName.value = chat?.name || ''

  navItems.value = navItems.value.map((item) => ({
    ...item,
    active: item.id === id,
  }))
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  // Emit with 'chat-' prefix to match App.vue's expectation
  emit('navigate', `chat-${id}`, activeChatName.value)
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

const handleAddItem = (workspaceId: string, itemType: string) => {
  addItemTargetWorkspaceId.value = workspaceId
  if (itemType === 'folder') {
    showAddItemDialog.value = true
  }
  // Future: for 'markdown' type, show markdown dialog
}

const handleCreateItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    const itemId = await workspacesStore.addWorkspaceItem(addItemTargetWorkspaceId.value, name, path)
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

// Task handlers - Add Task creates a task item and opens TaskDetail view
const handleAddTask = async (workspaceId: string, item: WorkspaceItem) => {
  // Create a new task using the store API
  const name = `New Task ${new Date().toLocaleTimeString()}`
  const taskId = await workspacesStore.addTask(workspaceId, item.id, name)

  if (taskId) {
    // Set active task (setActiveTask auto-sets parent workspace item and expands)
    workspacesStore.setActiveTask(taskId)

    // Navigate to task view (shows TaskDetail with ChatView-like interface)
    emit('navigate', 'task')
  }
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
    class="h-screen flex flex-col relative transition-all duration-300 ease-out"
    :style="{
      width: isCollapsed ? '72px' : sidebarWidth + 'px',
      backgroundColor: 'var(--semantic-sidebar-bg)',
      borderRight: '1px solid var(--semantic-sidebar-border)'
    }"
  >
    <!-- Resize Handle (right edge) -->
    <div
      v-if="!isCollapsed"
      class="absolute right-0 top-0 bottom-0 w-1 cursor-col-resize z-10 group/resize"
      @mousedown="startResize"
      @touchstart="startResize"
    >
      <div
        class="w-full h-full transition-opacity duration-200 group-hover/resize:opacity-100 opacity-0"
        style="background-color: var(--color-violet);"
      />
    </div>

    <!-- Collapse Toggle Button -->
    <button
      @click="toggleCollapse"
      class="absolute -right-3 top-20 z-20 w-6 h-6 rounded-full flex items-center justify-center transition-all duration-200 hover:scale-110"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); box-shadow: 0 2px 8px rgba(0,0,0,0.2);"
      :title="isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'"
    >
      <span
        class="text-xs transition-transform duration-300"
        :style="{ transform: isCollapsed ? 'rotate(0deg)' : 'rotate(180deg)' }"
        style="color: var(--semantic-text-muted);"
      >
        <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
        </svg>
      </span>
    </button>

    <!-- Logo Area -->
    <div
      class="h-16 flex items-center shrink-0 transition-all duration-300"
      :class="isCollapsed ? 'justify-center px-0' : 'px-5'"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-3" :class="isCollapsed ? 'flex-col' : ''">
        <div
          class="w-8 h-8 rounded-lg flex items-center justify-center shrink-0"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));"
        >
          <span
            class="text-sm font-bold"
            style="color: var(--color-bg);"
          >N</span>
        </div>
        <span
          v-if="!isCollapsed"
          class="text-lg font-semibold tracking-tight whitespace-nowrap"
          style="color: var(--semantic-text);"
        >Nalar</span>
      </div>
    </div>

    <!-- Navigation -->
    <nav class="flex-1 flex flex-col py-4 overflow-hidden transition-all duration-300" :class="isCollapsed ? 'px-2' : 'px-3'">
      <!-- Nav Section Header - Clickable to collapse/expand (only when expanded) -->
      <div
        v-if="!isCollapsed"
        class="py-2 flex items-center justify-between cursor-pointer hover:opacity-80 transition-opacity mb-1 shrink-0"
        @click="toggleNavSection"
      >
        <span
          class="text-xs font-semibold uppercase tracking-wider"
          style="color: var(--semantic-text-dim);"
        >Chats</span>
        <div class="flex items-center gap-2">
          <!-- Sort Dropdown -->
          <select
            v-model="chatsSortDirection"
            @change="handleSortChange"
            @click.stop
            class="text-xs px-1 py-0.5 rounded border-none cursor-pointer transition-colors"
            style="background-color: var(--semantic-card-bg); color: var(--semantic-text-dim);"
            title="Sort direction"
          >
            <option value="desc">↓ Newest</option>
            <option value="asc">↑ Oldest</option>
          </select>
          <button
            @click.stop="createChat"
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

      <!-- Add Chat Button (visible when collapsed) -->
      <div v-if="isCollapsed" class="mb-2 shrink-0">
        <button
          @click.stop="createChat"
          class="w-full py-2 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-dim);"
          title="Add Chat"
        >
          <span class="text-lg">+</span>
        </button>
      </div>

      <!-- Chats List Container with Resizable Height -->
      <div
        v-if="!isCollapsed && navExpanded"
        class="shrink-0 flex flex-col"
        :style="{ height: sidebarStore.chatsHeight + '%' }"
      >
        <!-- Main Nav Items -->
        <ul 
          ref="chatsContainerRef"
          @scroll="handleChatsScroll"
          class="flex-1 overflow-y-auto space-y-1 min-h-0"
        >
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
              <span class="flex-1 text-left truncate min-w-0">{{ item.name }}</span>
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

        <!-- Loading/Load More Indicator -->
        <div v-if="chatsLoading && navItems.length > 0" class="py-2 text-center">
          <span class="text-xs" style="color: var(--semantic-text-dim);">Loading more...</span>
        </div>
        
        <!-- Load More Button (fallback for when scroll doesn't trigger) -->
        <button 
          v-else-if="chatsHasMore && navItems.length > 0"
          @click="loadMoreChats"
          class="py-2 text-xs hover:opacity-80 transition-opacity"
          style="color: var(--color-violet);"
        >
          Load more chats
        </button>

        <!-- Drag Resize Handle (between chats and workspaces) -->
        <div
          class="h-2 cursor-row-resize flex items-center justify-center group/resize shrink-0"
          @mousedown="startChatsResize"
          @touchstart="startChatsResize"
        >
          <div
            class="w-full h-px transition-all duration-200 group-hover/resize:h-1"
            style="background: linear-gradient(90deg, transparent, var(--color-border), transparent);"
          />
        </div>
      </div>

      <!-- Collapsed Chat Items -->
      <ul v-show="isCollapsed" class="space-y-1 shrink-0">
        <li v-for="item in navItems" :key="item.id">
          <button
            @click="setActive(item.id)"
            class="w-full py-2 rounded-lg flex items-center justify-center transition-all duration-200 relative"
            :style="item.active
              ? `background-color: var(--semantic-active-bg);`
              : ''"
            :title="item.name"
          >
            <span class="text-lg">{{ item.icon }}</span>
            <span
              v-if="item.active"
              class="absolute bottom-1 w-1.5 h-1.5 rounded-full"
              style="background-color: var(--color-aqua);"
            />
          </button>
        </li>
      </ul>

      <!-- Workspaces List Component - Takes remaining space -->
      <div class="flex-1 min-h-0 overflow-hidden">
        <WorkspaceList
          v-if="!isCollapsed"
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
      </div>

      <!-- Collapsed Workspace Icons -->
      <div v-if="isCollapsed" class="space-y-1">
        <button
          v-for="workspace in workspacesStore.workspaces"
          :key="workspace.id"
          @click="handleToggleWorkspace(workspace.id)"
          class="w-full py-2 rounded-lg flex items-center justify-center transition-all duration-200 relative"
          :style="workspace.expanded ? 'background-color: var(--semantic-active-bg);' : ''"
          :title="workspace.name"
        >
          <span class="text-lg">{{ workspace.icon }}</span>
        </button>
        <!-- Add Workspace Button -->
        <button
          @click="handleAddWorkspace"
          class="w-full py-2 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
          style="color: var(--semantic-text-dim);"
          title="Add Workspace"
        >
          <span class="text-lg">+</span>
        </button>
      </div>
    </nav>

    <!-- Status / Footer -->
    <div
      class="shrink-0 transition-all duration-300"
      >
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

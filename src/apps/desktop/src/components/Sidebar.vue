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

const props = defineProps<{
  collapsed?: boolean
  width?: number
}>()

const emit = defineEmits<{
  navigate: [id: string, chatName?: string, taskId?: string]
  'toggle-collapse': []
  resize: [width: number]
}>()

// Expose method to update chat ID
const updateChatId = (oldId: string, newId: string) => {
  const chatItem = navItems.value.find(item => item.id === oldId)
  if (chatItem) {
    chatItem.id = newId
  }
}

defineExpose({ updateChatId })

const workspacesStore = useWorkspacesStore()
const sidebarStore = useSidebarStore()

// State
const isCollapsed = computed(() => props.collapsed ?? false)
const sidebarWidth = computed(() => props.width ?? 280)
const activeChatName = ref('')
const chatsLoading = ref(false)
const navItems = ref<{ id: string; name: string; icon: string; active?: boolean }[]>([])
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>(loadSortDirection())

// Dialog states
const showAddWorkspaceModal = ref(false)
const showAddItemDialog = ref(false)
const addItemTargetWorkspaceId = ref<string | null>(null)
const showDeleteConfirm = ref(false)
const deleteConfirmConfig = ref<{ title: string; message: string; onConfirm: () => void } | null>(null)

// Resize handling
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)
const chatsContainerRef = ref<HTMLElement | null>(null)

// Chats resize handling
const isChatsResizing = ref(false)
const chatsResizeStartY = ref(0)
const chatsResizeStartPx = ref(0)

// Get computed chats height in pixels from percentage
const getChatsHeightPx = (): number => {
  const aside = document.querySelector('aside')
  if (!aside) return 200
  const navHeight = aside.clientHeight - 56 - 48 // header + footer
  return (navHeight * sidebarStore.chatsHeight) / 100
}

const startChatsResize = (e: MouseEvent) => {
  e.preventDefault()
  e.stopPropagation()
  console.log('[Sidebar] startChatsResize', e.clientY)
  isChatsResizing.value = true
  chatsResizeStartY.value = e.clientY
  chatsResizeStartPx.value = getChatsHeightPx()
  document.addEventListener('mousemove', handleChatsResize, { passive: false })
  document.addEventListener('mouseup', stopChatsResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'row-resize'
}

const handleChatsResize = (e: MouseEvent) => {
  e.preventDefault()
  if (!isChatsResizing.value) return
  console.log('[Sidebar] handleChatsResize', e.clientY, 'delta:', e.clientY - chatsResizeStartY.value)
  const deltaY = e.clientY - chatsResizeStartY.value
  const newHeightPx = Math.max(80, chatsResizeStartPx.value + deltaY)
  // Convert back to percentage
  const aside = document.querySelector('aside')
  if (!aside) return
  const navHeight = aside.clientHeight - 56 - 48
  const newPercent = (newHeightPx / navHeight) * 100
  console.log('[Sidebar] newPercent:', newPercent)
  sidebarStore.setChatsHeight(newPercent)
}

const stopChatsResize = () => {
  isChatsResizing.value = false
  document.removeEventListener('mousemove', handleChatsResize)
  document.removeEventListener('mouseup', stopChatsResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

const startResize = (e: MouseEvent | TouchEvent) => {
  isResizing.value = true
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  resizeStartX.value = clientX
  resizeStartWidth.value = sidebarWidth.value
  document.addEventListener('mousemove', handleResize)
  document.addEventListener('mouseup', stopResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'col-resize'
}

const handleResize = (e: MouseEvent | TouchEvent) => {
  if (!isResizing.value) return
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  const deltaX = clientX - resizeStartX.value
  const newWidth = Math.max(72, Math.min(480, resizeStartWidth.value + deltaX))
  emit('resize', newWidth)
}

const stopResize = () => {
  isResizing.value = false
  document.removeEventListener('mousemove', handleResize)
  document.removeEventListener('mouseup', stopResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

const handleChatsScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const scrollBottom = target.scrollHeight - target.scrollTop - target.clientHeight
  if (scrollBottom < 100 && chatsHasMore.value && !chatsLoading.value) {
    loadMoreChats()
  }
}

onUnmounted(() => {
  stopResize()
  stopChatsResize()
})

function loadSortDirection(): 'asc' | 'desc' {
  const stored = localStorage.getItem('nalar_chats_sort_direction')
  return stored === 'asc' ? 'asc' : 'desc'
}

onMounted(async () => {
  await loadChats()
})

const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  try {
    const data = await api.getChats('created_at', chatsSortDirection.value, 20)
    navItems.value = (data.sessions || []).map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      icon: '💬',
      active: false,
    }))
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
  } catch (err) {
    console.error('Failed to load chats:', err)
    navItems.value = []
  } finally {
    chatsLoading.value = false
  }
}

const loadMoreChats = async () => {
  if (!chatsHasMore.value || chatsLoading.value || !chatsNextCursor.value) return
  chatsLoading.value = true
  try {
    const data = await api.getChats('created_at', chatsSortDirection.value, 20, chatsNextCursor.value)
    const newItems = (data.sessions || []).map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      icon: '💬',
      active: false,
    }))
    navItems.value.push(...newItems)
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
  } catch (err) {
    console.error('Failed to load more chats:', err)
  } finally {
    chatsLoading.value = false
  }
}

const toggleCollapse = () => emit('toggle-collapse')
const toggleNavSection = () => sidebarStore.toggleNavExpanded()
const goToSettings = () => emit('navigate', 'settings')

const createChat = () => {
  const name = 'New Chat'
  const newChatId = `session-${Date.now()}`
  navItems.value.forEach(item => item.active = false)
  navItems.value.unshift({ id: newChatId, name, icon: '💬', active: true })
  activeChatName.value = name
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  emit('navigate', `chat-${newChatId}`, name)
}

const setActive = (id: string) => {
  const chat = navItems.value.find(item => item.id === id)
  activeChatName.value = chat?.name || ''
  navItems.value = navItems.value.map(item => ({ ...item, active: item.id === id }))
  workspacesStore.setActiveWorkspaceItem(null)
  workspacesStore.setActiveTask(null)
  emit('navigate', `chat-${id}`, activeChatName.value)
}

const confirmDeleteChat = (chatId: string) => {
  openDeleteConfirm({
    title: 'Delete Chat',
    message: 'Delete this chat?',
    onConfirm: () => removeChat(chatId)
  })
}

const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex(item => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
    try {
      await api.deleteChat(chatId)
    } catch (err) {
      console.error('Failed to delete chat:', err)
    }
    if (wasActive && navItems.value.length > 0 && navItems.value[0]) {
      navItems.value[0].active = true
      emit('navigate', navItems.value[0].id)
    }
  }
}

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

// Workspace handlers
const handleToggleWorkspace = (workspaceId: string) => workspacesStore.toggleWorkspace(workspaceId)

const handleSelectItem = async (workspaceId: string, itemId: string) => {
  workspacesStore.setActiveTask(null)
  const workspace = workspacesStore.workspaces.find(ws => ws.id === workspaceId)
  const item = workspace?.items.find(i => i.id === itemId)
  if (item?.path && !item.isLoaded && !item.isLoading) {
    await workspacesStore.fetchFolderContents(workspaceId, itemId)
  }
  navItems.value = navItems.value.map(navItem => ({ ...navItem, active: false }))
  workspacesStore.setActiveWorkspaceItem(itemId)
  emit('navigate', 'workspace')
}

const handleDeleteWorkspace = (workspaceId: string) => {
  openDeleteConfirm({
    title: 'Delete Workspace',
    message: 'Delete workspace and all items?',
    onConfirm: () => workspacesStore.removeWorkspace(workspaceId)
  })
}

const handleDeleteItem = (workspaceId: string, itemId: string) => {
  openDeleteConfirm({
    title: 'Delete Project',
    message: 'Delete this project?',
    onConfirm: () => workspacesStore.removeWorkspaceItem(workspaceId, itemId)
  })
}

const handleAddItem = (workspaceId: string, itemType: string) => {
  addItemTargetWorkspaceId.value = workspaceId
  if (itemType === 'folder') showAddItemDialog.value = true
}

const handleCreateItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    const itemId = await workspacesStore.addWorkspaceItem(addItemTargetWorkspaceId.value, name, path)
    if (itemId) await workspacesStore.fetchFolderContents(addItemTargetWorkspaceId.value, itemId)
  }
}

const handleAddWorkspace = () => showAddWorkspaceModal.value = true
const handleCreateWorkspace = (name: string, icon: string) => workspacesStore.addWorkspace(name, icon)
const handleCloseModal = () => showAddWorkspaceModal.value = false
const handleCloseAddItemDialog = () => { showAddItemDialog.value = false; addItemTargetWorkspaceId.value = null }

const handleAddTask = async (workspaceId: string, item: WorkspaceItem) => {
  const name = `Task ${new Date().toLocaleTimeString()}`
  const taskId = await workspacesStore.addTask(workspaceId, item.id, name)
  if (taskId) {
    workspacesStore.setActiveTask(taskId)
    emit('navigate', 'task')
  }
}

const handleDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  openDeleteConfirm({
    title: 'Delete Task',
    message: 'Delete this task?',
    onConfirm: () => workspacesStore.deleteTask(workspaceId, itemId, taskId)
  })
}

const handleSelectTask = (taskId: string) => {
  workspacesStore.setActiveTask(taskId)
  emit('navigate', 'task', undefined, taskId)
}
</script>

<template>
  <aside
    class="h-screen flex flex-col relative transition-all duration-200 ease-out select-none"
    :style="{
      width: isCollapsed ? '64px' : sidebarWidth + 'px',
      backgroundColor: 'var(--semantic-sidebar-bg)',
      borderRight: '1px solid var(--color-border)'
    }"
  >
    <!-- Resize Handle -->
    <div
      v-if="!isCollapsed"
      class="absolute right-0 top-0 bottom-0 w-1 cursor-col-resize z-10 opacity-0 hover:opacity-100 transition-opacity"
      style="background: var(--color-violet);"
      @mousedown="startResize"
    />

    <!-- Collapse Button -->
    <button
      @click="toggleCollapse"
      class="absolute -right-3 top-20 z-20 w-6 h-6 rounded-full flex items-center justify-center transition-all duration-200 hover:scale-110"
      style="background: var(--semantic-card-bg); border: 1px solid var(--color-border); box-shadow: 0 2px 8px rgba(0,0,0,0.15);"
    >
      <svg
        class="w-3 h-3 transition-transform duration-200"
        :style="{ transform: isCollapsed ? 'rotate(0deg)' : 'rotate(180deg)' }"
        style="color: var(--semantic-text-muted);"
        fill="none" viewBox="0 0 24 24" stroke="currentColor"
      >
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
      </svg>
    </button>

    <!-- Header -->
    <div
      class="h-14 flex items-center shrink-0"
      :class="isCollapsed ? 'justify-center px-0' : 'px-4 justify-between'"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div v-if="!isCollapsed" class="flex items-center gap-2">
        <div class="w-7 h-7 rounded-lg flex items-center justify-center" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));">
          <span class="text-xs font-bold" style="color: var(--color-bg);">N</span>
        </div>
        <span class="text-base font-semibold" style="color: var(--semantic-text);">Nalar</span>
      </div>
      <div v-else class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));">
        <span class="text-sm font-bold" style="color: var(--color-bg);">N</span>
      </div>
      <button
        v-if="!isCollapsed"
        @click="goToSettings"
        class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors hover:opacity-70"
        style="color: var(--semantic-text-muted);"
      >
        <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
      </button>
    </div>

    <!-- Content -->
    <nav class="flex-1 flex flex-col overflow-hidden" :class="isCollapsed ? 'px-2 py-3' : 'p-3'">

      <!-- Chats Section with Resizable Height -->
      <div v-if="!isCollapsed" class="shrink-0 flex flex-col" :style="sidebarStore.navExpanded ? { height: sidebarStore.chatsHeight + '%', minHeight: '80px' } : { height: 'auto', minHeight: '0' }">

        <!-- Header with expand/collapse toggle -->
        <button
          class="px-3 py-2 flex items-center gap-2 w-full text-left hover:opacity-70 transition-opacity shrink-0"
          @click="toggleNavSection"
        >
          <span
            class="text-xs transition-transform duration-200"
            :style="{ transform: sidebarStore.navExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
            style="color: var(--semantic-text-dim);"
          >▶</span>
          <span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--semantic-text-dim);">Chats</span>
          <div class="flex items-center gap-1 ml-auto" v-if="sidebarStore.navExpanded">
            <select
              v-model="chatsSortDirection"
              @change="loadChats"
              @click.stop
              class="text-xs px-1.5 py-0.5 rounded cursor-pointer"
              style="background: var(--semantic-card-bg); color: var(--semantic-text-dim); border: none;"
            >
              <option value="desc">↓</option>
              <option value="asc">↑</option>
            </select>
            <button
              @click.stop="createChat"
              class="w-5 h-5 rounded flex items-center justify-center transition-colors hover:opacity-70"
              style="color: var(--semantic-text-dim);"
              title="New Chat"
            >
              <span class="text-sm">+</span>
            </button>
          </div>
        </button>

        <!-- Chat List -->
        <div v-if="sidebarStore.navExpanded" class="flex-1 min-h-0 flex flex-col">
          <ul ref="chatsContainerRef" @scroll="handleChatsScroll" class="flex-1 overflow-y-auto space-y-0.5 min-h-0">
            <li v-for="item in navItems" :key="item.id" class="group/chat">
              <button
                @click="setActive(item.id)"
                class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150"
                :style="item.active
                  ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text);'
                  : 'color: var(--semantic-text-muted);'"
              >

                <span class="flex-1 text-left truncate">{{ item.name }}</span>
                <button
                  v-if="item.id !== 'chat'"
                  @click.stop="confirmDeleteChat(item.id)"
                  class="w-5 h-5 rounded flex items-center justify-center opacity-0 group-hover/chat:opacity-100 transition-opacity hover:text-red-400 shrink-0"
                  style="color: var(--semantic-text-dim);"
                >
                  <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </button>
            </li>
            <li v-if="chatsLoading" class="py-2 text-center">
              <span class="text-xs" style="color: var(--semantic-text-dim);">Loading...</span>
            </li>
            <li v-else-if="chatsHasMore">
              <button @click="loadMoreChats" class="w-full py-2 text-xs hover:opacity-70" style="color: var(--color-violet);">
                Load more
              </button>
            </li>
          </ul>

          <!-- Drag Resize Handle -->
          <div
            class="h-3 cursor-row-resize flex items-center justify-center group/resize shrink-0 mt-1"
            @mousedown="startChatsResize"
          >
            <div
              class="w-full h-0.5 transition-all duration-200 group-hover/resize:h-1 rounded"
              style="background: linear-gradient(90deg, transparent, var(--color-border), transparent);"
            />
          </div>
        </div>
      </div>

      <!-- Collapsed Chats Button -->
      <div v-else class="mb-3 shrink-0">
        <button
          @click="createChat"
          class="w-full h-10 rounded-lg flex items-center justify-center transition-colors hover:opacity-80"
          style="color: var(--semantic-text-muted);"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
        </button>
      </div>

      <!-- Workspaces -->
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
        <!-- Collapsed workspaces -->
        <div v-else class="space-y-0.5">
          <button
            v-for="workspace in workspacesStore.workspaces"
            :key="workspace.id"
            @click="handleToggleWorkspace(workspace.id)"
            class="w-full h-10 rounded-lg flex items-center justify-center transition-colors"
            :style="workspace.expanded ? 'background: var(--semantic-active-bg);' : ''"
            :title="workspace.name"
          >
            <span class="text-base">{{ workspace.icon }}</span>
          </button>
          <button
            @click="handleAddWorkspace"
            class="w-full h-10 rounded-lg flex items-center justify-center transition-colors hover:opacity-70"
            style="color: var(--semantic-text-dim);"
          >
            <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
          </button>
        </div>
      </div>
    </nav>

    <!-- Modals -->
    <WorkspaceModal :show="showAddWorkspaceModal" @close="handleCloseModal" @create="handleCreateWorkspace" />
    <AddItemDialog :show="showAddItemDialog" @close="handleCloseAddItemDialog" @create="handleCreateItem" />
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
/* Smooth transitions */
aside { transition: width 0.2s ease-out; }
</style>
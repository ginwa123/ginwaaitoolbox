<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted, inject, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import WorkspaceList from './WorkspaceList.vue'
import ChatsList from './ChatsList.vue'
import WorkspaceModal from './WorkspaceModal.vue'
import RenameWorkspaceModal from './RenameWorkspaceModal.vue'
import RenameTaskModal from './RenameTaskModal.vue'
import AddItemDialog from './AddItemDialog.vue'
import ConfirmDialog from './ConfirmDialog.vue'
import type { WorkspaceItem } from '../stores/workspaces'
import * as api from '../api'

// Inject isLLMProcessing from App.vue
const isLLMProcessing = inject<Ref<boolean>>('isLLMProcessing', ref(false))

const router = useRouter()
const navigationStore = useNavigationStore()

const props = defineProps<{
  collapsed?: boolean
  width?: number
}>()

const emit = defineEmits<{
  navigate: [id: string, chatName?: string, taskId?: string]
  'toggle-collapse': []
  resize: [width: number]
}>()

// ─── Chats State (moved from ChatsList) ──────────────────────────────────────
const navItems = ref<Array<{ id: string; name: string; icon: string; active?: boolean; processing?: boolean }>>([])
const chatsLoading = ref(false)
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>('desc')

// Expose method to update chat ID
const updateChatId = (oldId: string, newId: string) => {
  const chatItem = navItems.value.find(item => item.id === oldId)
  if (chatItem) {
    chatItem.id = newId
  }
}

// Handle session events from SSE
const handleSessionEvent = (event: api.SessionEvent) => {
  console.log('[Sidebar] handleSessionEvent:', event)
  // Refresh chats on session change
  if (chatsListRef.value) {
    chatsListRef.value.loadChats()
  }
}

defineExpose({ updateChatId })

const workspacesStore = useWorkspacesStore()
const sidebarStore = useSidebarStore()

// State
const isCollapsed = computed(() => props.collapsed ?? false)
const sidebarWidth = computed(() => props.width ?? 280)
const activeChatName = computed(() => navigationStore.activeChatName)

// Dialog states
const showAddWorkspaceModal = ref(false)
const showAddItemDialog = ref(false)
const addItemTargetWorkspaceId = ref<string | null>(null)
const showDeleteConfirm = ref(false)
const deleteConfirmConfig = ref<{ title: string; message: string; onConfirm: () => void } | null>(null)
const showRenameWorkspaceModal = ref(false)
const renameTargetWorkspaceId = ref<string | null>(null)
const renameTargetName = ref('')
const showRenameTaskModal = ref(false)
const renameTargetTaskWorkspaceId = ref<string | null>(null)
const renameTargetTaskItemId = ref<string | null>(null)
const renameTargetTaskId = ref<string | null>(null)
const renameTargetTaskName = ref('')

// Resize handling
const isResizing = ref(false)
const resizeStartX = ref(0)
const resizeStartWidth = ref(0)

// Ref to ChatsList component
const chatsListRef = ref<InstanceType<typeof ChatsList> | null>(null)

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

onUnmounted(() => {
  stopResize()
})

const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  try {
    const data = await api.getChats('created_at', chatsSortDirection.value, 20)
    const savedSessionId = navigationStore.sessionId
    navItems.value = (data.sessions || []).map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      icon: '💬',
      active: savedSessionId === session.session_id,
    }))
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor

    // If we found and activated a saved chat, restore it in AppLayout
    const activeItem = navItems.value.find(item => item.active)
    if (activeItem) {
      navigationStore.setActiveChatName(activeItem.name)
      emit('navigate', `chat-${activeItem.id}`, activeItem.name)
    }
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

// ─── Session Events SSE ────────────────────────────────────────────────────────
//
// Sidebar previously had a stub `connectSessionsSse` /
// `disconnectSessionsSse` pair that did nothing. The real
// sessions SSE connection lives in `ChatsList.vue` (which
// mounts alongside the sidebar). Sidebar exposes the chats
// list via a ref and doesn't need its own connection — the
// stubs have been removed as part of the SSE refactor.

const toggleCollapse = () => emit('toggle-collapse')
const goToSettings = () => emit('navigate', 'settings')

// Handle navigation events from ChatsList component
const handleChatsNavigate = (id: string, chatName?: string) => {
  if (id === 'delete-chat') {
    // Handle chat deletion request - chatName is actually the chatId
    const chatId = chatName
    if (chatId && chatsListRef.value) {
      openDeleteConfirm({
        title: 'Delete Chat',
        message: 'Delete this chat?',
        onConfirm: () => chatsListRef.value?.removeChat(chatId)
      })
    }
  } else if (id.startsWith('chat-')) {
    // Navigate to chat
    const sessionId = id.replace('chat-', '')
    navigationStore.setActiveChat(sessionId, chatName || '')
    workspacesStore.setActiveWorkspaceItem(null)
    workspacesStore.setActiveTask(null)
    router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
  } else {
    // Direct navigation
    emit('navigate', id, chatName)
  }
}

// Toggle nav section and reload chats if needed
const toggleNavSectionAndReload = () => {
  sidebarStore.toggleNavExpanded()
  // If expanding and no chats loaded yet, trigger load
  if (sidebarStore.navExpanded && chatsListRef.value) {
    chatsListRef.value.loadChats()
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
  // Reset active state in ChatsList component
  if (chatsListRef.value) {
    chatsListRef.value.resetActiveChat()
  }
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

const handleRenameWorkspace = (workspaceId: string, currentName: string) => {
  renameTargetWorkspaceId.value = workspaceId
  renameTargetName.value = currentName
  showRenameWorkspaceModal.value = true
}

const handleConfirmRename = async (newName: string) => {
  if (renameTargetWorkspaceId.value) {
    await workspacesStore.renameWorkspace(renameTargetWorkspaceId.value, newName)
  }
  showRenameWorkspaceModal.value = false
  renameTargetWorkspaceId.value = null
  renameTargetName.value = ''
}

const handleCloseRenameModal = () => {
  showRenameWorkspaceModal.value = false
  renameTargetWorkspaceId.value = null
  renameTargetName.value = ''
}

// ─── Rename Task ────────────────────────────────────────────────────────────
// Mirrors the workspace-rename pattern above. The state is split
// across four refs (workspace id, item id, task id, name) instead
// of a single object because the modal's emit('rename', name) only
// carries the name — the targets need to survive across the modal's
// close + reopen lifecycle.
const handleRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  renameTargetTaskWorkspaceId.value = workspaceId
  renameTargetTaskItemId.value = itemId
  renameTargetTaskId.value = taskId
  renameTargetTaskName.value = currentName
  showRenameTaskModal.value = true
}

const handleConfirmTaskRename = async (newName: string) => {
  if (
    renameTargetTaskWorkspaceId.value &&
    renameTargetTaskItemId.value &&
    renameTargetTaskId.value
  ) {
    await workspacesStore.renameTask(
      renameTargetTaskWorkspaceId.value,
      renameTargetTaskItemId.value,
      renameTargetTaskId.value,
      newName,
    )
  }
  showRenameTaskModal.value = false
  renameTargetTaskWorkspaceId.value = null
  renameTargetTaskItemId.value = null
  renameTargetTaskId.value = null
  renameTargetTaskName.value = ''
}

const handleCloseTaskRenameModal = () => {
  showRenameTaskModal.value = false
  renameTargetTaskWorkspaceId.value = null
  renameTargetTaskItemId.value = null
  renameTargetTaskId.value = null
  renameTargetTaskName.value = ''
}

const handleAddTask = async (workspaceId: string, item: WorkspaceItem) => {
  const name = `Task ${new Date().toLocaleTimeString()}`
  const taskId = await workspacesStore.addTask(workspaceId, item.id, name)
  if (taskId) {
    workspacesStore.setActiveTask(taskId)
    router.replace({ path: '/app', query: { view: 'task', task: taskId } })
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
  // Mutually exclusive active state: task wins, clear any active chat row in ChatsList.
  if (chatsListRef.value) {
    chatsListRef.value.resetActiveChat()
  }
  router.replace({ path: '/app', query: { view: 'task', task: taskId } })
}

const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  // Click-to-load pagination: invoked by the "Load more" button in
  // WorkspaceItem.vue. The store action is the only place that calls
  // api.getTasks with a cursor — no auto-load / scroll listener /
  // intersection observer. Mirrors the loadMoreChats pattern in
  // ChatsList.vue:121-183.
  workspacesStore.loadMoreTasks(workspaceId, itemId)
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

      <!-- Chats List Component -->
      <ChatsList
        ref="chatsListRef"
        :collapsed="isCollapsed"
        @navigate="handleChatsNavigate"
      />

      <!-- Workspaces -->
      <div class="flex-1 min-h-0 overflow-hidden">
        <WorkspaceList
          v-if="!isCollapsed"
          :workspaces="workspacesStore.workspaces"
          :active-workspace-item-id="workspacesStore.activeWorkspaceItemId"
          @toggle-workspace="handleToggleWorkspace"
          @select-item="handleSelectItem"
          @delete-workspace="handleDeleteWorkspace"
          @rename-workspace="handleRenameWorkspace"
          @delete-item="handleDeleteItem"
          @request-add-item="handleAddItem"
          @add-workspace="handleAddWorkspace"
          @add-task="handleAddTask"
          @select-task="handleSelectTask"
          @delete-task="handleDeleteTask"
          @rename-task="handleRenameTask"
          @load-more-tasks="handleLoadMoreTasks"
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
    <RenameWorkspaceModal :show="showRenameWorkspaceModal" :current-name="renameTargetName" @close="handleCloseRenameModal" @rename="handleConfirmRename" />
    <RenameTaskModal :show="showRenameTaskModal" :current-name="renameTargetTaskName" @close="handleCloseTaskRenameModal" @rename="handleConfirmTaskRename" />
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

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import Sidebar from './components/Sidebar.vue'
import FolderExplorer from './components/FolderExplorer.vue'
import Chats from './components/Chats.vue'
import ChatView from './components/ChatView.vue'
import TaskDetail from './components/TaskDetail.vue'
import { useWorkspacesStore } from './stores/workspaces'

const workspacesStore = useWorkspacesStore()
const activeView = ref('chat')
const activeChatId = ref('')
const activeChatName = ref('')

// Ref to Sidebar component for calling exposed methods
const sidebarRef = ref<InstanceType<typeof Sidebar> | null>(null)

// Sidebar collapse/expand state
const sidebarCollapsed = ref(false)
const sidebarWidth = ref(288) // Default w-72 = 288px
const minSidebarWidth = 72 // Collapsed width (icon-only)
const maxSidebarWidth = 480

// Load persisted state from localStorage
onMounted(() => {
  // Sidebar state
  const savedCollapsed = localStorage.getItem('sidebar-collapsed')
  if (savedCollapsed !== null) {
    sidebarCollapsed.value = savedCollapsed === 'true'
  }
  
  const savedWidth = localStorage.getItem('sidebar-width')
  if (savedWidth !== null) {
    const parsed = parseInt(savedWidth, 10)
    if (!isNaN(parsed)) {
      sidebarWidth.value = Math.max(minSidebarWidth, Math.min(maxSidebarWidth, parsed))
    }
  }
  
  // Active view state
  const savedView = localStorage.getItem('active-view')
  const savedChatId = localStorage.getItem('active-chat-id')
  const savedChatName = localStorage.getItem('active-chat-name')
  
  if (savedView) {
    activeView.value = savedView
  }
  if (savedChatId) {
    activeChatId.value = savedChatId
  }
  if (savedChatName) {
    activeChatName.value = savedChatName
  }
  
  // Initialize workspaces
  workspacesStore.initializeFromSystemFolder()
})

// Toggle sidebar collapsed state
const toggleSidebar = () => {
  if (sidebarCollapsed.value) {
    // Expanding - restore previous width
    sidebarCollapsed.value = false
  } else {
    // Collapsing - store current width and collapse
    sidebarCollapsed.value = true
  }
  localStorage.setItem('sidebar-collapsed', String(sidebarCollapsed.value))
}

// Handle sidebar resize from child
const handleSidebarResize = (newWidth: number) => {
  sidebarWidth.value = Math.max(minSidebarWidth, Math.min(maxSidebarWidth, newWidth))
  localStorage.setItem('sidebar-width', String(sidebarWidth.value))
}

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)

const handleNavigate = (view: string, chatName?: string) => {
  activeView.value = view
  if (view.startsWith('chat-')) {
    activeChatId.value = view
    activeChatName.value = chatName || ''
    localStorage.setItem('active-view', 'chat')
    localStorage.setItem('active-chat-id', view)
    localStorage.setItem('active-chat-name', chatName || '')
  } else if (view === 'chat') {
    activeChatId.value = ''
    activeChatName.value = ''
    localStorage.setItem('active-view', 'chat')
    localStorage.removeItem('active-chat-id')
    localStorage.removeItem('active-chat-name')
  } else if (view === 'workspace') {
    localStorage.setItem('active-view', 'workspace')
    localStorage.removeItem('active-chat-id')
    localStorage.removeItem('active-chat-name')
  } else if (view === 'task') {
    localStorage.setItem('active-view', 'task')
    localStorage.removeItem('active-chat-id')
    localStorage.removeItem('active-chat-name')
  }
}

// Handle updating chat ID when session is created (pending -> real)
const handleUpdateChatId = (oldId: string, newId: string) => {
  // Update active chat ID if it matches the old pending ID
  if (activeChatId.value === `chat-${oldId}`) {
    activeChatId.value = `chat-${newId}`
    localStorage.setItem('active-chat-id', `chat-${newId}`)
  }
  
  // Update sidebar's navItems with the new session ID
  sidebarRef.value?.updateChatId(oldId, newId)
}
</script>

<template>
  <div class="flex h-screen" style="background-color: var(--semantic-content-bg);">
    <Sidebar 
      ref="sidebarRef"
      @navigate="handleNavigate"
      :collapsed="sidebarCollapsed"
      :width="sidebarWidth"
      @toggle-collapse="toggleSidebar"
      @resize="handleSidebarResize"
    />
    <main class="flex-1 flex flex-col overflow-hidden">
      <ChatView
        v-if="activeChatId.startsWith('chat-')"
        :key="activeChatId"
        :chat-id="activeChatId"
        :chat-name="activeChatName"
        @update-chat-id="handleUpdateChatId"
      />
      <Chats v-else-if="activeView === 'chat'" />
      <TaskDetail
        v-else-if="activeView === 'task' && workspacesStore.activeTask && workspacesStore.activeWorkspaceItem"
        :task="workspacesStore.activeTask"
        :project-name="workspacesStore.activeWorkspaceItem.name"
      />
      <div v-else-if="activeView === 'workspace'" class="flex-1 flex flex-col items-center justify-center p-8">
        <!-- Workspace Item Selected -->
        <div
          v-if="activeWorkspaceItem"
          class="w-full max-w-2xl p-8 rounded-xl text-center"
          style="background: linear-gradient(135deg, var(--semantic-card-bg), var(--semantic-sidebar-bg)); border: 1px solid var(--color-border);"
        >
          <div
            class="w-16 h-16 rounded-2xl mx-auto mb-6 flex items-center justify-center text-3xl"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));"
          >
            {{ activeWorkspaceItem.icon }}
          </div>
          <h2
            class="text-2xl font-bold mb-2"
            style="color: var(--semantic-text);"
          >{{ activeWorkspaceItem.name }}</h2>
          <p
            class="text-sm mb-4"
            style="color: var(--semantic-text-muted);"
          >
            {{ workspacesStore.activeWorkspace?.name }}
          </p>
          <div
            v-if="activeWorkspaceItem.path"
            class="inline-flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-text-muted);"
          >
            <span>{{ activeWorkspaceItem.path }}</span>
          </div>
        </div>

        <!-- No Workspace Item Selected - Show Workspace List -->
        <div v-else class="text-center">
          <div
            class="w-20 h-20 rounded-2xl mx-auto mb-6 flex items-center justify-center text-4xl"
            style="background: linear-gradient(135deg, var(--color-yellow), var(--color-orange));"
          >
            📂
          </div>
          <h2
            class="text-2xl font-bold mb-2"
            style="color: var(--semantic-text);"
          >Workspaces</h2>
          <p style="color: var(--semantic-text-muted);">
            Select a project from the sidebar to get started
          </p>

          <!-- Workspace Summary -->
          <div class="mt-8 grid grid-cols-3 gap-4 max-w-md">
            <div
              v-for="workspace in workspacesStore.workspaces"
              :key="workspace.id"
              class="p-4 rounded-lg text-center"
              style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
            >
              <div class="text-2xl mb-2">{{ workspace.icon }}</div>
              <div
                class="text-sm font-medium truncate"
                style="color: var(--semantic-text);"
              >{{ workspace.name }}</div>
              <div
                class="text-xs mt-1"
                style="color: var(--semantic-text-dim);"
              >{{ workspace.items.length }} projects</div>
            </div>
          </div>
        </div>
      </div>
    </main>
    <FolderExplorer v-if="workspacesStore.activeWorkspaceItem" />
  </div>
</template>

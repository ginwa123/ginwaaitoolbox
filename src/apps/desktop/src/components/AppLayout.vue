<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './Sidebar.vue'
import FolderExplorer from './FolderExplorer.vue'
import ChatView from './ChatView.vue'
import Chats from './Chats.vue'
import SettingsView from './SettingsView.vue'
import { useWorkspacesStore } from '../stores/workspaces'

const router = useRouter()
const route = useRoute()
const workspacesStore = useWorkspacesStore()

// Ref to Sidebar component
const sidebarRef = ref<InstanceType<typeof Sidebar> | null>(null)

// Sidebar state
const sidebarCollapsed = ref(false)
const sidebarWidth = ref(288)
const minSidebarWidth = 72
const maxSidebarWidth = 480

// Settings overlay state
const showSettings = ref(false)

onMounted(() => {
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

  const savedTaskId = localStorage.getItem('active-task-id')
  if (savedTaskId && route.query.view === 'task') {
    workspacesStore.setActiveTask(savedTaskId)
  }

  workspacesStore.initializeFromSystemFolder()
})

const toggleSidebar = () => {
  if (sidebarCollapsed.value) {
    sidebarCollapsed.value = false
  } else {
    sidebarCollapsed.value = true
  }
  localStorage.setItem('sidebar-collapsed', String(sidebarCollapsed.value))
}

const handleSidebarResize = (newWidth: number) => {
  sidebarWidth.value = Math.max(minSidebarWidth, Math.min(maxSidebarWidth, newWidth))
  localStorage.setItem('sidebar-width', String(sidebarWidth.value))
}

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)

// Chat state
const activeChatId = ref('')
const activeChatName = ref('')

onMounted(() => {
  const savedChatId = localStorage.getItem('active-chat-id')
  const savedChatName = localStorage.getItem('active-chat-name')
  if (savedChatId) activeChatId.value = savedChatId
  if (savedChatName) activeChatName.value = savedChatName
})

const handleUpdateChatId = (oldId: string, newId: string) => {
  if (activeChatId.value === `chat-${oldId}`) {
    activeChatId.value = `chat-${newId}`
    localStorage.setItem('active-chat-id', `chat-${newId}`)
  }
  sidebarRef.value?.updateChatId(oldId, newId)
}

const handleNavigate = (view: string, chatName?: string, taskId?: string) => {
  if (view.startsWith('chat-')) {
    activeChatId.value = view
    activeChatName.value = chatName || ''
    localStorage.setItem('active-chat-id', view)
    localStorage.setItem('active-chat-name', chatName || '')
    router.replace({ path: '/app', query: { view: 'chat' } })
  } else if (view === 'chat') {
    activeChatId.value = ''
    activeChatName.value = ''
    localStorage.removeItem('active-chat-id')
    localStorage.removeItem('active-chat-name')
    router.replace({ path: '/app', query: { view: 'chat' } })
  } else if (view === 'workspace') {
    activeChatId.value = ''
    localStorage.removeItem('active-chat-id')
    localStorage.removeItem('active-chat-name')
    router.replace({ path: '/app', query: { view: 'workspace' } })
  } else if (view === 'task') {
    localStorage.setItem('active-task-id', taskId || '')
    router.replace({ path: '/app', query: { view: 'task' } })
  } else if (view === 'settings') {
    showSettings.value = true
  }
}

const closeSettings = () => {
  showSettings.value = false
}

const currentView = computed(() => {
  return route.query.view as string || 'chat'
})

const activeTask = computed(() => workspacesStore.activeTask)
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
      <!-- Task view takes priority -->
      <ChatView
        v-if="currentView === 'task' && activeTask"
        :key="'task-' + activeTask.id"
        :chat-id="activeTask.id"
        :chat-name="activeTask.name"
        :type="'task'"
        :cwd="activeWorkspaceItem?.path || ''"
        :task-id="activeTask.id"
        :task-name="activeTask.name"
        :project-name="activeWorkspaceItem?.name || ''"
      />
      <ChatView
        v-else-if="activeChatId.startsWith('chat-')"
        :key="activeChatId"
        :chat-id="activeChatId"
        :chat-name="activeChatName"
        @update-chat-id="handleUpdateChatId"
      />
      <Chats v-else-if="currentView === 'chat'" />
      <div v-else-if="currentView === 'workspace'" class="flex-1 flex flex-col items-center justify-center p-8">
        <div
          v-if="activeWorkspaceItem"
          class="w-full max-w-2xl p-8 rounded-xl text-center"
          style="background: linear-gradient(135deg, var(--semantic-card-bg), var(--semantic-sidebar-bg)); border: 1px solid var(--color-border);"
        >
          <div
            class="w-16 h-16 rounded-2xl mx-auto mb-6 flex items-center justify-center text-3xl"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));"
          >
            {{ activeWorkspaceItem.item_type === 'folder' ? '📁' : '📄' }}
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
    <FolderExplorer v-if="activeWorkspaceItem" />

    <!-- Settings Overlay -->
    <SettingsView v-if="showSettings" @close="closeSettings" />
  </div>
</template>
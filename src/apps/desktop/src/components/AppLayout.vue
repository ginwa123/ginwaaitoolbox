<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './Sidebar.vue'
import FolderExplorer from './FolderExplorer.vue'
import ChatView from './ChatView.vue'
import Chats from './Chats.vue'
import SettingsView from './SettingsView.vue'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'

const router = useRouter()
const route = useRoute()
const navigationStore = useNavigationStore()
const workspacesStore = useWorkspacesStore()

// Ref to Sidebar component
const sidebarRef = ref<InstanceType<typeof Sidebar> | null>(null)

// Settings overlay state (now driven by route)

onMounted(() => {
  // Restore from URL params first (for browser history/shareable links)
  const urlSessionId = route.query.session as string
  const urlTaskId = route.query.task as string
  const urlView = route.query.view as string

  if (urlSessionId && urlView === 'chat') {
    navigationStore.setActiveChat(urlSessionId, navigationStore.activeChatName)
  } else if (urlTaskId && urlView === 'task') {
    workspacesStore.setActiveTask(urlTaskId)
  } else {
    // Fallback to store's initFromUrl
    navigationStore.initFromUrl(urlSessionId || undefined, urlTaskId || undefined, urlView)
  }

  workspacesStore.initializeFromSystemFolder()
})

const toggleSidebar = () => {
  navigationStore.toggleSidebar()
}

const handleSidebarResize = (newWidth: number) => {
  navigationStore.setSidebarWidth(newWidth)
}

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)

// Computed refs from store
const activeChatId = computed(() => navigationStore.activeChatId)
const activeChatName = computed(() => navigationStore.activeChatName)
const sidebarCollapsed = computed(() => navigationStore.sidebarCollapsed)
const sidebarWidth = computed(() => navigationStore.sidebarWidth)

const handleUpdateChatId = (oldId: string, newId: string) => {
  if (activeChatId.value === `chat-${oldId}`) {
    navigationStore.setActiveChat(newId)
  }
  sidebarRef.value?.updateChatId(oldId, newId)
}

const handleNavigate = (view: string, chatName?: string, taskId?: string) => {
  if (view.startsWith('chat-')) {
    const chatSessionId = view.replace(/^chat-/, '')
    navigationStore.setActiveChat(chatSessionId, chatName)
    router.replace({ path: '/app', query: { view: 'chat', session: chatSessionId } })
  } else if (view === 'chat') {
    navigationStore.clearActiveChat()
    router.replace({ path: '/app', query: { view: 'chat' } })
  } else if (view === 'workspace') {
    navigationStore.clearAll()
    router.replace({ path: '/app', query: { view: 'workspace' } })
  } else if (view === 'task') {
    navigationStore.setActiveTask(taskId || null)
    router.replace({ path: '/app', query: { view: 'task', task: taskId } })
  } else if (view === 'settings') {
    router.push({ path: '/app/settings' })
  }
}

const closeSettings = () => {
  router.back()
}

const currentView = computed(() => {
  const path = route.path
  if (path === '/app/settings') return 'settings'
  return route.query.view as string || 'chat'
})

const activeTask = computed(() => workspacesStore.activeTask)

// Watch route query changes to sync with app state
watch(
  () => route.query,
  (query) => {
    const sessionId = query.session as string
    const taskId = query.task as string
    const view = query.view as string

    if (view === 'chat' && sessionId) {
      if (activeChatId.value !== `chat-${sessionId}`) {
        navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
      }
    } else if (view === 'task' && taskId) {
      // Task is handled by workspacesStore.setActiveTask already called in onMounted
    }
  }
)
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
            class="w-16 h-16 rounded-2xl mx-auto mb-6 flex items-center justify-center"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));"
          >
            <svg class="w-8 h-8" fill="none" viewBox="0 0 24 24" stroke="currentColor" style="color: var(--color-bg);">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z" />
            </svg>
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

    <!-- Settings page -->
    <SettingsView v-if="currentView === 'settings'" />
  </div>
</template>
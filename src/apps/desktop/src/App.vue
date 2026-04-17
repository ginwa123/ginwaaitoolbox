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

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)

// Initialize system folder on mount
onMounted(() => {
  workspacesStore.initializeFromSystemFolder()
})

const handleNavigate = (view: string, chatName?: string) => {
  activeView.value = view
  if (view.startsWith('chat-')) {
    activeChatId.value = view
    activeChatName.value = chatName || ''
  } else if (view === 'chat') {
    activeChatId.value = ''
    activeChatName.value = ''
  }
}
</script>

<template>
  <div class="flex h-screen" style="background-color: var(--semantic-content-bg);">
    <Sidebar @navigate="handleNavigate" />
    <main class="flex-1 flex flex-col overflow-hidden">
      <ChatView 
        v-if="activeChatId.startsWith('chat-')" 
        :chat-id="activeChatId" 
        :chat-name="activeChatName" 
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

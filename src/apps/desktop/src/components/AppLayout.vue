<script setup lang="ts">
import { ref, computed, onMounted, watch, nextTick, provide } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './Sidebar.vue'
import RightSidebar from './RightSidebar.vue'
import GitFileViewer from './GitFileViewer.vue'
import SkillDetail from './SkillDetail.vue'
import ChatView from './ChatView.vue'
import Chats from './Chats.vue'
import SettingsView from './SettingsView.vue'
import CodeEditor from './CodeEditor.vue'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import * as api from '../api'
import {
  OPEN_IN_CODE_EDITOR_KEY,
  type OpenInCodeEditorFn,
  type OpenInCodeEditorOptions,
} from '../composables/useCodeEditor'

const router = useRouter()
const route = useRoute()
const navigationStore = useNavigationStore()
const workspacesStore = useWorkspacesStore()
const sidebarStore = useSidebarStore()

// Ref to Sidebar component
const sidebarRef = ref<InstanceType<typeof Sidebar> | null>(null)

// Settings overlay state (now driven by route)

onMounted(() => {
  const urlSessionId = route.query.session as string
  const urlTaskId = route.query.task as string
  const urlView = route.query.view as string

  if (urlSessionId && urlView === 'chat') {
    // Clear any workspace-item active state from a prior session — the URL
    // is the source of truth, and it points to a chat.
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(urlSessionId, navigationStore.activeChatName)
    fetchChatSessionCwd(urlSessionId)
  } else if (urlTaskId && urlView === 'task') {
    workspacesStore.setActiveTask(urlTaskId)
  } else {
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

const handleRightSidebarResize = (newWidth: number) => {
  sidebarStore.setRightSidebarWidth(newWidth)
}

const activeWorkspaceItem = computed(() => workspacesStore.activeWorkspaceItem)

// Computed refs from store
const activeChatId = computed(() => navigationStore.activeChatId)
const activeChatName = computed(() => navigationStore.activeChatName)
const sidebarCollapsed = computed(() => navigationStore.sidebarCollapsed)
const sidebarWidth = computed(() => navigationStore.sidebarWidth)
const rightSidebarWidth = computed(() => sidebarStore.rightSidebarWidth)

const handleUpdateChatId = (oldId: string, newId: string) => {
  if (activeChatId.value === `chat-${oldId}`) {
    navigationStore.setActiveChat(newId)
  }
  sidebarRef.value?.updateChatId(oldId, newId)
}

const handleNavigate = (view: string, chatName?: string, taskId?: string) => {
  if (view.startsWith('chat-')) {
    const chatSessionId = view.replace(/^chat-/, '')
    // Clear any workspace-item active state — navigating to a chat wins.
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(chatSessionId, chatName)
    // Fetch cwd for folder explorer and git
    fetchChatSessionCwd(chatSessionId)
    router.replace({ path: '/app', query: { view: 'chat', session: chatSessionId } })
  } else if (view === 'chat') {
    // Clear any workspace-item active state — the URL is asserting
    // "no chat selected, no workspace item selected".
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.clearActiveChat()
    chatSessionCwd.value = ''
    router.replace({ path: '/app', query: { view: 'chat' } })
  } else if (view === 'workspace') {
    navigationStore.clearAll()
    chatSessionCwd.value = ''
    router.replace({ path: '/app', query: { view: 'workspace' } })
  } else if (view === 'task') {
    navigationStore.setActiveTask(taskId || null)
    chatSessionCwd.value = ''
    router.replace({ path: '/app', query: { view: 'task', task: taskId } })
  } else if (view === 'settings') {
    router.push({ path: '/app/settings' })
  }
}

const closeSettings = () => {
  router.back()
}

const handleRightSidebarFileClick = (file: api.GitFileChange, staged: boolean) => {
  console.log('[handleRightSidebarFileClick] file:', file.path, 'staged:', staged)
  // Clear other overlays to prevent priority conflicts
  skillViewerSkill.value = null
  codeEditorFile.value = null
  codeEditorContent.value = ''
  codeEditorError.value = null

  // Store file info first (synchronously)
  gitViewerFile.value = file
  gitViewerStaged.value = staged
  console.log(
    '[handleRightSidebarFileClick] gitViewerFile.value after set:',
    gitViewerFile.value?.path,
  )

  // Encode the file path for URL (base64 to handle special chars)
  const encodedPath = btoa(file.path)
  router.replace({
    path: '/app',
    query: {
      view: 'gitfile',
      file: encodedPath,
      staged: staged ? '1' : '0',
      cwd: rightSidebarCwd.value,
    },
  })
}

const closeGitViewer = () => {
  gitViewerFile.value = null
  gitViewerStaged.value = false
  // Navigate back to previous view based on state
  if (activeTask.value) {
    router.replace({ path: '/app', query: { view: 'task', task: activeTask.value.id } })
  } else if (activeChatId.value.startsWith('chat-')) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
  } else {
    router.replace({ path: '/app', query: { view: 'chat' } })
  }
}

// Skill viewer state
const skillViewerSkill = ref<api.Skill | null>(null)

const handleRightSidebarSkillClick = (skill: api.Skill) => {
  console.log('[handleRightSidebarSkillClick] skill:', skill.name)
  // Clear other overlays to prevent priority conflicts
  gitViewerFile.value = null
  gitViewerStaged.value = false
  skillViewerSkill.value = skill
  console.log(
    '[handleRightSidebarSkillClick] skillViewerSkill.value after set:',
    skillViewerSkill.value?.name,
  )

  console.log('[handleRightSidebarSkillClick] current route:', route.fullPath)
  console.log('[handleRightSidebarSkillClick] activeChatId:', activeChatId.value)
  console.log('[handleRightSidebarSkillClick] activeTask:', activeTask.value)

  // Navigate to skill view
  router.replace({
    path: '/app',
    query: {
      view: 'skill',
      skill: skill.name,
    },
  })

  // Check state after route change
  setTimeout(() => {
    console.log(
      '[handleRightSidebarSkillClick] AFTER route change - skillViewerSkill:',
      skillViewerSkill.value?.name,
    )
    console.log('[handleRightSidebarSkillClick] AFTER route change - route:', route.fullPath)
    console.log(
      '[handleRightSidebarSkillClick] AFTER route change - currentView:',
      currentView.value,
    )
  }, 100)
}

const closeSkillViewer = () => {
  skillViewerSkill.value = null
  // Navigate back to previous view based on state
  if (activeTask.value) {
    router.replace({ path: '/app', query: { view: 'task', task: activeTask.value.id } })
  } else if (activeChatId.value.startsWith('chat-')) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
  } else {
    router.replace({ path: '/app', query: { view: 'chat' } })
  }
}

// Code editor state
const codeEditorFile = ref<api.FolderEntry | null>(null)
const codeEditorContent = ref<string>('')
const codeEditorLoading = ref(false)
const codeEditorError = ref<string | null>(null)

const openInCodeEditor: OpenInCodeEditorFn = async (opts: OpenInCodeEditorOptions) => {
  console.log('[openInCodeEditor] filePath:', opts.filePath, 'cwd:', opts.cwd)
  if (!opts.cwd) return

  // Build a FolderEntry-shaped object from the lightweight options
  const file: api.FolderEntry = {
    path: opts.filePath,
    name: opts.fileName || opts.filePath.split('/').pop() || opts.filePath,
    is_directory: false,
    is_symlink: false,
  }

  // Clear other overlays to prevent priority conflicts
  gitViewerFile.value = null
  gitViewerStaged.value = false
  skillViewerSkill.value = null

  codeEditorFile.value = file
  codeEditorLoading.value = true
  codeEditorError.value = null
  codeEditorContent.value = ''

  try {
    const response = await api.readFileContent(opts.cwd, file.path)
    codeEditorContent.value = response.content
    console.log(
      '[openInCodeEditor] codeEditorFile.value after set:',
      codeEditorFile.value?.path,
    )
    // Navigate to code-editor view
    // Encode the file path for URL (base64 to handle special chars)
    const encodedPath = btoa(file.path)
    router.replace({
      path: '/app',
      query: {
        view: 'code-editor',
        file: encodedPath,
        cwd: opts.cwd,
      },
    })
  } catch (err) {
    console.error('Failed to read file:', err)
    codeEditorError.value = 'Failed to read file'
    codeEditorContent.value = ''
  } finally {
    codeEditorLoading.value = false
  }
}

const handleCodeEditorFileClick = (file: api.FolderEntry) => {
  if (!rightSidebarCwd.value) return
  return openInCodeEditor({
    filePath: file.path,
    fileName: file.name,
    cwd: rightSidebarCwd.value,
  })
}

// Expose openInCodeEditor to all descendants (tool output components) via inject
provide<OpenInCodeEditorFn>(OPEN_IN_CODE_EDITOR_KEY, openInCodeEditor)

const closeCodeEditor = () => {
  codeEditorFile.value = null
  codeEditorContent.value = ''
  codeEditorError.value = null
  // Navigate back to previous view
  if (activeTask.value) {
    router.replace({ path: '/app', query: { view: 'task', task: activeTask.value.id } })
  } else if (activeChatId.value.startsWith('chat-')) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    router.replace({ path: '/app', query: { view: 'chat', session: sessionId } })
  } else {
    router.replace({ path: '/app', query: { view: 'chat' } })
  }
}

const loadCodeEditorContent = async () => {
  if (!codeEditorFile.value || !rightSidebarCwd.value) return

  codeEditorLoading.value = true
  codeEditorError.value = null

  try {
    const response = await api.readFileContent(rightSidebarCwd.value, codeEditorFile.value.path)
    codeEditorContent.value = response.content
  } catch (err) {
    console.error('Failed to read file:', err)
    codeEditorError.value = 'Failed to read file'
    codeEditorContent.value = ''
  } finally {
    codeEditorLoading.value = false
  }
}

const handleCodeEditorSave = async (content: string) => {
  if (!rightSidebarCwd.value || !codeEditorFile.value) return

  try {
    await api.writeFileContent(rightSidebarCwd.value, codeEditorFile.value.path, content)
    codeEditorContent.value = content
    console.log('File saved successfully')
  } catch (err) {
    console.error('Failed to save file:', err)
    codeEditorError.value = 'Failed to save file'
  }
}

const handleSubmitReview = async (message: string) => {
  console.log('[AppLayout] Code review submitted:', message)
  // Navigate to chat view with the review message
  if (activeChatId.value.startsWith('chat-')) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    // Send the review message to the active chat session
    try {
      await api.sendChatMessage(sessionId, message, rightSidebarCwd.value)
      console.log('[AppLayout] Review message sent successfully')
    } catch (err) {
      console.error('[AppLayout] Failed to send review message:', err)
    }
  }
  // Close the git viewer after submitting
  closeGitViewer()
}

// Git file viewer state
const gitViewerFile = ref<api.GitFileChange | null>(null)
const gitViewerStaged = ref(false)

// Chat session cwd for folder explorer and git (fetched from API)
const chatSessionCwd = ref<string>('')

const fetchChatSessionCwd = async (sessionId: string) => {
  chatSessionCwd.value = ''
  try {
    const session = await api.getSession(sessionId)
    if (session && session.cwd) {
      chatSessionCwd.value = session.cwd
      return
    }

    // Fallback: get cwd from session messages
    const historyData = await api.getChatHistory(sessionId, 1)
    if (historyData.cwd) {
      chatSessionCwd.value = historyData.cwd
    }
  } catch (err) {
    console.error('Failed to fetch chat session cwd:', err)
  }
}

const currentView = computed(() => {
  const path = route.path
  if (path === '/app/settings') return 'settings'
  // gitfile view - check only the ref (set synchronously before navigation)
  if (gitViewerFile.value) {
    console.log('[currentView] returning gitfile, gitViewerFile:', gitViewerFile.value.path)
    return 'gitfile'
  }
  // skill view - check only the ref
  if (skillViewerSkill.value) {
    console.log('[currentView] returning skill, skillViewerSkill:', skillViewerSkill.value.name)
    return 'skill'
  }
  console.log('[currentView] skillViewerSkill is null, checking route')
  // code-editor view - check only the ref
  if (codeEditorFile.value) return 'code-editor'

  const view = (route.query.view as string) || 'chat'
  console.log('[currentView] returning route view:', view)
  return view
})

const activeTask = computed(() => workspacesStore.activeTask)

// Right sidebar cwd - show when chat is open OR task is active
const rightSidebarCwd = computed(() => {
  if (activeTask.value && activeWorkspaceItem.value?.path) {
    return activeWorkspaceItem.value.path
  }
  if (navigationStore.activeChatId && navigationStore.activeChatId.startsWith('chat-')) {
    return chatSessionCwd.value || activeWorkspaceItem.value?.path || ''
  }
  return ''
})

// Watch route query changes to sync with app state
watch(
  () => route.query,
  async (query) => {
    const sessionId = query.session as string
    const taskId = query.task as string
    const view = query.view as string

    if (view === 'gitfile') {
      // Restore git file viewer state from URL
      const filePath = query.file as string
      const staged = query.staged === '1'
      const cwd = query.cwd as string

      if (filePath) {
        // Decode the file path
        try {
          const decodedPath = atob(filePath)
          gitViewerFile.value = {
            path: decodedPath,
            index_status: staged ? 'M' : ' ',
            worktree_status: staged ? ' ' : 'M',
          }
          gitViewerStaged.value = staged
        } catch {
          // Fallback if decoding fails
          gitViewerFile.value = {
            path: filePath,
            index_status: staged ? 'M' : ' ',
            worktree_status: staged ? ' ' : 'M',
          }
          gitViewerStaged.value = staged
        }
      }
    } else if (view === 'skill') {
      // Restore skill viewer state from URL
      const skillName = query.skill as string
      if (skillName) {
        skillViewerSkill.value = {
          name: skillName,
          description: '',
        }
      }
    } else if (view === 'code-editor') {
      // Restore code editor state from URL
      const filePath = query.file as string
      const cwd = query.cwd as string

      if (filePath) {
        // Decode the file path
        try {
          const decodedPath = atob(filePath)
          codeEditorFile.value = {
            path: decodedPath,
            name: decodedPath.split('/').pop() || decodedPath,
            is_directory: false,
            is_symlink: false,
          }
          codeEditorContent.value = ''
          codeEditorError.value = null
          // Fetch file content
          loadCodeEditorContent()
        } catch {
          codeEditorFile.value = null
        }
      }
    } else {
      // Clear git viewer when not in gitfile view
      gitViewerFile.value = null
      gitViewerStaged.value = false
      // Clear skill viewer when not in skill view
      skillViewerSkill.value = null
      // Clear code editor when not in code-editor view
      codeEditorFile.value = null
      codeEditorContent.value = ''
      codeEditorError.value = null

      if (view === 'chat' && sessionId) {
        if (activeChatId.value !== `chat-${sessionId}`) {
          // URL changed to a different chat — clear any leftover workspace
          // item active state from a previous view.
          workspacesStore.setActiveWorkspaceItem(null)
          navigationStore.setActiveChat(sessionId, navigationStore.activeChatName)
        }
        // Fetch cwd for folder explorer and git
        // Use localStorage cached value if available for immediate use
        const cachedCwd = localStorage.getItem(`session_cwd_${sessionId}`)
        if (cachedCwd) {
          chatSessionCwd.value = cachedCwd
        }
        await fetchChatSessionCwd(sessionId)
        // Cache the cwd for future use
        if (chatSessionCwd.value) {
          localStorage.setItem(`session_cwd_${sessionId}`, chatSessionCwd.value)
        }
      } else if (view === 'task' && taskId) {
        // Task is handled by workspacesStore.setActiveTask already called in onMounted
      } else if (!view || view === 'workspace') {
        // Clear chat session cwd when not in chat view
        chatSessionCwd.value = ''
        // Clear any workspace-item active state — "no view" or "workspace"
        // means "no chat selected".
        workspacesStore.setActiveWorkspaceItem(null)
      }
    }
  },
)

// Watch chatSessionCwd changes and sync to GitFileViewer if needed
watch(chatSessionCwd, (newCwd) => {
  // Update localStorage cache when cwd becomes available
  if (newCwd && activeChatId.value) {
    const sessionId = activeChatId.value.replace(/^chat-/, '')
    localStorage.setItem(`session_cwd_${sessionId}`, newCwd)
  }
})
</script>

<template>
  <div class="flex h-screen" style="background-color: var(--semantic-content-bg)">
    <Sidebar
      ref="sidebarRef"
      @navigate="handleNavigate"
      :collapsed="sidebarCollapsed"
      :width="sidebarWidth"
      @toggle-collapse="toggleSidebar"
      @resize="handleSidebarResize"
    />
    <main class="flex-1 flex flex-col overflow-hidden relative">
      <!-- Git File Viewer (shown when view is gitfile) -->
      <GitFileViewer
        v-if="currentView === 'gitfile' && gitViewerFile && rightSidebarCwd"
        class="absolute inset-0"
        style="z-index: 10;"
        :cwd="rightSidebarCwd"
        :file-path="gitViewerFile.path"
        :file-name="gitViewerFile.path.split('/').pop() || gitViewerFile.path"
        :staged="gitViewerStaged"
        @close="closeGitViewer"
        @submit-review="handleSubmitReview"
      />

      <!-- Skill Detail Viewer (shown when view is skill) -->
      <div
        v-if="currentView === 'skill' && skillViewerSkill"
        class="flex-1 flex flex-col overflow-hidden absolute inset-0"
        style="background-color: var(--semantic-content-bg); z-index: 10;"
      >
        <!-- Header -->
        <div
          class="h-14 flex items-center justify-between px-4 shrink-0"
          style="border-bottom: 1px solid var(--color-border)"
        >
          <div class="flex items-center gap-3">
            <button
              @click="closeSkillViewer"
              class="p-2 rounded-lg hover:opacity-70 transition-opacity"
              title="Back"
            >
              <svg
                class="w-5 h-5"
                style="color: var(--semantic-text)"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 19l-7-7 7-7"
                />
              </svg>
            </button>
            <h2 class="text-base font-semibold" style="color: var(--semantic-text)">
              🧠 {{ skillViewerSkill?.name }}
            </h2>
          </div>
        </div>
        <!-- Skill Detail Content -->
        <div class="flex-1 overflow-hidden">
          <SkillDetail
            :skill-name="skillViewerSkill?.name"
            :cwd="rightSidebarCwd"
            @skill-deleted="closeSkillViewer"
            @error="(msg) => console.error('Skill error:', msg)"
          />
        </div>
      </div>

      <!-- Code Editor (shown when view is code-editor) -->
      <div
        v-if="currentView === 'code-editor' && codeEditorFile"
        class="flex-1 flex flex-col overflow-hidden absolute inset-0"
        style="background-color: var(--semantic-content-bg); z-index: 10;"
      >
        <!-- Loading state -->
        <div v-if="codeEditorLoading" class="flex-1 flex items-center justify-center">
          <svg
            class="animate-spin w-8 h-8"
            style="color: var(--color-aqua)"
            viewBox="0 0 24 24"
            fill="none"
          >
            <circle
              class="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              stroke-width="4"
            />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            />
          </svg>
        </div>

        <!-- Error state -->
        <div v-else-if="codeEditorError" class="flex-1 flex flex-col items-center justify-center">
          <span class="text-2xl mb-2">⚠️</span>
          <p class="text-sm" style="color: var(--semantic-text-dim)">{{ codeEditorError }}</p>
          <button
            @click="closeCodeEditor"
            class="mt-4 px-4 py-2 rounded-lg text-sm"
            style="background-color: var(--color-border); color: var(--semantic-text)"
          >
            Close
          </button>
        </div>

        <!-- Code Editor -->
        <CodeEditor
          v-else
          :file-path="codeEditorFile.path"
          :file-name="codeEditorFile.name"
          :content="codeEditorContent"
          :cwd="rightSidebarCwd"
          @close="closeCodeEditor"
          @save="handleCodeEditorSave"
        />
      </div>

      <!-- Task view takes priority -->
      <ChatView
        v-else-if="currentView === 'task' && activeTask"
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
      <div
        v-else-if="currentView === 'workspace'"
        class="flex-1 flex flex-col items-center justify-center p-8"
      >
        <div
          v-if="activeWorkspaceItem"
          class="w-full max-w-2xl p-8 rounded-xl text-center"
          style="
            background: linear-gradient(
              135deg,
              var(--semantic-card-bg),
              var(--semantic-sidebar-bg)
            );
            border: 1px solid var(--color-border);
          "
        >
          <div
            class="w-16 h-16 rounded-2xl mx-auto mb-6 flex items-center justify-center"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue))"
          >
            <svg
              class="w-8 h-8"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              style="color: var(--color-bg)"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              />
            </svg>
          </div>
          <h2 class="text-2xl font-bold mb-2" style="color: var(--semantic-text)">
            {{ activeWorkspaceItem.name }}
          </h2>
          <p class="text-sm mb-4" style="color: var(--semantic-text-muted)">
            {{ workspacesStore.activeWorkspace?.name }}
          </p>
          <div
            v-if="activeWorkspaceItem.path"
            class="inline-flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-text-muted)"
          >
            <span>{{ activeWorkspaceItem.path }}</span>
          </div>
        </div>

        <div v-else class="text-center">
          <div
            class="w-20 h-20 rounded-2xl mx-auto mb-6 flex items-center justify-center text-4xl"
            style="background: linear-gradient(135deg, var(--color-yellow), var(--color-orange))"
          >
            📂
          </div>
          <h2 class="text-2xl font-bold mb-2" style="color: var(--semantic-text)">Workspaces</h2>
          <p style="color: var(--semantic-text-muted)">
            Select a project from the sidebar to get started
          </p>

          <div class="mt-8 grid grid-cols-3 gap-4 max-w-md">
            <div
              v-for="workspace in workspacesStore.workspaces"
              :key="workspace.id"
              class="p-4 rounded-lg text-center"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
            >
              <div class="text-2xl mb-2">{{ workspace.icon }}</div>
              <div class="text-sm font-medium truncate" style="color: var(--semantic-text)">
                {{ workspace.name }}
              </div>
              <div class="text-xs mt-1" style="color: var(--semantic-text-dim)">
                {{ workspace.items.length }} projects
              </div>
            </div>
          </div>
        </div>
      </div>
    </main>

    <!-- Settings page -->
    <SettingsView v-if="currentView === 'settings'" />

    <!-- Right Sidebar (Explorer + Git tabs) -->
    <RightSidebar
      v-if="rightSidebarCwd"
      :cwd="rightSidebarCwd"
      :width="rightSidebarWidth"
      @file-click="handleRightSidebarFileClick"
      @skill-click="handleRightSidebarSkillClick"
      @code-editor-file-click="handleCodeEditorFileClick"
      @resize="handleRightSidebarResize"
    />
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch, nextTick, provide } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './Sidebar.vue'
import RightSidebar from './RightSidebar.vue'
import GitFileViewer from './GitFileViewer.vue'
import SkillDetail from './SkillDetail.vue'
import ChatView from './ChatView.vue'
import Chats from './Chats.vue'
import SettingsView from './SettingsView.vue'
import CodeEditor from './CodeEditor.vue'
import NotificationContainer from './NotificationContainer.vue'
import KanbanView from './KanbanView.vue'
import KanbanColumnEditor from './KanbanColumnEditor.vue'
import KanbanSettingsDialog from './KanbanSettingsDialog.vue'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import { useKanbanSseStore } from '../stores/kanbanSse'
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
  // Subscribe to /api/sessions/stream so renames from the backend
  // (e.g. the cascade triggered by renameTask) propagate to the
  // workspace-item task list in real time. Without this, the
  // sidebar's task row stays at the old name until manual reload —
  // the ChatsList (top of sidebar) updates because it has its own
  // subscription, but the workspace tree in this store did not.
  // The subscription is idempotent; calling it more than once is
  // a no-op.
  workspacesStore.subscribeToSessionEvents()
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
const activeWorkspace = computed(() => workspacesStore.activeWorkspace)

// Subscribe to /api/kanban/events so live kanban mutations (column
// create / update / delete / reorder, task move / assign / unassign)
// refresh the visible board in real time without a manual reload.
// The store owns ONE global SSE connection for the app's lifetime
// (mirrors the workersSse pattern in App.vue) — workspace switches
// just update the client-side filter, no connection churn.
// Empty string when no workspace is active (the store treats "" as
// a valid workspaceId, but the activeWorkspace.value?.id falls
// through to "" so no kanban event is ever dispatched to a
// non-existent workspace — the workspacesStore.fetchKanbanColumns
// helper no-ops if the (workspaceId, itemId) pair doesn't resolve to
// a local item).
const kanbanSseStore = useKanbanSseStore()
const activeWorkspaceId = computed(() => activeWorkspace.value?.id ?? '')

// Subscribe to /api/kanban/events on the FIRST truthy activeWorkspaceId
// and update the client-side filter on every subsequent change.
// `watch + { immediate: true }` replaces the previous `onMounted + watch`
// pair — the onMounted fired while `workspaces.value` was still empty
// (initializeFromSystemFolder is async and not awaited), so the if-guard
// was always skipped and initKanbanSse never ran. This watcher covers
// all three startup shapes:
//   - URL has ?task=...  → setActiveTask ran before mount; immediate=true
//     opens the SSE on the first tick with the already-truthy id.
//   - URL has ?session=... (chat) or no URL params → activeWorkspaceId
//     is '' at mount; the watch sits idle until
//     initializeFromSystemFolder's post-init restoration
//     (workspaces.ts:1559-1577) sets activeWorkspaceItemId, then fires
//     with the now-truthy id and opens the SSE.
//   - User clicks a sidebar item mid-session → fires with the new id.
// `didInitSse` preserves the store's design: ONE connection for the
// app's lifetime, only filter updates on workspace switches (the
// backend's kanban routing keys are global, so we don't reopen).
//
// The watch callback is async so we can `await` `initKanbanSse`. The
// underlying `createSseClient` defers its initial `start()` to the
// next macrotask — awaiting the Promise here makes the SSE setup
// cooperative with other same-tick fetch API calls (workspace data,
// chat history) and prevents the EventSource HTTP request from
// saturating the browser's per-origin 6-connection pool.
let didInitSse = false
watch(activeWorkspaceId, async (newId) => {
  if (!newId) return
  if (!didInitSse) {
    didInitSse = true
    await kanbanSseStore.initKanbanSse(newId)
  } else {
    kanbanSseStore.setActiveWorkspaceId(newId)
  }
}, { immediate: true })

onUnmounted(() => {
  kanbanSseStore.closeKanbanSse()
})

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
    console.log('[openInCodeEditor] codeEditorFile.value after set:', codeEditorFile.value?.path)
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

// Workspace-item id of the currently-active task. Used by the
// 3-column kanban|chatview template branch to make sure the
// chatview and the kanban belong to the same parent — otherwise
// we'd render a chatview of a non-kanban task alongside an
// unrelated kanban (visual mess). The lookup walks every
// workspace's tasks looking for `activeTaskId`; returns the
// containing item's id or null. Cheap O(W) where W = number of
// tasks across all workspaces.
const activeTaskWorkspaceItemId = computed(() => {
  const taskId = workspacesStore.activeTaskId
  if (!taskId) return null
  for (const ws of workspacesStore.workspaces) {
    for (const item of ws.items) {
      if (item.tasks?.some((t) => t.id === taskId)) {
        return item.id
      }
    }
  }
  return null
})

// Close the chatview column (the 3-column layout's right pane).
// Triggered by the ChatView's ✕ header button. Clears the active
// task and navigates to `view=workspace` so the URL remains the
// source of truth — a refresh of `/app?view=workspace` re-renders
// the kanban alone, with no leftover activeTask. Without the
// `router.replace`, the URL would still say `view=task&task=…`
// after the close, which would force a re-mount of the standalone
// task branch and the kanban would vanish.
//
// The chat list (ChatsList) is intentionally NOT touched here:
// closing the kanban task's chatview is independent of the chat
// list's active row (a kanban task has its own session, not a
// chat-row session). Clearing activeTask is sufficient.
const handleCloseTaskView = () => {
  workspacesStore.setActiveTask(null)
  router.replace({ path: '/app', query: { view: 'workspace' } })
}

// ─── Kanban column resize (3-column layout: sidebar | kanban | chatview) ──
//
// The 3-column layout's kanban column is drag-resizable. The user grabs
// the 1px handle between the kanban and the chatview, drags left/right,
// and the kanban grows/shrinks within a clamped range. The chatview
// column absorbs the leftover space (it has `flex: 1 1 0`). The width
// persists to localStorage so a refresh keeps the user's preferred
// layout.
//
// Pattern mirrors Sidebar.vue's resize handling
// (lines 162-194: startResize / handleResize / stopResize), which
// uses raw `mousemove` listeners on `document` (not on the handle
// itself — the cursor can outrun the handle during a fast drag,
// and listening on `document` is the only way to catch every move).
//
// Bounds rationale:
//   - MIN 280px: kanban columns become unreadable below this (the
//     column card itself is ~240px wide plus padding, and the
//     "+ Add" footer needs another ~40px).
//   - MAX 720px: beyond this the chatview shrinks to <30% of the
//     main area on typical 1080p+ displays, making the chat feel
//     cramped. The chat needs at least 480px to be usable.
const KANBAN_MIN_WIDTH = 280
const KANBAN_MAX_WIDTH = 720
const KANBAN_DEFAULT_WIDTH = 40 // % of main area, used when no localStorage value exists
const KANBAN_WIDTH_STORAGE_KEY = 'kanban-column-width'

// Load the persisted kanban width. Returns a px value (int) or
// null when no value exists. The caller falls back to a percentage
// layout in that case (see kanbanColumnStyle below). We deliberately
// do NOT clamp here — clamping belongs in the resize handler, so
// that an out-of-range value from a future bug doesn't silently
// shrink the kanban on load.
const loadKanbanColumnWidth = (): number | null => {
  if (typeof localStorage === 'undefined') return null
  const saved = localStorage.getItem(KANBAN_WIDTH_STORAGE_KEY)
  if (saved === null) return null
  const parsed = parseInt(saved, 10)
  if (isNaN(parsed) || parsed <= 0) return null
  return parsed
}

const kanbanColumnWidth = ref<number | null>(loadKanbanColumnWidth())
const isKanbanResizing = ref(false)
const kanbanResizeStartX = ref(0)
const kanbanResizeStartWidth = ref(0)

const startKanbanResize = (e: MouseEvent | TouchEvent) => {
  isKanbanResizing.value = true
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  kanbanResizeStartX.value = clientX
  // If the kanban is currently percentage-sized (no persisted
  // width yet), measure the rendered column width as the drag
  // start point. Otherwise use the persisted px value. Without
  // this, dragging from a 40% layout would snap to a 280px start.
  const rendered = kanbanResizeStartWidth.value
  if (rendered <= 0) {
    const el = document.querySelector(
      '[data-kanban-three-column] > :first-child',
    ) as HTMLElement | null
    kanbanResizeStartWidth.value = el?.getBoundingClientRect().width ?? 400
  }
  document.addEventListener('mousemove', handleKanbanResize)
  document.addEventListener('mouseup', stopKanbanResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'col-resize'
  e.preventDefault()
}

const handleKanbanResize = (e: MouseEvent | TouchEvent) => {
  if (!isKanbanResizing.value) return
  const clientX = 'touches' in e && e.touches[0] ? e.touches[0].clientX : (e as MouseEvent).clientX
  const deltaX = clientX - kanbanResizeStartX.value
  const newWidth = Math.max(
    KANBAN_MIN_WIDTH,
    Math.min(KANBAN_MAX_WIDTH, kanbanResizeStartWidth.value + deltaX),
  )
  kanbanColumnWidth.value = newWidth
}

const stopKanbanResize = () => {
  if (!isKanbanResizing.value) return
  isKanbanResizing.value = false
  document.removeEventListener('mousemove', handleKanbanResize)
  document.removeEventListener('mouseup', stopKanbanResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
  // Persist on release (not during drag — dragging fires 60+
  // mousemove events per second, and localStorage.setItem is
  // synchronous + slow enough to noticeably drag the resize
  // interaction). One write per gesture is enough.
  if (kanbanColumnWidth.value !== null) {
    try {
      localStorage.setItem(KANBAN_WIDTH_STORAGE_KEY, String(kanbanColumnWidth.value))
    } catch {
      // localStorage may throw in private-mode or quota-exceeded
      // scenarios; silently ignore so the in-memory drag still
      // works for the current session.
    }
  }
}

// Inline style for the kanban column. When a width is persisted
// (in px), use it directly (the user resized the column). When
// no width is persisted yet, fall back to the default 40% flex
// so first-time users see a balanced layout. Returns a CSSStyleDeclaration-compatible
// object — Vue handles kebab-case keys natively in `:style`.
const kanbanColumnStyle = computed(() => {
  if (kanbanColumnWidth.value !== null) {
    return {
      width: `${kanbanColumnWidth.value}px`,
      'min-width': `${KANBAN_MIN_WIDTH}px`,
      'max-width': `${KANBAN_MAX_WIDTH}px`,
      'flex-shrink': '0',
    }
  }
  return {
    flex: `0 1 ${KANBAN_DEFAULT_WIDTH}%`,
    'min-width': `${KANBAN_MIN_WIDTH}px`,
    'max-width': `${KANBAN_MAX_WIDTH}px`,
  }
})

// ─── Kanban main-content view (was inline in WorkspaceItem.vue;
// now mounted here so the board lives in the main content area, not
// in the sidebar). The KanbanView emits its own CRUD events; we
// forward them to the workspaces store directly. The one event
// that can't be handled by the store alone is `addTask` (it opens
// the AddTaskPickerDialog, which is owned by Sidebar) — that one
// delegates to `sidebarRef.value?.openTaskPicker(...)`. ──────────────

// KanbanColumnEditor modal state. Three modes (add / rename / delete)
// share the same component; we track the mode + the target column
// id + the initial name. Lives at the AppLayout scope so the editor
// is mounted exactly once (any kanban view emits request-rename-
// column / request-delete-column; we point them at this state).
type KanbanEditorMode = 'add' | 'rename' | 'delete'
const showKanbanColumnEditor = ref(false)
const kanbanColumnEditorMode = ref<KanbanEditorMode>('add')
const kanbanColumnEditorTargetId = ref<string | null>(null)
const kanbanColumnEditorInitialName = ref<string>('')
const kanbanColumnEditorInitialDescription = ref<string>('')

// Look up the column by id in the active kanban item. Returns
// undefined if the active item is missing or has no columns — the
// caller treats that as a no-op.
const findKanbanColumn = (columnId: string) => {
  return activeWorkspaceItem.value?.kanban_columns?.find((c) => c.id === columnId)
}

// + Column on the kanban header: open the editor in 'add' mode.
const handleKanbanAddColumn = () => {
  kanbanColumnEditorMode.value = 'add'
  kanbanColumnEditorTargetId.value = null
  kanbanColumnEditorInitialName.value = ''
  showKanbanColumnEditor.value = true
}

// ⋮ menu "Rename" on a column: open the editor in 'rename' mode,
// pre-filled with the column's current name and description.
const handleKanbanRequestRenameColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'rename'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  showKanbanColumnEditor.value = true
}

// ⋮ menu "Delete" on a column: open the editor in 'delete' mode
// (the editor renders the confirmation copy itself).
const handleKanbanRequestDeleteColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'delete'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  showKanbanColumnEditor.value = true
}

const handleKanbanColumnEditorClose = () => {
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorAdd = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name, description)
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorRename = (name: string, description: string) => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
    { name, description },
  )
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorDelete = () => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
  )
  showKanbanColumnEditor.value = false
}

// ─── KanbanSettingsDialog — per-board column management ─────────────────
//
// A single modal that shows the kanban name, an inline "Add Column"
// form, and the list of existing columns with per-row Edit / Delete
// actions. The dialog reuses the KanbanColumnEditor in 'rename' /
// 'delete' modes for per-row edits, so the per-board and per-⋮-menu
// flows share the same UX. The dialog itself stays open across
// add/edit/delete so the user can manage several columns in
// succession without reopening it.
const showKanbanSettingsDialog = ref(false)

const handleOpenKanbanSettings = () => {
  showKanbanSettingsDialog.value = true
}

const handleCloseKanbanSettings = () => {
  showKanbanSettingsDialog.value = false
}

const handleKanbanSettingsAddColumn = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name, description)
  // Dialog stays open so the user can add more columns in succession.
}

const handleKanbanSettingsEditColumn = (payload: {
  columnId: string
  name: string
  description: string
}) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(ws.id, activeWorkspaceItem.value.id, payload.columnId, {
    name: payload.name,
    description: payload.description,
  })
}

const handleKanbanSettingsDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}

// + Add on a column: open the standard chat dialog directly
// (skipping the AddTaskPickerDialog). Kanban cards are always
// standard chats — the column is a workflow stage, not a task-type
// discriminator — so the Routine / Memory options would be noise.
// Calls Sidebar's exposed `openStandardTaskDialog` (the picker →
// standard dialog transition that `handleAddTaskPick('standard')`
// performs internally). The new task is auto-assigned to the
// first kanban column by the backend's tasks_create.zig (the
// `columnId` payload is logged for future routing once the
// create-task API accepts a column param).
const handleKanbanAddTask = (payload: { columnId: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  sidebarRef.value?.openStandardTaskDialog(ws.id, activeWorkspaceItem.value.id)
  // TODO (v2): route payload.columnId through to the create-task
  // API so the task lands in the user's chosen column on creation,
  // not the default first column.
  void payload.columnId
}

// Drag-and-drop task move between columns. Direct store call.
const handleKanbanMoveTask = (payload: { taskId: string; columnId: string; position: number }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.moveTaskToColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    payload.taskId,
    payload.columnId,
    payload.position,
  )
}

// "Rename column" emitted from the inline rename input inside
// <KanbanColumn>. The column lets the user type a new name
// directly (no modal) and emits this on blur / Enter. Direct store
// call.
const handleKanbanRenameColumn = (payload: { columnId: string; name: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(ws.id, activeWorkspaceItem.value.id, payload.columnId, {
    name: payload.name,
  })
}

// "Delete column" emitted from the column's quick-delete path (the
// ⋮ menu's "Delete" goes through the editor flow above, but the
// column may also expose a faster path in a future iteration).
// Direct store call.
const handleKanbanDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}

// Column header drag-and-drop reorder (Trello/Jira UX). Direct store
// call — the store action resolves the target column's current
// position, PATCHes the moved column, and re-fetches the full
// column list (because the backend's PATCH response only includes
// the moved column, but siblings were renumbered too).
const handleKanbanReorderColumn = (payload: { columnId: string; targetColumnId: string }) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.reorderKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    payload.columnId,
    payload.targetColumnId,
  )
}

// Task-level events (select-task, delete-task, rename-task,
// edit-routine, run-routine, pin-task) re-emitted by <KanbanColumn>.
// These all live in Sidebar (because they need access to
// chatsListRef and the modal state for rename / edit-routine), so
// we forward them via the exposed methods. The sidebar ref is
// non-null at runtime (AppLayout always renders a Sidebar); the
// optional-chaining + noop-on-miss is defensive for the
// initial-render / unmount edge case.

// select-task: click a card → open the task's chat view.
const handleKanbanSelectTask = (taskId: string) => {
  sidebarRef.value?.selectTask(taskId)
}

const handleKanbanDeleteTask = (workspaceId: string, itemId: string, taskId: string) => {
  sidebarRef.value?.deleteTask(workspaceId, itemId, taskId)
}

const handleKanbanRenameTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  currentName: string,
) => {
  sidebarRef.value?.renameTask(workspaceId, itemId, taskId, currentName)
}

const handleKanbanEditRoutine = (workspaceId: string, itemId: string, taskId: string) => {
  sidebarRef.value?.editRoutine(workspaceId, itemId, taskId)
}

const handleKanbanRunRoutine = (workspaceId: string, itemId: string, taskId: string) => {
  void sidebarRef.value?.runRoutine(workspaceId, itemId, taskId)
}

const handleKanbanPinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  sidebarRef.value?.pinTask(workspaceId, itemId, taskId, isPinned)
}

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
        // Clear chat session cwd when not in chat view. We
        // intentionally do NOT clear activeWorkspaceItemId here:
        // Sidebar's handleSelectItem navigates to this exact URL
        // after setting the active workspace item (folder or
        // kanban). Clearing it here would clobber the user's
        // selection and force them to click the item again.
        // The empty-state placeholder in the v-else-if chain
        // below renders when activeWorkspaceItem is null, so
        // users still see a "select a project" message when
        // there's no active item — clearing in the watcher is
        // unnecessary.
        chatSessionCwd.value = ''
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
        style="z-index: 10"
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
        style="background-color: var(--semantic-content-bg); z-index: 10"
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
        style="background-color: var(--semantic-content-bg); z-index: 10"
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

      <!-- 3-column kanban layout: sidebar | kanban | chatview.
           Rendered when (a) the active workspace item is a kanban
           AND (b) a task is currently selected under that kanban.
           Both columns are mounted simultaneously so the user
           can see the kanban context while chatting. The kanban
           column is flexed to ~40% of the remaining width (after
           the sidebar) and the chat takes the rest. The :key on
           KanbanView forces a fresh mount when the user navigates
           from one kanban to another; the ChatView :key uses
           'task-<id>' so switching to a different task in the
           SAME kanban remounts the chat (clean state, no stale
           scroll position from the previous task). -->
      <div
        v-else-if="
          activeTask &&
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'kanban' &&
          activeTaskWorkspaceItemId === activeWorkspaceItem.id
        "
        class="flex-1 flex min-h-0"
        data-kanban-three-column
      >
        <div
          class="flex flex-col h-full min-h-0"
          :style="kanbanColumnStyle"
          style="border-right: 1px solid var(--color-border)"
        >
          <KanbanView
            :key="'kanban-' + activeWorkspaceItem.id"
            :item="activeWorkspaceItem"
            :workspace-id="activeWorkspace?.id ?? ''"
            :item-id="activeWorkspaceItem.id"
            @add-task="handleKanbanAddTask"
            @move-task="handleKanbanMoveTask"
            @add-column="handleKanbanAddColumn"
            @rename-column="handleKanbanRenameColumn"
            @delete-column="handleKanbanDeleteColumn"
            @reorder-column="handleKanbanReorderColumn"
            @request-rename-column="handleKanbanRequestRenameColumn"
            @request-delete-column="handleKanbanRequestDeleteColumn"
            @select-task="handleKanbanSelectTask"
            @delete-task="handleKanbanDeleteTask"
            @rename-task="handleKanbanRenameTask"
            @edit-routine="handleKanbanEditRoutine"
            @run-routine="handleKanbanRunRoutine"
            @pin-task="handleKanbanPinTask"
            @open-settings="handleOpenKanbanSettings"
          />
        </div>
        <!--
          Resize handle between the kanban column and the chatview
          column. A 4px-wide hit area (w-1 in Tailwind = 4px) with
          a 1px visual bar centered in it; the bar turns violet on
          hover and during an active drag so the user knows the
          handle is grabbable. Mirrors Sidebar.vue's resize handle
          (line 949): same cursor, same opacity-on-hover pattern,
          same data-kanban-resize-handle test selector.

          The drag is owned by startKanbanResize (mousedown handler
          below) which adds document-level mousemove/mouseup
          listeners so a fast drag that outruns the handle still
          tracks correctly.
        -->
        <div
          class="shrink-0 w-1 cursor-col-resize relative"
          :class="{ 'opacity-100': isKanbanResizing }"
          :style="{
            backgroundColor: isKanbanResizing ? 'var(--color-violet)' : 'var(--color-border)',
          }"
          data-kanban-resize-handle
          data-testid="kanban-resize-handle"
          @mousedown="startKanbanResize"
          @mouseenter="
            (e) => ((e.currentTarget as HTMLElement).style.backgroundColor = 'var(--color-violet)')
          "
          @mouseleave="
            (e) => {
              if (!isKanbanResizing)
                (e.currentTarget as HTMLElement).style.backgroundColor = 'var(--color-border)'
            }
          "
        ></div>
        <div class="flex-1 flex flex-col h-full min-w-0 min-h-0">
          <ChatView
            :key="'task-' + activeTask.id"
            :chat-id="activeTask.id"
            :chat-name="activeTask.name"
            :type="'task'"
            :cwd="activeWorkspaceItem.path || ''"
            :task-id="activeTask.id"
            :task-name="activeTask.name"
            :project-name="activeWorkspaceItem.name || ''"
            :show-header="true"
            @close="handleCloseTaskView"
          />
        </div>
      </div>
      <!-- Task view (non-kanban parents, e.g. chat tasks): single
           column, no header. Preserved for backward compatibility. -->
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
      <!-- Kanban view (was inline in WorkspaceItem.vue; now mounted
           in the main content area so the board is no longer cramped
           in the sidebar). Renders only when an active kanban item
           is selected AND no task is currently being viewed (the
           3-column branch above already handles task-with-kanban-parent).
           The :key forces a fresh mount when the user navigates
           from one kanban to another (KanbanView fetches columns
           on mount). -->
      <KanbanView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'"
        :key="'kanban-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        @add-task="handleKanbanAddTask"
        @move-task="handleKanbanMoveTask"
        @add-column="handleKanbanAddColumn"
        @rename-column="handleKanbanRenameColumn"
        @delete-column="handleKanbanDeleteColumn"
        @reorder-column="handleKanbanReorderColumn"
        @request-rename-column="handleKanbanRequestRenameColumn"
        @request-delete-column="handleKanbanRequestDeleteColumn"
        @select-task="handleKanbanSelectTask"
        @delete-task="handleKanbanDeleteTask"
        @rename-task="handleKanbanRenameTask"
        @edit-routine="handleKanbanEditRoutine"
        @run-routine="handleKanbanRunRoutine"
        @pin-task="handleKanbanPinTask"
        @open-settings="handleOpenKanbanSettings"
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

    <!-- Global error notification stack -->
    <NotificationContainer />

    <!-- Kanban column editor: add / rename / delete a column on the
         currently-active kanban item. Mounted at the AppLayout root
         (not inside the KanbanView's scoped tree) so the modal's
         internal Teleport/animation lifecycle works cleanly even if
         the KanbanView branch unmounts mid-edit (e.g. the user
         clicks a task card and the view switches to ChatView while
         the modal is open). The modal's `show` prop is bound to
         showKanbanColumnEditor; mode/targetId/initialName are set
         by the request-add-column / request-rename-column /
         request-delete-column handlers. -->
    <KanbanColumnEditor
      :show="showKanbanColumnEditor"
      :mode="kanbanColumnEditorMode"
      :initial-name="kanbanColumnEditorInitialName"
      :initial-description="kanbanColumnEditorInitialDescription"
      @close="handleKanbanColumnEditorClose"
      @add="handleKanbanColumnEditorAdd"
      @rename="handleKanbanColumnEditorRename"
      @delete="handleKanbanColumnEditorDelete"
    />

    <!--
      KanbanSettingsDialog — per-board column management. Mounted
      alongside the KanbanColumnEditor (not inside the KanbanView
      scoped tree) so the modal's Teleport/animation lifecycle
      works cleanly even if the KanbanView branch unmounts
      mid-edit. The dialog owns its own KanbanColumnEditor
      instance for per-row rename/delete actions so the two
      dialogs can coexist (a user can open the settings while
      the ⋮ menu is already showing).
    -->
    <KanbanSettingsDialog
      :show="showKanbanSettingsDialog"
      :item="activeWorkspaceItem ?? null"
      @close="handleCloseKanbanSettings"
      @add-column="handleKanbanSettingsAddColumn"
      @edit-column="handleKanbanSettingsEditColumn"
      @delete-column="handleKanbanSettingsDeleteColumn"
    />
  </div>
</template>

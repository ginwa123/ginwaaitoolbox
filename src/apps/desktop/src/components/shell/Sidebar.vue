<script setup lang="ts">
import { ref, computed, watch, onMounted, onUnmounted, inject, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import WorkspaceList from '../workspace/WorkspaceList.vue'
import ChatsList from '../views/ChatsList.vue'
import WorkspaceModal from '../dialogs/WorkspaceModal.vue'
import RenameWorkspaceModal from '../dialogs/RenameWorkspaceModal.vue'
import RenameTaskModal from '../dialogs/RenameTaskModal.vue'
import AddItemDialog from '../dialogs/AddItemDialog.vue'
import AddKanbanDialog from '../dialogs/AddKanbanDialog.vue'
// NEW (design-mode feature): the modal that creates a design
// workspace item (DesignView's container). Opened via the
// "+ Add Item → Add Design" dropdown option in WorkspaceList.
// Plan: docs/superpowers/plans/2026-06-13-design-mode.md.
import AddDesignDialog from '../design/AddDesignDialog.vue'
import AddMemoryDialog from '../dialogs/AddMemoryDialog.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import AddTaskDialog from '../dialogs/AddTaskDialog.vue'
import AddTaskPickerDialog from '../dialogs/AddTaskPickerDialog.vue'
import AddRoutineDialog from '../dialogs/AddRoutineDialog.vue'
import EditRoutineDialog from '../dialogs/EditRoutineDialog.vue'
import type { EditRoutineParams } from '../dialogs/EditRoutineDialog.vue'
import type { RoutineMeta, WorkspaceItem } from '../../stores/workspaces'
import * as api from '../../api'

// Inject isLLMProcessing from App.vue
const isLLMProcessing = inject<Ref<boolean>>('isLLMProcessing', ref(false))

const router = useRouter()
const navigationStore = useNavigationStore()

const props = defineProps<{
  collapsed?: boolean
  width?: number
}>()

const emit = defineEmits<{
  navigate: [
    id: string,
    chatName?: string,
    taskId?: string,
    workspaceId?: string,
    itemId?: string,
  ]
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

// Compute a 1–2 letter monogram for a workspace, used by the
// collapsed-state tile (no icons). Algorithm:
//   1. Strip non-alphanumeric chars
//   2. Take the first letter; if a word boundary appears within the
//      first 5 letters, use that second letter as well (e.g.
//      "agentic_coding_zig" → "A", "my project" → "M" + "P" → "MP",
//      "wonderful" → "W").
//   3. Uppercase and clamp to ≤ 2 chars.
//
// Falls back to `?` if the name is empty/whitespace-only (defensive —
// the workspace store validates names server-side, but a future
// client-only flow could produce an empty name).
const workspaceMonogram = (name: string): string => {
  const cleaned = name.replace(/[^a-zA-Z0-9]/g, '')
  if (cleaned.length === 0) return '?'
  const head = cleaned[0]?.toUpperCase() ?? '?'
  if (cleaned.length < 2) return head
  // Look for the next word-boundary character within the first 6 chars
  // of the *original* name (not the cleaned one — we want to detect
  // space/underscore/hyphen transitions, not stripped chars).
  for (let i = 1; i < Math.min(name.length, 6); i++) {
    const ch = name[i]
    const prev = name[i - 1]
    if (ch && /[a-zA-Z0-9]/.test(ch) && prev && /[^a-zA-Z0-9]/.test(prev)) {
      return head + ch.toUpperCase()
    }
  }
  return head
}

// Expose method to open the Add Task picker dialog. Called by
// AppLayout's <KanbanView> when the user clicks "+" on a kanban
// column (the kanban now lives in the main content area, not in the
// sidebar, so the picker needs to be opened from outside). Uses the
// same flow as handleAddTask below — picker → standard/routine/memory
// → store action. Returns nothing; the picker takes over from there.
const openTaskPicker = (workspaceId: string, itemId: string) => {
  pickerWorkspaceId.value = workspaceId
  pickerItemId.value = itemId
  showAddTaskPicker.value = true
}

// Skip the picker and go straight to the standard chat dialog.
// Used by the kanban's "+ Add on column" path — kanban cards are
// always standard chats (the column is a workflow stage, not a
// task-type discriminator), so the Routine / Memory options would
// be noise. Mirrors the picker → standard dialog transition that
// `handleAddTaskPick('standard')` performs internally.
//
// (Removed in the kanban-add-task-via-detail-dialog feature: the
// kanban now handles its own "+ Add" flow locally via
// KanbanTaskDetailDialog in create mode. Sidebar no longer needs
// to expose this.)

// Handle session events from SSE
const handleSessionEvent = (event: api.SessionEvent) => {
  console.log('[Sidebar] handleSessionEvent:', event)
  // Refresh chats on session change
  if (chatsListRef.value) {
    chatsListRef.value.loadChats()
  }
}

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
// Kanban dialog state (Chunk 6 of workspace-item-kanban plan).
// Reuses `addItemTargetWorkspaceId` as the target workspace (the
// kanban item is created in that workspace, same as folder/memory).
const showAddKanbanDialog = ref(false)
// NEW (design-mode feature): mirrors showAddKanbanDialog for the
// design-mode flow. The 'design' branch in handleAddItem (below)
// flips this on, which mounts <AddDesignDialog> below the kanban
// dialog. See AddDesignDialog.vue for the internal flow.
// Plan: docs/superpowers/plans/2026-06-13-design-mode.md.
const showAddDesignDialog = ref(false)
const showAddMemoryDialog = ref(false)
const addMemoryTargetWorkspaceId = ref<string | null>(null)
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

// ─── Add Task picker + dialog state (Chunk 6) ──────────────────────────────
//
// When the user clicks the green `+` on a workspace item:
//   1. AddTaskPickerDialog opens with two cards (Standard / Routine).
//   2. On pick, the picker closes and either AddTaskDialog (standard)
//      or AddRoutineDialog (routine) opens.
//   3. The create callback calls `workspacesStore.addTask(...)` with
//      the appropriate params and closes the dialog.
//
// We track workspaceId + itemId on each dialog's `Open` ref so the
// create callback knows where to create the task. We don't auto-
// navigate to the new task (the original behavior did) — creating
// a routine doesn't make sense to "open" the same way (the routine
// fires on a schedule, not on user input), and a standard task
// can be opened from the sidebar by the user.
const showAddTaskPicker = ref(false)
const pickerWorkspaceId = ref<string | null>(null)
const pickerItemId = ref<string | null>(null)
const showAddTaskDialog = ref(false)
const addTaskDialogWorkspaceId = ref<string | null>(null)
const addTaskDialogItemId = ref<string | null>(null)
const showAddRoutineDialog = ref(false)
const addRoutineDialogWorkspaceId = ref<string | null>(null)
const addRoutineDialogItemId = ref<string | null>(null)
// Memory task flow (2026-06-20): picked from the AddTaskPickerDialog
// "Memory" card, opens AddMemoryDialog in `mode='task'`, then
// the create callback calls addTask with taskType='memory'.
const showAddMemoryTaskDialog = ref(false)
const addMemoryTaskWorkspaceId = ref<string | null>(null)
const addMemoryTaskItemId = ref<string | null>(null)

// Edit routine (Chunk 7 of task-routines plan): opened by
// handleEditRoutine (triggered by the routine-task row's pencil
// via WorkspaceItemTask → WorkspaceItem → WorkspaceList → Sidebar).
// The dialog is prefilled with the routine's current values via
// `editRoutineTarget` (RoutineMeta | null) and the task's name via
// `editRoutineTaskName`. We keep workspaceId + itemId + taskId on
// separate refs (not a single object) so the submit callback can
// resolve the right routine for the updateRoutine store action.
const showEditRoutineDialog = ref(false)
const editRoutineWorkspaceId = ref<string | null>(null)
const editRoutineItemId = ref<string | null>(null)
const editRoutineTaskId = ref<string | null>(null)

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
  // Carry (workspaceId, itemId) into the URL so the kanban / folder /
  // design view survives a page reload. The URL is the source of
  // truth on reload; the in-memory `activeWorkspaceItemId` would
  // otherwise reset to null on a refresh.
  emit('navigate', 'workspace', undefined, undefined, workspaceId, itemId)
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
  if (itemType === 'kanban') showAddKanbanDialog.value = true
  // NEW (design-mode feature): routes the 'design' itemType to
  // AddDesignDialog. Mirrors the kanban routing above — both
  // dialogs share the (workspaceId, itemType) routing pattern
  // emitted by WorkspaceList. Plan:
  // docs/superpowers/plans/2026-06-13-design-mode.md.
  if (itemType === 'design') showAddDesignDialog.value = true
  if (itemType === 'memory') {
    addMemoryTargetWorkspaceId.value = workspaceId
    showAddMemoryDialog.value = true
  }
}

const handleCreateItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    const itemId = await workspacesStore.addWorkspaceItem(addItemTargetWorkspaceId.value, name, path)
    if (itemId) await workspacesStore.fetchFolderContents(addItemTargetWorkspaceId.value, itemId)
  }
}

// Kanban item creation (Chunk 6 of workspace-item-kanban plan):
// user fills in the name + picks a project folder, AddKanbanDialog
// emits `create(name, path)`, we call workspacesStore.addKanbanItem
// (the store action from Chunk 5) which POSTs to
// /api/workspaces/:wsId/items/kanban and pushes the new item + its
// 3 default columns into the local store. Then close the dialog.
// The new item appears in the sidebar immediately (the workspace
// is auto-expanded by the store action, same UX as
// addWorkspaceItem). The path is required so every chat session
// created under the kanban's tasks has a cwd to run git / file
// tools in.
const handleCreateKanban = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addKanbanItem(
      addItemTargetWorkspaceId.value,
      name,
      path,
    )
  }
  showAddKanbanDialog.value = false
}

const handleCloseAddKanbanDialog = () => {
  showAddKanbanDialog.value = false
}

// NEW (design-mode feature): mirrors handleCreateKanban. User
// fills in the name + picks a project folder, AddDesignDialog
// emits `create(name, path)`, we call workspacesStore.addDesignItem
// (the store action) which POSTs to /api/workspaces/:wsId/items/design
// and pushes the new item (with empty tasks + design_elements
// arrays) into the local store. The new item appears in the
// sidebar immediately and is auto-selected so the user lands in
// the new DesignView. The path is required so every chat session
// / design page created under this design item has a cwd to run
// git / file tools in. Plan:
// docs/superpowers/plans/2026-06-13-design-mode.md.
const handleCreateDesign = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addDesignItem(
      addItemTargetWorkspaceId.value,
      name,
      path,
    )
  }
  showAddDesignDialog.value = false
}

const handleCloseAddDesignDialog = () => {
  showAddDesignDialog.value = false
}

/**
 * Resolve the cwd to scope a new local memory to. Uses the first
 * folder-type item in the target workspace as the project root
 * (the most natural "cwd" for the workspace). Falls back to ''
 * when the workspace has no folder items — the AddMemoryDialog
 * then shows its own "no cwd" error and refuses to submit.
 */
const resolveCwdForMemory = (workspaceId: string): string => {
  // workspacesStore is a Pinia store; its `workspaces` getter
  // auto-unwraps the underlying ref (no `.value` access in the
  // store-public surface). See src/apps/desktop/src/stores/workspaces.ts
  // for the store definition.
  const ws = workspacesStore.workspaces.find((w) => w.id === workspaceId)
  if (!ws) return ''
  // Find the first folder item (item_type === 'folder') — its `path`
  // is the absolute path to a real project directory on disk, which
  // is what the local-memories backend will scope the file to.
  for (const item of ws.items) {
    if (item.item_type === 'folder' && item.path) return item.path
    if (item.item_type === 'design' && item.path) return item.path
  }
  return ''
}

/**
 * Resolve the cwd to scope a new memory TASK to. Unlike
 * `resolveCwdForMemory` (which uses the workspace's first folder),
 * this function takes the SPECIFIC item_id the user picked — the
 * memory task is attached to that item, and the .md file is
 * scoped to that item's path. Returns '' if the item can't be
 * found or has no path (in which case the AddMemoryDialog will
 * show its own "no cwd" error and refuse to submit).
 */
const resolveCwdForItem = (itemId: string): string => {
  const item = workspacesStore.allWorkspaceItems.find((i) => i.id === itemId)
  if (!item) return ''
  return item.path ?? ''
}

const handleCloseAddMemoryDialog = () => {
  showAddMemoryDialog.value = false
  addMemoryTargetWorkspaceId.value = null
}

const handleCreateMemory = async (name: string, _content: string, path: string) => {
  // The local memory file is created by AddMemoryDialog (via
  // createLocalMemory API) and lives at
  // `<cwd>/.nalar/memories/<name>.md`. The next chat in this
  // workspace will pick it up via `loadLocalKnowledge` (see
  // `src/modules/agent/prompts.zig:263`). We currently just log
  // the success — a future iteration could:
  //   - Emit a typed toast (the notifications store currently only
  //     has notifyError, so this would require a `notifySuccess`).
  //   - Register a workspace-item reference so the memory shows
  //     up in the sidebar list (mirrors Add Project's behavior).
  //
  // The 3-arg signature `(name, content, path)` matches the
  // AddMemoryDialog emit shape; the legacy flow doesn't need
  // `content` (the dialog already sent it to the API), so we
  // prefix-underscore it to silence the unused-arg warning.
  console.info(`[Sidebar] local memory created: ${name} at ${path}`)
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

// Open the picker when the user clicks the green `+` on a
// non-kanban workspace item. Chunk 6: previously this directly
// created a `Task <time>` row and auto-navigated. Now we route
// through AddTaskPickerDialog → AddTaskDialog / AddRoutineDialog /
// AddMemoryDialog. Kanban items handle "+ Add" locally inside
// KanbanView.vue (no picker — kanban cards are always standard
// chats; the picker is for non-kanban parents where the user might
// want a routine / memory / chat task).
const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  pickerWorkspaceId.value = workspaceId
  pickerItemId.value = item.id
  showAddTaskPicker.value = true
}

// Route the pick to the right create dialog. The picker dialog
// self-closes on pick (see AddTaskPickerDialog.vue: handleStandard,
// handleRoutine, and handleMemory emit both 'pick' and 'close'),
// so the @close handler (handleCloseAddTaskPicker) runs as a side
// effect of the pick — no explicit close call needed here.
const handleAddTaskPick = (taskType: 'standard' | 'routine' | 'memory') => {
  if (taskType === 'standard') {
    addTaskDialogWorkspaceId.value = pickerWorkspaceId.value
    addTaskDialogItemId.value = pickerItemId.value
    showAddTaskDialog.value = true
  } else if (taskType === 'routine') {
    addRoutineDialogWorkspaceId.value = pickerWorkspaceId.value
    addRoutineDialogItemId.value = pickerItemId.value
    showAddRoutineDialog.value = true
  } else {
    // 'memory' (2026-06-20): open AddMemoryDialog in `mode='task'`
    // (it won't call the API itself; the create callback here
    // calls addTask with taskType='memory' which triggers the
    // backend's file-write + task-insert in one POST).
    addMemoryTaskWorkspaceId.value = pickerWorkspaceId.value
    addMemoryTaskItemId.value = pickerItemId.value
    showAddMemoryTaskDialog.value = true
  }
  // Clear the picker targets so a stale workspaceId/itemId
  // doesn't leak into a future accidental re-open.
  pickerWorkspaceId.value = null
  pickerItemId.value = null
}

const handleCloseAddTaskPicker = () => {
  showAddTaskPicker.value = false
  pickerWorkspaceId.value = null
  pickerItemId.value = null
}

// Standard path: user filled in the name + description in
// AddTaskDialog, hit Create Task. Persist via the store and
// navigate to the new task.
const handleAddTaskCreated = async (name: string, description?: string) => {
  const workspaceId = addTaskDialogWorkspaceId.value
  const itemId = addTaskDialogItemId.value
  if (!workspaceId || !itemId) return
  const taskId = await workspacesStore.addTask(workspaceId, itemId, {
    name,
    description,
  })
  showAddTaskDialog.value = false
  addTaskDialogWorkspaceId.value = null
  addTaskDialogItemId.value = null
  // Defensive: close the picker too. AddTaskPickerDialog already
  // self-closes on pick (see AddTaskPickerDialog.vue handleStandard
  // / handleRoutine), but the create callback is the last word on
  // dialog state — if a future refactor breaks the picker's
  // self-close, this ensures the picker is still gone and no
  // leftover dialog covers the new chat view.
  handleCloseAddTaskPicker()
  if (taskId) {
    workspacesStore.setActiveTask(taskId)
    router.replace({ path: '/app', query: { view: 'task', task: taskId } })
  }
}

const handleCloseAddTaskDialog = () => {
  showAddTaskDialog.value = false
  addTaskDialogWorkspaceId.value = null
  addTaskDialogItemId.value = null
}

// Routine path: user filled in name, description (optional),
// initial_prompt, schedule, enabled in AddRoutineDialog, hit
// Create Routine. Persist via the store with taskType='routine'.
// We do NOT navigate to the new routine — routines are not
// user-driven chats; the user opens the routine from the
// sidebar to inspect its runs.
const handleAddRoutineCreated = async (params: {
  name: string
  description?: string
  initial_prompt: string
  schedule: string
  enabled: boolean
}) => {
  const workspaceId = addRoutineDialogWorkspaceId.value
  const itemId = addRoutineDialogItemId.value
  if (!workspaceId || !itemId) return
  await workspacesStore.addTask(workspaceId, itemId, {
    name: params.name,
    description: params.description,
    taskType: 'routine',
    routine: {
      schedule: params.schedule,
      initial_prompt: params.initial_prompt,
      enabled: params.enabled,
    },
  })
  showAddRoutineDialog.value = false
  addRoutineDialogWorkspaceId.value = null
  addRoutineDialogItemId.value = null
  // Defensive: close the picker too. AddTaskPickerDialog already
  // self-closes on pick, but the create callback is the last word
  // on dialog state — see handleAddTaskCreated for the same
  // rationale applied to the standard path.
  handleCloseAddTaskPicker()
}

const handleCloseAddRoutineDialog = () => {
  showAddRoutineDialog.value = false
  addRoutineDialogWorkspaceId.value = null
  addRoutineDialogItemId.value = null
}

// Memory task flow (2026-06-20). AddMemoryDialog in `mode='task'`
// emits `create(name, content, path)` when the user submits; we
// forward to addTask which POSTs to the backend with
// taskType='memory'. The backend's task_create.zig handles the
// .md file write AND the workspace_item_tasks INSERT in one call
// (and rolls back the .md on task-row failure — no orphan files).
//
// We do NOT navigate to the new memory task — memory tasks have
// no chat session (the .md file IS the content; the AI reads it
// on the next chat in this workspace). The task row shows up in
// the sidebar's task list where the user can inspect it.
const handleCreateMemoryTask = async (
  name: string,
  content: string,
  _path: string,
) => {
  const workspaceId = addMemoryTaskWorkspaceId.value
  const itemId = addMemoryTaskItemId.value
  if (!workspaceId || !itemId) return
  await workspacesStore.addTask(workspaceId, itemId, {
    name,
    taskType: 'memory',
    memory: { name, content },
  })
  showAddMemoryTaskDialog.value = false
  addMemoryTaskWorkspaceId.value = null
  addMemoryTaskItemId.value = null
  // Defensive: close the picker too. AddTaskPickerDialog already
  // self-closes on pick, but the create callback is the last word
  // on dialog state — see handleAddTaskCreated for the same
  // rationale applied to the standard path.
  handleCloseAddTaskPicker()
}

const handleCloseAddMemoryTaskDialog = () => {
  showAddMemoryTaskDialog.value = false
  addMemoryTaskWorkspaceId.value = null
  addMemoryTaskItemId.value = null
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

// Forward drag-and-drop reorder events from <WorkspaceList> to the
// store. The store action does the optimistic update + API call +
// silent rollback on error. Plan:
// docs/plans/2026-06-12-workspace-drag-and-drop.md
const handleReorderWorkspaces = (orderedIds: string[]) => {
  workspacesStore.reorderWorkspaces(orderedIds)
}

// Mirrors handleReorderWorkspaces but scoped to a single
// workspace's items. <WorkspaceList> emits the workspaceId +
// orderedItemIds payload on a successful drop; the store action
// does the optimistic update + API call + silent rollback on
// error. Plan:
// docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md
const handleReorderWorkspaceItems = (
  workspaceId: string,
  orderedItemIds: string[],
) => {
  workspacesStore.reorderWorkspaceItems(workspaceId, orderedItemIds)
}

// NEW (pinned-tasks feature, plan:
// docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md):
// pin/unpin and drag-reorder of the pinned subset, both forwarded
// from <WorkspaceItem> via <WorkspaceList>. The store actions
// perform the optimistic update + API call + silent rollback.
const handlePinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  workspacesStore.pinTask(workspaceId, itemId, taskId, isPinned)
}

const handleReorderPinnedTasks = (
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
) => {
  workspacesStore.reorderPinnedTasks(workspaceId, itemId, orderedIds)
}

// ─── Routines (Chunk 7 of task-routines plan) ────────────────────────────
// These two handlers close the wiring loop from the routine-task
// row in WorkspaceItemTask.vue (which emits `runRoutine` and
// `editRoutine`) up through WorkspaceItem → WorkspaceList → here.
// Sidebar is the only component that touches the store, so it
// owns the user-visible side effects (route to chat, open the
// edit dialog, call runRoutine / updateRoutine).

// Run now: fire the routine via the store, then navigate to the
// task's chat view. The backend returns the session_id (= task.id
// by codebase invariant); we set the active task and route. The
// chat view's existing SSE /chat-view connection picks up the new
// user message when the worker writes it (see Task 7.5 E2E).
const handleRunRoutine = async (
  workspaceId: string,
  itemId: string,
  taskId: string,
) => {
  const result = await workspacesStore.runRoutine(workspaceId, itemId, taskId)
  // Per the `task.id == session_id` convention (Migration 052
  // dropped the redundant `workspace_item_tasks.session_id`
  // column), `taskId` IS the session id. We no longer need to
  // read `result.session_id` — the routine fire returns the
  // task_id as the session id, and the URL query is just for
  // downstream cache hydration.
  if (result) {
    workspacesStore.setActiveTask(taskId)
    router.replace({
      path: '/app',
      query: { view: 'task', task: taskId, session: taskId },
    })
  }
}

// Edit routine: capture the workspace / item / task ids on the
// three refs and open the dialog. The dialog's `routine` and
// `taskName` props are bound to the two `computed`s below, which
// look up the routine in the workspaces tree (and tolerate a
// stale id by returning null / '' — the dialog renders only when
// `routine` is non-null, so a missing target simply doesn't
// open).
const handleEditRoutine = (
  workspaceId: string,
  itemId: string,
  taskId: string,
) => {
  editRoutineWorkspaceId.value = workspaceId
  editRoutineItemId.value = itemId
  editRoutineTaskId.value = taskId
  showEditRoutineDialog.value = true
}

const handleEditRoutineClose = () => {
  showEditRoutineDialog.value = false
  editRoutineWorkspaceId.value = null
  editRoutineItemId.value = null
  editRoutineTaskId.value = null
}

// Submit: pass the form fields to the store's updateRoutine
// action (added in Chunk 5). The store action does an optimistic
// name update + API call + rollback on error. Routine schedule /
// initial_prompt / enabled updates surface on the next SSE
// refresh (the backend recomputes next_run_at on update).
const handleEditRoutineSubmitted = async (params: EditRoutineParams) => {
  if (
    !editRoutineWorkspaceId.value ||
    !editRoutineItemId.value ||
    !editRoutineTaskId.value
  ) {
    return
  }
  await workspacesStore.updateRoutine(
    editRoutineWorkspaceId.value,
    editRoutineItemId.value,
    editRoutineTaskId.value,
    {
      name: params.name,
      schedule: params.schedule,
      initial_prompt: params.initial_prompt,
      enabled: params.enabled,
    },
  )
  showEditRoutineDialog.value = false
  editRoutineWorkspaceId.value = null
  editRoutineItemId.value = null
  editRoutineTaskId.value = null
}

// Look up the routine being edited in the workspaces tree. The
// EditRoutineDialog's `routine` prop expects RoutineMeta | null;
// returning null when the lookup misses keeps the dialog from
// opening (the dialog's v-if="show && routine" gate handles it).
const editRoutineTarget = computed<RoutineMeta | null>(() => {
  if (
    !editRoutineWorkspaceId.value ||
    !editRoutineItemId.value ||
    !editRoutineTaskId.value
  ) {
    return null
  }
  for (const ws of workspacesStore.workspaces) {
    if (ws.id !== editRoutineWorkspaceId.value) continue
    const item = ws.items.find((i) => i.id === editRoutineItemId.value)
    const task = item?.tasks?.find((t) => t.id === editRoutineTaskId.value)
    return task?.routine ?? null
  }
  return null
})

// The task's display name (for the dialog's subtitle). Mirrors
// editRoutineTarget's lookup but returns the name.
const editRoutineTaskName = computed<string>(() => {
  if (
    !editRoutineWorkspaceId.value ||
    !editRoutineItemId.value ||
    !editRoutineTaskId.value
  ) {
    return ''
  }
  for (const ws of workspacesStore.workspaces) {
    if (ws.id !== editRoutineWorkspaceId.value) continue
    const item = ws.items.find((i) => i.id === editRoutineItemId.value)
    const task = item?.tasks?.find((t) => t.id === editRoutineTaskId.value)
    if (task) return task.name
  }
  return ''
})

// ─── Kanban handlers ────────────────────────────────────────────────────────
//
// The kanban board lives in the main content area (rendered by
// <AppLayout> when activeWorkspaceItem.item_type === 'kanban'), not
// inline in the sidebar anymore. AppLayout's <KanbanView> wires its
// events directly to the workspaces store (moveTaskToColumn,
// addKanbanColumn, updateKanbanColumn, deleteKanbanColumn) — see
// AppLayout.vue's handle*Kanban* functions. The only Sidebar-side
// concern is the "+ Add" button on a column, which opens the
// AddTaskPickerDialog; that flow is exposed via `openTaskPicker`
// (see defineExpose below) and called by AppLayout.
//
// Kept here for reference (deleted in this commit):
//   - handleAddKanbanTask    (replaced by AppLayout's call to
//                             sidebarRef.openTaskPicker)
//   - handleMoveKanbanTask   (moved to AppLayout's
//                             handleKanbanMoveTask)
//   - handleAddKanbanColumn  (moved to AppLayout's
//                             handleKanbanAddColumn)
//   - handleRenameKanbanColumn (moved to AppLayout's
//                               handleKanbanRenameColumn)
//   - handleDeleteKanbanColumn (moved to AppLayout's
//                               handleKanbanDeleteColumn)

// Expose the task event handlers for AppLayout to call when the
// kanban board (now mounted in the main content area, not the
// sidebar) emits select-task / delete-task / rename-task /
// edit-routine / run-routine / pin-task. AppLayout holds the
// kanban view; the handlers themselves still live here because
// they need access to the modal state (rename, edit-routine) and
// the chatsList ref (select-task resets the chat row's active
// state). Re-exporting via defineExpose keeps the kanban events
// in the same place the original WorkspaceItem path was using.
//
// Placed at the end of the script (rather than with the other
// state) so the handler references are not in the temporal dead
// zone — the arrow functions are only invoked from AppLayout at
// runtime, by which point all `handle*` consts are initialized.
defineExpose({
  updateChatId,
  openTaskPicker,
  // Pass-throughs for the kanban's task events. The signature
  // matches the existing handlers exactly; AppLayout's KanbanView
  // forwards its emitted events to these.
  selectTask: (taskId: string) => handleSelectTask(taskId),
  deleteTask: (workspaceId: string, itemId: string, taskId: string) =>
    handleDeleteTask(workspaceId, itemId, taskId),
  renameTask: (
    workspaceId: string,
    itemId: string,
    taskId: string,
    currentName: string,
  ) => handleRenameTask(workspaceId, itemId, taskId, currentName),
  editRoutine: (workspaceId: string, itemId: string, taskId: string) =>
    handleEditRoutine(workspaceId, itemId, taskId),
  runRoutine: (workspaceId: string, itemId: string, taskId: string) =>
    handleRunRoutine(workspaceId, itemId, taskId),
  pinTask: (
    workspaceId: string,
    itemId: string,
    taskId: string,
    isPinned: boolean,
  ) => handlePinTask(workspaceId, itemId, taskId, isPinned),
})
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

    <!-- Collapse/Expand Button. A minimal chevron-only button — no
         shadow, no scale on hover, just a thin border that matches
         the sidebar's typographic treatment. The chevron points in
         the *target* direction (left when expanded, right when
         collapsed) so the click intent reads at a glance. -->
    <button
      @click="toggleCollapse"
      data-testid="sidebar-collapse-toggle"
      class="absolute -right-2.5 top-16 z-20 w-5 h-5 rounded flex items-center justify-center transition-colors duration-150"
      style="background: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      :title="isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'"
      :aria-label="isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'"
    >
      <svg
        class="w-3 h-3 transition-transform duration-150"
        :style="{ color: 'var(--semantic-text-dim)', transform: isCollapsed ? 'rotate(180deg)' : 'rotate(0deg)' }"
        fill="none" viewBox="0 0 24 24" stroke="currentColor"
      >
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
      </svg>
    </button>

    <!-- Header. Minimal text-driven header — no logo gradient
         pill, no decorative sub-label. Two layouts: collapsed shows
         a thin monogram "N" character; expanded shows "Nalar" word
         + a small settings chevron. The thin border-bottom keeps
         the section boundary visible without any visual heaviness. -->
    <div
      class="h-12 flex items-center shrink-0"
      :class="isCollapsed ? 'justify-center px-0' : 'px-4 justify-between'"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div
        v-if="!isCollapsed"
        class="flex items-center gap-2"
        data-testid="sidebar-header-expanded"
      >
        <span class="text-sm font-semibold tracking-tight" style="color: var(--semantic-text);">Nalar</span>
      </div>
      <span
        v-else
        class="text-sm font-semibold tracking-tight"
        style="color: var(--semantic-text);"
        title="Nalar"
        aria-label="Nalar"
        data-testid="sidebar-header-collapsed"
      >N</span>
      <button
        v-if="!isCollapsed"
        @click="goToSettings"
        class="text-xs font-medium transition-colors duration-150 hover:text-[--semantic-text]"
        style="color: var(--semantic-text-dim);"
        title="Settings"
        aria-label="Settings"
        data-testid="sidebar-settings-button"
      >
        Settings
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
          @run-routine="handleRunRoutine"
          @edit-routine="handleEditRoutine"
          @load-more-tasks="handleLoadMoreTasks"
          @reorder-workspaces="handleReorderWorkspaces"
          @reorder-workspace-items="handleReorderWorkspaceItems"
          @pin-task="handlePinTask"
          @reorder-pinned-tasks="handleReorderPinnedTasks"
        />
        <!-- Collapsed workspaces: minimal text-driven monograms.
             Each workspace is rendered as a 1-2 letter monogram
             (first letters of the workspace name) in a thin-bordered
             rounded square. NO folder/emoji icons — the monogram is
             pure typography on a neutral background. The ACTIVE
             workspace (workspace.expanded === true) gets a 2px
             violet left accent bar (matching the active row
             treatment used elsewhere in the sidebar) so the user
             can glance to find which workspace is open without
             needing labels. Tooltips show the full workspace name
             on hover so labels aren't lost. -->
        <div v-else class="flex flex-col items-center gap-1 py-1">
          <button
            v-for="workspace in workspacesStore.workspaces"
            :key="workspace.id"
            @click="handleToggleWorkspace(workspace.id)"
            data-testid="collapsed-workspace-button"
            class="relative w-9 h-9 rounded-md flex items-center justify-center text-xs font-semibold tracking-tight transition-colors duration-150"
            :style="workspace.expanded
              ? 'background: transparent; color: var(--semantic-active-text); border: 1px solid var(--color-border); box-shadow: inset 2px 0 0 0 var(--semantic-active-text);'
              : 'background: transparent; color: var(--semantic-text-dim); border: 1px solid var(--color-border);'"
            :title="workspace.name"
            :aria-label="`Open workspace ${workspace.name}`"
          >
            {{ workspaceMonogram(workspace.name) }}
          </button>
          <button
            @click="handleAddWorkspace"
            data-testid="collapsed-add-workspace-button"
            class="w-9 h-9 rounded-md flex items-center justify-center text-sm transition-colors duration-150 hover:text-[--semantic-text]"
            style="color: var(--semantic-text-dim);"
            title="Add Workspace"
            aria-label="Add Workspace"
          >
            +
          </button>
        </div>
      </div>
    </nav>

    <!-- Modals -->
    <WorkspaceModal :show="showAddWorkspaceModal" @close="handleCloseModal" @create="handleCreateWorkspace" />
    <RenameWorkspaceModal :show="showRenameWorkspaceModal" :current-name="renameTargetName" @close="handleCloseRenameModal" @rename="handleConfirmRename" />
    <RenameTaskModal :show="showRenameTaskModal" :current-name="renameTargetTaskName" @close="handleCloseTaskRenameModal" @rename="handleConfirmTaskRename" />
    <AddItemDialog :show="showAddItemDialog" @close="handleCloseAddItemDialog" @create="handleCreateItem" />
    <AddKanbanDialog :show="showAddKanbanDialog" @close="handleCloseAddKanbanDialog" @create="handleCreateKanban" />
    <!-- NEW (design-mode feature): modal for creating a design-mode
         workspace item. Wired to the 'design' itemType in
         handleAddItem (above). See AddDesignDialog.vue for the
         internal flow. Plan:
         docs/superpowers/plans/2026-06-13-design-mode.md. -->
    <AddDesignDialog :show="showAddDesignDialog" @close="handleCloseAddDesignDialog" @create="handleCreateDesign" />
    <AddMemoryDialog
      :show="showAddMemoryDialog"
      :cwd="addMemoryTargetWorkspaceId ? resolveCwdForMemory(addMemoryTargetWorkspaceId) : ''"
      @close="handleCloseAddMemoryDialog"
      @create="handleCreateMemory"
    />
    <AddTaskPickerDialog :show="showAddTaskPicker" @close="handleCloseAddTaskPicker" @pick="handleAddTaskPick" />
    <AddTaskDialog :show="showAddTaskDialog" @close="handleCloseAddTaskDialog" @create="handleAddTaskCreated" />
    <AddRoutineDialog :show="showAddRoutineDialog" @close="handleCloseAddRoutineDialog" @create="handleAddRoutineCreated" />
    <AddMemoryDialog
      v-if="addMemoryTaskItemId"
      :show="showAddMemoryTaskDialog"
      :cwd="resolveCwdForItem(addMemoryTaskItemId)"
      mode="task"
      @close="handleCloseAddMemoryTaskDialog"
      @create="handleCreateMemoryTask"
    />
    <EditRoutineDialog
      :show="showEditRoutineDialog"
      :routine="editRoutineTarget"
      :task-name="editRoutineTaskName"
      @close="handleEditRoutineClose"
      @submit="handleEditRoutineSubmitted"
    />
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

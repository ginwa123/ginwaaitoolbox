<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
import { ref, computed, onUnmounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import { useNotificationStore } from '../../stores/notifications'
import WorkspaceList from '../workspace/WorkspaceList.vue'
import ChatsList from '../views/ChatsList.vue'
import WorkspaceModal from '../dialogs/WorkspaceModal.vue'
import RenameWorkspaceModal from '../dialogs/RenameWorkspaceModal.vue'
import RenameTaskModal from '../dialogs/RenameTaskModal.vue'
import RenameDesignPageModal from '../dialogs/RenameDesignPageModal.vue'
import AddItemDialog from '../dialogs/AddItemDialog.vue'
import AddKanbanDialog from '../dialogs/AddKanbanDialog.vue'
// NEW (design-mode feature): the modal that creates a design
// workspace item (DesignView's container). Opened via the
// "+ Add Item → Add Design" dropdown option in WorkspaceList.
// Plan: docs/superpowers/plans/2026-06-13-design-mode.md.
import AddDesignDialog from '../design/AddDesignDialog.vue'
import AddAgentDialog from '../dialogs/AddAgentDialog.vue'
import AddRoutineItemDialog from '../dialogs/AddRoutineItemDialog.vue'
import AddMemoryDialog from '../dialogs/AddMemoryDialog.vue'
import ConfirmDialog from '../dialogs/ConfirmDialog.vue'
import AddTaskPickerDialog from '../dialogs/AddTaskPickerDialog.vue'
import type { WorkspaceItem } from '../../stores/workspaces'
import * as api from '../../api'
import { buildTaskUrlQuery } from '../../helpers/buildTaskUrlQuery'

const router = useRouter()
const route = useRoute()
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
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06):
    // optional 6th arg — page id for the design-view navigation
    // (so a click on a design page in the sidebar tree switches
    // the URL off `?view=task` back to `?view=workspace&pageId=Z`).
    // Matches the matching AppLayout.handleNavigate signature.
    pageId?: string,
    // NEW (kanban default-URL, 2026-08-06): optional 7th arg —
    // a pre-built `?sorts=` query string. Sidebar populates it
    // when the user clicks a kanban workspace item (commits the
    // default sort per column). AppLayout.handleNavigate mirrors
    // it into the URL. Undefined for non-kanban navigations.
    sortsParam?: string,
  ]
  'toggle-collapse': []
  resize: [width: number]
}>()

// Default task name for the auto-created standard chat. The user
// clicks "Standard Chat" on the picker → we create the task with
// this name and navigate straight to the chatview. Renaming is
// available via the task row's rename modal, and ChatView's
// existing first-message convention auto-renames the chat once
// the user sends a message.
const DEFAULT_NEW_CHAT_NAME = 'New Chat'

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

const workspacesStore = useWorkspacesStore()
const sidebarStore = useSidebarStore()

// State
const isCollapsed = computed(() => props.collapsed ?? false)
const sidebarWidth = computed(() => props.width ?? 280)

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
// NEW (rename-design-pages plan, 2026-08-06): ⋮ menu "Rename"
// opens the RenameDesignPageModal. Same four-ref pattern as the
// task-rename state above — the four vars survive across modal
// close + reopen lifecycles, since the modal's emit('rename', name)
// only carries the name (not the ids).
const showRenameDesignPageModal = ref(false)
const renameTargetDesignPageWorkspaceId = ref<string | null>(null)
const renameTargetDesignPageItemId = ref<string | null>(null)
const renameTargetDesignPageId = ref<string | null>(null)
const renameTargetDesignPageName = ref('')

// ─── Add Task picker + per-type dialog state (Chunk 6) ──────────────────────
//
// When the user clicks the green `+` on a workspace item:
//   1. AddTaskPickerDialog opens with two cards (Standard / Memory).
//   2. On pick, the picker closes and the per-type flow runs:
//      - Standard: auto-create a task named "New Chat" and navigate
//        straight to its ChatView. No dialog (the "name + description"
//        prompt was noise — chat name is editable later via the rename
//        modal on the task row, and an empty description is fine).
//      - Memory:  open AddMemoryDialog in `mode='task'` (needs content
//        and the .md filename).
//
// We track workspaceId + itemId on each dialog's `Open` ref so the
// create callback knows where to create the task. Memory tasks do
// NOT auto-navigate — memories have no chat session to open.
// Standard tasks always auto-navigate to their new ChatView (the
// user just clicked "Standard Chat", they want to be IN the chat).
const showAddTaskPicker = ref(false)
const pickerWorkspaceId = ref<string | null>(null)
const pickerItemId = ref<string | null>(null)
// Memory task flow (2026-06-20): picked from the AddTaskPickerDialog
// "Memory" card, opens AddMemoryDialog in `mode='task'`, then
// the create callback calls addTask with taskType='memory'.
const showAddMemoryTaskDialog = ref(false)
const addMemoryTaskWorkspaceId = ref<string | null>(null)
const addMemoryTaskItemId = ref<string | null>(null)

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

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- legacy pagination path retained for diff readability; not wired up after the chatsListRef refactor.
const _loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  try {
    const data = await api.getChats('created_at', chatsSortDirection.value, 20)
    const savedSessionId = navigationStore.sessionId
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    navItems.value = (data.sessions || []).map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',      icon: '💬',
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

// eslint-disable-next-line @typescript-eslint/no-unused-vars
const _loadMoreChats = async () => {
  if (!chatsHasMore.value || chatsLoading.value || !chatsNextCursor.value) return
  chatsLoading.value = true
  try {
    const data = await api.getChats('created_at', chatsSortDirection.value, 20, chatsNextCursor.value)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
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
// eslint-disable-next-line @typescript-eslint/no-unused-vars
const _toggleNavSectionAndReload = () => {
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

/**
 * Ctrl/Cmd+click (or middle click) on a workspace item: open a real
 * browser tab and stay where the user is. The click never navigates,
 * so nothing in the render chain has to know about it.
 */
const handleOpenItemInBackground = (payload: {
  workspaceId: string
  itemId: string
  name: string
  itemType?: string
}) => {
  const href = router.resolve({
    path: '/app',
    query: { view: 'workspace', workspaceId: payload.workspaceId, itemId: payload.itemId },
  }).href
  window.open(href, '_blank', 'noopener')
}

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
  // NEW (kanban-sort-by default-URL, 2026-08-06): when the user
  // clicks a kanban workspace item, ALWAYS append `?sorts=` to the
  // URL with the default sort (`updated_at:desc`) for every column.
  // The user's mental model: a URL without `sorts` means "no
  // explicit sort" — but they want the URL to commit to a default
  // on first click so a refresh preserves it (and so the wire
  // payload doesn't carry silent defaults). Folders / designs /
  // chats don't get the sort param.
  //
  // FIX (kanban-sort-independence, task_1785730557641, 2026-08-06,
  // refresh follow-up): DO NOT overwrite the URL's existing `sorts`
  // when the user re-navigates to the SAME kanban. Pre-fix, every
  // Sidebar click on a kanban wrote `?sorts=col_X:updated_at:desc,...`
  // for every column — clobbering the user's custom picks (e.g.
  // col_X:name:desc) with the default. The fix: only write the
  // default when the URL doesn't already have `sorts=` for this
  // kanban. If the URL has sorts, preserve them (the user has
  // already committed to those picks on a previous visit).
  //
  // Build the `sorts` string from the kanban's columns. If the
  // columns aren't loaded yet, fetch them on demand (cheap HTTP
  // GET, idempotent) so the URL is complete on the first click.
  let sortsParam: string | undefined
  if (item?.item_type === 'kanban') {
    // Preserve the existing URL's `sorts` for THIS kanban (the
    // user has already committed to those picks). Only fall back
    // to building the default if there's no existing sorts — this
    // is the FIRST visit to this kanban (URL has no sorts at all,
    // or the current itemId doesn't match the kanban in the URL).
    const existingSorts = route.query.sorts as string | undefined
    const urlItemId = route.query.itemId as string | undefined
    if (existingSorts && urlItemId === itemId) {
      // Re-navigation to the SAME kanban — preserve the user's
      // existing sort picks so we don't clobber them with the
      // default. The KanbanView's URL-restore on mount reads
      // `sorts` and applies each entry to its column.
      sortsParam = existingSorts
    } else {
      const columns = item.kanban_columns ?? []
      if (columns.length === 0) {
        // Fire-and-await: the URL we emit must include the column ids,
        // so we wait for the columns to land. fetchKanbanColumns is
        // idempotent — safe to call even if columns are already in
        // flight from elsewhere (e.g. Sidebar expansion).
        try {
          await workspacesStore.fetchKanbanColumns(workspaceId, itemId)
        } catch {
          // Swallow — the URL will simply omit `sorts` and the
          // KanbanView mount path will apply its own fallback when
          // columns arrive. Better than throwing mid-click.
        }
      }
    }
  }
  // Carry (workspaceId, itemId) into the URL so the kanban / folder /
  // design view survives a page reload. The URL is the source of
  // truth on reload; the in-memory `activeWorkspaceItemId` would
  // otherwise reset to null on a refresh.
  emit('navigate', 'workspace', undefined, undefined, workspaceId, itemId, undefined, sortsParam)
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
  // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
  // routes the 'agent' itemType to the new AddAgentDialog.
  if (itemType === 'agent') showAddAgentDialog.value = true
  // Workspace routines (Migration 084, plan
  // 2026-09-10-workspace-items-routines): routes the 'routine'
  // itemType to AddRoutineItemDialog.
  if (itemType === 'routine') showAddRoutineItemDialog.value = true
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

// Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
// agent item create + dialog state — mirrors the design flow above.
const showAddAgentDialog = ref(false)
const handleCreateAgent = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addAgentItem(
      addItemTargetWorkspaceId.value,
      name,
      path,
    )
  }
  showAddAgentDialog.value = false
}
const handleCloseAddAgentDialog = () => {
  showAddAgentDialog.value = false
}

// Workspace routines (Migration 084, plan
// 2026-09-10-workspace-items-routines): routine item create +
// dialog state — mirrors the agent flow above.
const showAddRoutineItemDialog = ref(false)
const handleCreateRoutineItem = async (name: string, path: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addRoutineItem(
      addItemTargetWorkspaceId.value,
      name,
      path,
    )
  }
  showAddRoutineItemDialog.value = false
}
const handleCloseAddRoutineItemDialog = () => {
  showAddRoutineItemDialog.value = false
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
const handleCreateWorkspace = (name: string) => workspacesStore.addWorkspace(name)
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

// ─── Rename Design Page (rename-design-pages, 2026-08-06) ───────────────
//
// Mirrors the workspace-rename + task-rename patterns. The state
// is split across four refs (workspace id, item id, page id, name)
// because the modal's emit('rename', name) only carries the name —
// the ids need to survive across the modal's close + reopen cycle.
//
// On confirm, calls `workspacesStore.renameDesignPage(...)`. The
// store handles the optimistic update + rollback + PATCH
// round-trip; Sidebar's only job is opening the modal + dispatching
// the action. Failure surfaces as a toast via the store's catch
// (renamed page = re-throws so the modal close awaits, then the
// caller catches + notifies).
const handleRenameDesignPage = (
  workspaceId: string,
  itemId: string,
  pageId: string,
  currentName: string,
) => {
  renameTargetDesignPageWorkspaceId.value = workspaceId
  renameTargetDesignPageItemId.value = itemId
  renameTargetDesignPageId.value = pageId
  renameTargetDesignPageName.value = currentName
  showRenameDesignPageModal.value = true
}

const handleConfirmDesignPageRename = async (newName: string) => {
  if (
    renameTargetDesignPageWorkspaceId.value &&
    renameTargetDesignPageItemId.value &&
    renameTargetDesignPageId.value
  ) {
    try {
      await workspacesStore.renameDesignPage(
        renameTargetDesignPageWorkspaceId.value,
        renameTargetDesignPageItemId.value,
        renameTargetDesignPageId.value,
        newName,
      )
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      useNotificationStore().notifyError('Failed to rename page', message)
    }
  }
  showRenameDesignPageModal.value = false
  renameTargetDesignPageWorkspaceId.value = null
  renameTargetDesignPageItemId.value = null
  renameTargetDesignPageId.value = null
  renameTargetDesignPageName.value = ''
}

const handleCloseDesignPageRenameModal = () => {
  showRenameDesignPageModal.value = false
  renameTargetDesignPageWorkspaceId.value = null
  renameTargetDesignPageItemId.value = null
  renameTargetDesignPageId.value = null
  renameTargetDesignPageName.value = ''
}

// Shared standard-chat create+navigate flow (2026-09-09 agent-mode
// direct-to-chat): auto-create a task named "New Chat" and navigate
// straight to its ChatView. Used by BOTH the picker Standard-Chat pick
// (`handleAddTaskPick('standard')` below) and the agent-mode direct path
// (`handleAddTask` bypasses the picker for `item_type === 'agent'`).
// The task row appears in the sidebar's task list under the parent item;
// the chat name is "New Chat" until the user renames it or the first user
// message auto-renames it (ChatView's existing convention).
const createAndOpenStandardChat = async (workspaceId: string, itemId: string) => {
  const taskId = await workspacesStore.addTask(workspaceId, itemId, {
    name: DEFAULT_NEW_CHAT_NAME,
  })
  if (taskId) {
    workspacesStore.setActiveTask(taskId)
    // NEW (add-workspace-id-params, 2026-08-06): include the
    // workspaceId + itemId in the URL so the auto-created chat task
    // carries the kanban / folder / design breadcrumb. Pre-fix the
    // URL was just `?view=task&task=X` — sharing / refreshing lost
    // the workspace context. The helper reads from the active store
    // state set by `handleSelectItem` (which fired before the
    // picker opened).
    router.replace({
      path: '/app',
      query: buildTaskUrlQuery({
        taskId,
        activeWorkspaceId: workspacesStore.activeWorkspace?.id ?? null,
        activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
        activeDesignPageId: workspacesStore.activeDesignPageId,
        activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
      }),
    })
  }
}

// Open the picker when the user clicks the green `+` on a
// non-agent workspace item. Chunk 6: previously this directly
// created a `Task <time>` row and auto-navigated. Now we route
// through AddTaskPickerDialog → AddTaskDialog / AddRoutineDialog /
// AddMemoryDialog. Kanban items handle "+ Add" locally inside
// KanbanView.vue (no picker — kanban cards are always standard
// chats; the picker is for non-kanban parents where the user might
// want a routine / memory / chat task).
//
// Agent-mode items (`item_type === 'agent'`) skip the picker entirely
// (2026-09-09): an agent item IS a chat container, so `+` directly
// creates a Standard Chat and opens it — no Routine / Memory choice.
const handleAddTask = (workspaceId: string, item: WorkspaceItem) => {
  if (item.item_type === 'agent') {
    void createAndOpenStandardChat(workspaceId, item.id)
    return
  }
  pickerWorkspaceId.value = workspaceId
  pickerItemId.value = item.id
  showAddTaskPicker.value = true
}

// Route the pick to the right create flow. The picker dialog
// self-closes on pick (see AddTaskPickerDialog.vue: handleStandard,
// handleRoutine, and handleMemory emit both 'pick' and 'close'),
// so the @close handler (handleCloseAddTaskPicker) runs as a side
// effect of the pick — no explicit close call needed here.
//
// For 'standard' we DON'T show a dialog. The previous flow opened
// AddTaskDialog asking for a name + description, but that was pure
// friction: the user just clicked "Standard Chat", they want to
// start chatting, not write a name. Auto-create a task named
// "New Chat" and navigate straight to its ChatView. The chat name
// is editable later via the rename modal on the task row (and via
// the auto-rename-on-first-message convention that already runs
// in ChatView's stream lifecycle).
const handleAddTaskPick = async (taskType: 'standard' | 'memory') => {
  const workspaceId = pickerWorkspaceId.value
  const itemId = pickerItemId.value
  // Clear the picker targets FIRST so a re-entry from the auto-create
  // path (which itself triggers router.replace) doesn't leak the
  // workspaceId/itemId into a future accidental re-open.
  pickerWorkspaceId.value = null
  pickerItemId.value = null

  if (taskType === 'standard') {
    // No dialog — auto-create + navigate via the shared helper (also
    // used by the agent-mode direct path in `handleAddTask`).
    if (!workspaceId || !itemId) return
    await createAndOpenStandardChat(workspaceId, itemId)
    return
  }

  // 'memory' (2026-06-20): open AddMemoryDialog in `mode='task'`
  // (it won't call the API itself; the create callback here
  // calls addTask with taskType='memory' which triggers the
  // backend's file-write + task-insert in one POST).
  addMemoryTaskWorkspaceId.value = workspaceId
  addMemoryTaskItemId.value = itemId
  showAddMemoryTaskDialog.value = true
}

const handleCloseAddTaskPicker = () => {
  showAddTaskPicker.value = false
  pickerWorkspaceId.value = null
  pickerItemId.value = null
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

const handleSelectTask = async (taskId: string) => {
  const currentSorts = route.query?.sorts
  if (typeof currentSorts === 'string' && currentSorts.length > 0) {
    workspacesStore.savedSortsParam = currentSorts
  }
  // FIX (task-url-overwrite, task_1785959660154, 2026-08-06):
  // Set the navigation flag BEFORE mutating the store. The
  // AppLayout URL sync watcher reads `workspacesStore.isNavigatingToTask`
  // and returns early when it's true — closing the race window
  // between setActiveTask's synchronous store mutation (which
  // fires the watcher) and Vue Router's asynchronous URL update
  // (which would otherwise leave the watcher seeing
  // `route.query.view === 'workspace'` and clobbering the in-flight
  // task URL with `router.replace({ view: 'workspace', ... })`).
  workspacesStore.isNavigatingToTask = true
  try {
    workspacesStore.setActiveTask(taskId)
    if (chatsListRef.value) {
      chatsListRef.value.resetActiveChat()
    }
  // NEW (better-url-browser, 2026-08-06): APPEND the URL instead
  // of REPLACE. The user reported "when click task in kanban, no
  // need replace url, but append the url browser" — clicking a
  // kanban task used to write a lean `?view=task&task=X&itemId=Y`
  // URL via router.replace, which (a) dropped the workspace +
  // per-column sort context the user was on, and (b) clobbered the
  // browser history so the back button skipped the kanban URL.
  //
  // Now we PUSH the new URL with the current route.query spread
  // underneath, then override `view`, `task`, and `itemId`. This:
  //   1. Preserves the breadcrumb (workspaceId / pageId / sorts)
  //      so a refresh of the task URL still carries the kanban
  //      context, matching the sidebar's mental model of "I'm on
  //      kanban X, opened task Y from column Z".
  //   2. Keeps the previous URL in the browser history so the back
  //      button returns naturally to the kanban URL (no need to
  //      manually pre-fill `savedSortsParam` for back-restore).
  //   3. Still works for deep links — if the user landed on the
  //      task URL via bookmark with NO workspace context, the
  //      spread copies nothing and the resulting URL stays lean.
  //
  // The `savedSortsParam` snapshot above remains the close-restore
  // fallback for cases where AppLayout's handleCloseTaskView runs
  // WITHOUT the URL having preserved context (e.g. an older URL
  // pattern that lands on task without kanban context).
  //
  // NEW (add-workspace-id-params, 2026-08-06): always include
  // workspaceId + itemId + pageId from the active store state, with
  // the URL breadcrumb as a fallback. Pre-fix the URL could end up
  // as `?view=task&task=X&itemId=Y` (no workspaceId) when the user
  // landed on a kanban URL that didn't include workspaceId — sharing
  // / refreshing that URL lost the workspace context. The helper
  // reads from the store FIRST (authoritative source) and falls back
  // to the current URL only when no active store state exists.
  //
  // `await router.push(...)` is critical: Vue Router updates the
  // route ref asynchronously (during the navigation guard / scroll
  // sequence). Awaiting ensures the URL is `view=task&task=X` by
  // the time any subsequent watcher fires. Even with the flag
  // guard, awaiting is the cleanest close — the flag's `finally`
  // clears only after the navigation is committed.
  const query = buildTaskUrlQuery({
    taskId,
    activeWorkspaceId: workspacesStore.activeWorkspace?.id ?? null,
    activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
    activeDesignPageId: workspacesStore.activeDesignPageId,
    activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
    currentQuery: route.query,
  })
  // handleSelectTask uses router.push (NOT replace) so the previous
  // kanban / design URL stays in the browser history and the back
  // button returns naturally (better-url-browser, 2026-08-06). The
  // `itemId` derived from `activeWorkspaceItemId` is included via the
  // helper's store-derived value (NOT the `parentItemId` we computed
  // above — they should be equal but the store is authoritative).
  await router.push({ path: '/app', query })
  } finally {
    workspacesStore.isNavigatingToTask = false
  }
}

// pickBreadcrumbFromQuery moved to `helpers/buildTaskUrlQuery.ts`
// (add-workspace-id-params plan, 2026-08-06) so it can be shared
// across Sidebar, AppLayout, and any future task-URL builders.

const handleLoadMoreTasks = (workspaceId: string, itemId: string) => {
  // Click-to-load pagination: invoked by the "Load more" button in
  // WorkspaceItem.vue. The store action is the only place that calls
  // api.getTasks with a cursor — no auto-load / scroll listener /
  // intersection observer. Mirrors the _loadMoreChats pattern in
  // ChatsList.vue:121-183.
  //
  // Per-column pagination (kanban-per-column-pagination plan,
  // 2026-08-06): the sidebar's "Load more" picks the FIRST column
  // with hasMore=true and fetches that column's next page. This
  // matches the user's mental model: "I clicked Load more on the
  // sidebar; give me more tasks for this board" (the first column
  // that still has more is the cheapest visible next-page).
  const workspace = workspacesStore.workspaces.find((w) => w.id === workspaceId)
  const item = workspace?.items.find((i) => i.id === itemId)
  if (!item) return
  const colPagination = item.columnPagination ?? {}
  for (const [columnId, state] of Object.entries(colPagination)) {
    if (state.hasMore && !state.isLoading) {
      void workspacesStore.loadMoreTasksForColumn(
        workspaceId,
        itemId,
        columnId,
      )
      return
    }
  }
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

// NEW (design-pages-in-workspace-tree plan, 2026-08-06): the design
// page events from the sidebar tree. WorkspaceItem already set
// activeDesignPageId + activeWorkspaceItemId on `select-design-page`
// (so the store is in the right state before this handler runs);
// we just need to navigate AppLayout to the design view. The
// design-view mount reads the activeDesignPageId from the store
// and renders the page.
//
// FIX (2026-08-06, post-#169 fix): the previous implementation
// was a no-op — it relied on AppLayout's URL-sync watcher (line
// 237 in AppLayout.vue) to mirror the store change into the URL.
// But that watcher has a guard `currentView !== 'workspace' &&
// currentView !== undefined → return` — meaning it REFUSES to
// overwrite the URL when the user is on a different view (e.g.
// `?view=task&task=X`). So when the user was on a chat task
// view (their last navigation), clicked a page in the sidebar,
// the store updated but the URL stayed at `?view=task&task=X`
// and the canvas didn't switch to DesignView. The user reported:
// *"when i click its not go to design mode"*.
//
// The fix: explicitly emit `navigate` to switch the URL to
// `?view=workspace&workspaceId=X&itemId=Y&pageId=Z`. AppLayout's
// `handleNavigate('workspace', ...)` does `router.replace(...)`
// which switches the URL view off task/chat back to workspace.
// Once on workspace view, the watcher syncs pageId too.
const handleSelectDesignPage = (
  workspaceId: string,
  itemId: string,
  pageId: string,
) => {
  // WorkspaceItem already activated the item + set the page.
  // We intentionally don't re-call setActiveWorkspaceItem here
  // to avoid duplicate AppLayout re-renders (WorkspaceItem's
  // handler guards that call on activeWorkspaceItemId !== item.id).
  //
  // Emit `navigate` with view='workspace' + workspaceId + itemId +
  // pageId to switch the URL off the current view (e.g. ?view=task)
  // and into the design view, with the page id preserved in the
  // URL for reload resilience. AppLayout.handleNavigate now reads
  // the 6th positional arg (pageId) and writes it to the query.
  emit('navigate', 'workspace', undefined, undefined, workspaceId, itemId, pageId)
}

// NEW (2026-08-06, task 1785912441877): design-page delete now
// requires confirmation, matching the existing pattern for
// workspaces / items / tasks (`handleDeleteWorkspace` etc.).
//
// Clicking × on a design page in the sidebar tree is too easy to
// do by accident — every other delete (workspace / item / task)
// already shows the <ConfirmDialog>. The store's
// `deleteDesignPage` action still handles cache + active-page
// fallback + error notification; we just gate it behind the same
// confirm dialog so a stray click can't nuke a page.
const handleDeleteDesignPage = (
  workspaceId: string,
  itemId: string,
  pageId: string,
) => {
  openDeleteConfirm({
    title: 'Delete Page',
    message: 'Delete this design page? This cannot be undone.',
    onConfirm: async () => {
      try {
        await workspacesStore.deleteDesignPage(workspaceId, itemId, pageId)
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        useNotificationStore().notifyError('Failed to delete page', message)
      }
    },
  })
}

// "+ Add Page" button. The store's `addDesignPage` action returns
// the new page object; we set it as active so the canvas shows the
// empty new page (matching DesignView's pre-fix handleAddPage
// behaviour). Also expands the design item if it isn't already
// (otherwise the new page row appears collapsed inside the
// sidebar, which is confusing for the user).
const handleAddDesignPage = async (
  workspaceId: string,
  itemId: string,
) => {
  // Expand first so the user sees the new row appear.
  if (workspacesStore.expandedItemIds[itemId] !== true) {
    workspacesStore.toggleExpandedItem(itemId)
  }
  // Pick the next untitled name (mirrors DesignView's pre-fix
  // `computeNextUntitledName` — same high-water-mark + 1 rule).
  const pages = workspacesStore.designPagesByItemId[itemId] ?? []
  const name = computeNextUntitledName(pages)
  try {
    const created = await workspacesStore.addDesignPage(workspaceId, itemId, name)
    if (created) {
      // The store's `addDesignPage` action already set the new page
      // as active (matches pre-fix DesignView handleAddPage). We
      // only need to activate the design item so AppLayout routes
      // to DesignView.
      if (workspacesStore.activeWorkspaceItemId !== itemId) {
        workspacesStore.setActiveWorkspaceItem(itemId)
      }
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    useNotificationStore().notifyError('Failed to add page', message)
  }
}

// Compute the next untitled name (mirrors DesignView's pre-fix
// `computeNextUntitledName`). Copied here to keep the sidebar logic
// independent of DesignView — the function is 20 lines and
// Sidebar/DesignView don't share a common parent module.
const UNTITLED_BASE = 'Untitled'
const UNTITLED_PATTERN = /^Untitled (\d+)$/
function computeNextUntitledName(
  existingPages: ReadonlyArray<{ name: string }>,
): string {
  let hasUnnumbered = false
  let maxNumbered = 0
  for (const p of existingPages) {
    if (p.name === UNTITLED_BASE) {
      hasUnnumbered = true
      continue
    }
    const match = UNTITLED_PATTERN.exec(p.name)
    if (match && match[1]) {
      const n = Number.parseInt(match[1], 10)
      if (Number.isFinite(n) && n > 0 && n > maxNumbered) {
        maxNumbered = n
      }
    }
  }
  if (!hasUnnumbered && maxNumbered === 0) return UNTITLED_BASE
  return `${UNTITLED_BASE} ${maxNumbered + 1}`
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
// owns the user-visible side effects (route to chat).
//
// NOTE: per-task routine handlers (handleRunRoutine,
// handleEditRoutine + EditRoutineDialog plumbing) were deleted with
// per-task routines (Migration 084, plan
// 2026-09-10-workspace-items-routines). Workspace-level routines
// fire via RoutineView → workspacesStore.runRoutineItem.

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
// pin-task. AppLayout holds the
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
      borderRight: '1px solid var(--color-border)',
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
         a thin monogram "A" character; expanded shows "AnakMagang" word
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
        <span class="text-sm font-semibold tracking-tight" style="color: var(--semantic-text);">AnakMagang</span>
      </div>
      <span
        v-else
        class="text-sm font-semibold tracking-tight"
        style="color: var(--semantic-text);"
        title="AnakMagang"
        aria-label="AnakMagang"
        data-testid="sidebar-header-collapsed"
      >A</span>
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
          @open-item-in-background="handleOpenItemInBackground"
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
          @reorder-workspaces="handleReorderWorkspaces"
          @reorder-workspace-items="handleReorderWorkspaceItems"
          @pin-task="handlePinTask"
          @reorder-pinned-tasks="handleReorderPinnedTasks"
          @select-design-page="handleSelectDesignPage"
          @delete-design-page="handleDeleteDesignPage"
          @add-design-page="handleAddDesignPage"
          @rename-design-page="handleRenameDesignPage"
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
    <!-- NEW (rename-design-pages, 2026-08-06): ⋮ menu "Rename"
         opens this modal; confirm fires workspaceStore.renameDesignPage
         which PATCHes the page + optimistically updates the local cache. -->
    <RenameDesignPageModal :show="showRenameDesignPageModal" :current-name="renameTargetDesignPageName" @close="handleCloseDesignPageRenameModal" @rename="handleConfirmDesignPageRename" />
    <AddItemDialog :show="showAddItemDialog" @close="handleCloseAddItemDialog" @create="handleCreateItem" />
    <AddKanbanDialog :show="showAddKanbanDialog" @close="handleCloseAddKanbanDialog" @create="handleCreateKanban" />
    <!-- NEW (design-mode feature): modal for creating a design-mode
         workspace item. Wired to the 'design' itemType in
         handleAddItem (above). See AddDesignDialog.vue for the
         internal flow. Plan:
         docs/superpowers/plans/2026-06-13-design-mode.md. -->
    <AddDesignDialog :show="showAddDesignDialog" @close="handleCloseAddDesignDialog" @create="handleCreateDesign" />
    <AddAgentDialog :show="showAddAgentDialog" @close="handleCloseAddAgentDialog" @create="handleCreateAgent" />
    <!-- Workspace routines (Migration 084): modal for creating a
         routine-mode workspace item. Wired to the 'routine' itemType
         in handleAddItem (above). -->
    <AddRoutineItemDialog :show="showAddRoutineItemDialog" @close="handleCloseAddRoutineItemDialog" @create="handleCreateRoutineItem" />
    <AddMemoryDialog
      :show="showAddMemoryDialog"
      :cwd="addMemoryTargetWorkspaceId ? resolveCwdForMemory(addMemoryTargetWorkspaceId) : ''"
      @close="handleCloseAddMemoryDialog"
      @create="handleCreateMemory"
    />
    <AddTaskPickerDialog :show="showAddTaskPicker" @close="handleCloseAddTaskPicker" @pick="handleAddTaskPick" />
    <!-- AddTaskDialog was removed in 2026-07-26 — the "Standard Chat"
         path now auto-creates the task + navigates straight to its
         ChatView, no name/description prompt. See handleAddTaskPick.
         (AddRoutineDialog was removed in Migration 084 — routines are
         workspace items now, see AddRoutineItemDialog above.) -->
    <AddMemoryDialog
      v-if="addMemoryTaskItemId"
      :show="showAddMemoryTaskDialog"
      :cwd="resolveCwdForItem(addMemoryTaskItemId)"
      mode="task"
      @close="handleCloseAddMemoryTaskDialog"
      @create="handleCreateMemoryTask"
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

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch, nextTick, provide } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import Sidebar from './shell/Sidebar.vue'
// DISABLED: import RightSidebar from './shell/RightSidebar.vue'   // 2026-06-29 — task disable-rightsidebar-vue
import GitFileViewer from './git/GitFileViewer.vue'
import SkillDetail from './shell/SkillDetail.vue'
import ChatView from './views/ChatView.vue'
import Chats from './views/Chats.vue'
import SettingsView from './views/SettingsView.vue'
import CodeEditor from './views/CodeEditor.vue'
import NotificationContainer from './shell/NotificationContainer.vue'
import SseStatusBadge from './shell/SseStatusBadge.vue'
import KanbanView from './kanban/KanbanView.vue'
import KanbanChatDialog from './kanban/KanbanChatDialog.vue'
import DesignChatDialog from './design/DesignChatDialog.vue'
import KanbanColumnEditor from './kanban/KanbanColumnEditor.vue'
import KanbanSettingsDialog from './kanban/KanbanSettingsDialog.vue'
import CopyKanbanSpecDialog from './dialogs/CopyKanbanSpecDialog.vue'
import DesignView from './design/DesignView.vue'
import WorkspaceItemMemoriesView from './views/WorkspaceItemMemoriesView.vue'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore, type Task as TaskType } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import { useKanbanSseStore } from '../stores/kanbanSse'
import { useDesignSseStore } from '../stores/designSse'
import * as api from '../api'
import {
  OPEN_IN_CODE_EDITOR_KEY,
  type OpenInCodeEditorFn,
  type OpenInCodeEditorOptions,
} from '../composables/useCodeEditor'
import { useDesignHandlers } from '../composables/useDesignHandlers'
import { buildTaskUrlQuery } from '../helpers/buildTaskUrlQuery'

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
  // Session events (renames / deletes) now flow through the sseBus,
  // which is opened once by App.vue. The workspaces store installs
  // its bus.on('session', ...) handler in its own `init()` (called
  // transitively by initializeFromSystemFolder above), so no
  // explicit subscribe call is needed here. See Chunk 6 of
  // unify-frontend-sse.
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
watch(
  activeWorkspaceId,
  async (newId) => {
    if (!newId) return
    if (!didInitSse) {
      didInitSse = true
      await kanbanSseStore.initKanbanSse(newId)
    } else {
      await kanbanSseStore.setActiveWorkspaceId(newId)
    }
  },
  { immediate: true },
)

// ─── URL → activeWorkspaceItemId / activeDesignPageId restoration ─────
//
// When the user reloads `/app?view=workspace&workspaceId=X&itemId=Y[&pageId=Z]`,
// the in-memory `activeWorkspaceItemId` (and `activeDesignPageId`) is null.
// We need to set them from the URL params, but only AFTER the workspaces
// array has loaded (so we can validate the (workspaceId, itemId) pair
// actually exists). The pageId restoration happens at the DesignView
// layer (it loads pages and reads `activeDesignPageId` from the store
// before falling back to the first page) — we just stash the URL value
// into the store here so DesignView can pick it up.
//
// Setup reads the URL synchronously (it runs before any async API
// calls) and stashes the params into `pendingUrlRestore`. The
// `workspaces` watcher fires the moment initializeFromSystemFolder
// populates the array (or in tests, the moment the test sets
// ws.workspaces = [...] before mount), validates the pair, calls
// setActiveWorkspaceItem (+ setActiveDesignPage if pageId is set), and
// clears the pending slot. If the pair no longer exists (deleted), we
// just leave the kanban blank.
const pendingUrlRestore = ref<{
  workspaceId: string
  itemId: string
  pageId: string
} | null>(
  (() => {
    const view = route.query.view as string | undefined
    const wsId = route.query.workspaceId as string | undefined
    const itemId = route.query.itemId as string | undefined
    const pageId = route.query.pageId as string | undefined
    if (view === 'workspace' && wsId && itemId) {
      return { workspaceId: wsId, itemId, pageId: pageId ?? '' }
    }
    return null
  })(),
)
watch(
  () => workspacesStore.workspaces,
  (wsList) => {
    const pending = pendingUrlRestore.value
    if (!pending) return
    if (!wsList || wsList.length === 0) return
    const wsExists = wsList.some((ws) => ws.id === pending.workspaceId)
    const itemExists = wsList.some((ws) => ws.items.some((item) => item.id === pending.itemId))
    if (wsExists && itemExists) {
      workspacesStore.setActiveWorkspaceItem(pending.itemId)
      // Restore the active design page (if any) so DesignView picks
      // it up after its pages-load watcher fires. Empty pageId means
      // "use the first page" — the default behavior.
      if (pending.pageId) {
        workspacesStore.setActiveDesignPage(pending.pageId)
      }
      pendingUrlRestore.value = null
    } else {
      // Stale URL — clear it so we don't try again on every workspace
      // update. User will see the empty kanban-state placeholder and
      // can pick a workspace item manually.
      pendingUrlRestore.value = null
    }
  },
  { immediate: true },
)

// IMPORTANT (2026-07-28 per-page chat scoping):
// When the user switches design pages (activeDesignPageId changes
// in the store, mirrored from DesignView's `watch(activePageId)`),
// we DO NOT swap the active chat task. The chat is bound to the
// page that opened it (via `handleDesignOpenChat`'s per-page
// lookup); switching tabs leaves that conversation alone. Closing
// the chat and reopening on a new page binds to the new page's
// chat predictably via `handleDesignOpenChat`. Any future "smart
// chat that follows the page" behavior must be opt-in, NOT
// implicit, to avoid disorienting users mid-conversation.
// Plan: docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md

// ─── activeWorkspaceItem / activeDesignPage → URL mirror (reverse sync) ──
//
// The forward direction (sidebar click → URL) is wired through
// Sidebar.handleSelectItem → emit('navigate', 'workspace', …, wsId, itemId)
// → AppLayout.handleNavigate → router.replace. The reverse direction
// (activeWorkspaceItemId / activeDesignPageId changes from ANY source →
// URL) is needed for resilience: if the URL restore watcher above sets
// activeWorkspaceItemId, the URL is already correct (it was the
// source), but if any future code path sets activeWorkspaceItemId
// programmatically (e.g., keyboard shortcut, deep link, restored
// from localStorage), the URL would NOT update and a refresh
// would lose the context. This watcher fills that gap. Also covers
// the active design page (DesignView emits selectPage → no URL
// update; DesignView's watch(activePageId) writes to the store,
// this watcher mirrors the store back to the URL).
//
// We guard against two footguns:
//   1. The watcher must NOT overwrite the URL while the user is
//      on a route like view=task / view=chat / view=settings /
//      view=gitfile / view=skill / view=code-editor — those views
//      have their own URL contract and should be preserved.
//   2. The watcher must NOT call router.replace when the URL
//      already matches the active state (would push redundant
//      history entries).
watch(
  () => [workspacesStore.activeWorkspaceItemId, workspacesStore.activeDesignPageId] as const,
  ([itemId, pageId]) => {
    const wsId = workspacesStore.activeWorkspace?.id ?? ''
    const currentView = route.query.view as string | undefined
    // FIX (task-url-overwrite, task_1785959660154, 2026-08-06):
    // The URL sync watcher must NOT fire while Sidebar is in the
    // middle of a task navigation. The race that broke this:
    // Sidebar.handleSelectTask calls
    // workspacesStore.setActiveTask(taskId) (which synchronously
    // mutates activeWorkspaceItemId to the task's parent item via
    // the parent-discovery loop in workspaces.ts:3031-3107) and then
    // calls router.push({ view: 'task', task, workspaceId, itemId }).
    // Vue Router resolves the push asynchronously (the route ref
    // updates after the navigation guard / scroll / etc.). This
    // watcher fires on the next microtask after the store mutation —
    // BEFORE Vue Router has applied the URL change. At that moment
    // route.query.view is still the OLD view (typically
    // 'workspace'), the existing guard
    // `if (currentView !== 'workspace' && currentView !== undefined) return`
    // does NOT return early, and the watcher clobbers the URL with
    // `router.replace({ view: 'workspace', workspaceId, itemId, ... })`.
    // The pending `router.push({ view: 'task', ... })` is then
    // applied AFTER the replace, but Vue Router's `replace`
    // semantics overwrite the push's history entry — the URL ends
    // up at view=workspace and the task never shows up.
    //
    // User report (task_1785959660154): "select task not show up
    // ... buildTaskUrlQuery view is task, but the url browser
    // still using view workspace".
    //
    // The fix: a `isNavigatingToTask` ref is set true at the start
    // of Sidebar.handleSelectTask and cleared after the URL update
    // completes. The watcher returns early when the flag is set,
    // so the race window is closed. The flag is stored in the
    // workspaces store (the natural home for cross-component view
    // state).
    if (workspacesStore.isNavigatingToTask) return
    // Only sync when we're on the workspace view — all other views
    // (chat, task, settings, gitfile, skill, code-editor) have their
    // own URL contract and should be preserved.
    if (currentView !== 'workspace' && currentView !== undefined) return
    const urlWsId = route.query.workspaceId as string | undefined
    const urlItemId = route.query.itemId as string | undefined
    const urlPageId = route.query.pageId as string | undefined
    if (urlWsId === wsId && urlItemId === itemId && urlPageId === pageId) return
    const query: Record<string, string> = { view: 'workspace' }
    if (wsId && itemId) {
      query.workspaceId = wsId
      query.itemId = itemId
      // pageId is design-item-scoped — only include it when the active
      // item is a design. Empty pageId means "default to first page"
      // and is omitted from the URL to keep the URL clean. FIX
      // (chatview-bug, task_1785726648589): pre-fix, the watcher wrote
      // `pageId` to the URL based purely on `activeDesignPageId` being
      // truthy — without checking the active item's type. When the
      // user switched from a design to a kanban (or folder), the
      // store's `activeDesignPageId` stayed stale (carried over from
      // the design), and the URL ended up as
      // `?view=workspace&itemId=KANBAN_ID&pageId=DESIGN_PAGE_ID`. On
      // reload, the URL restoration would try to honor the stale page
      // for the kanban (which doesn't have pages). The fix: look up
      // the active item and only include pageId when it's a design.
      if (pageId) {
        const activeItem = workspacesStore.workspaces
          .flatMap((ws) => ws.items)
          .find((it) => it.id === itemId)
        if (activeItem?.item_type === 'design') {
          query.pageId = pageId
        }
      }
      // FIX (kanban-sort-independence, task_1785730557641,
      // 2026-08-06): preserve the per-column `sorts` query param so
      // the URL survives navigation. Without this, this watcher
      // (which fires on every workspaceItemId change) would clobber
      // the URL with `{view, workspaceId, itemId}` and drop the
      // `sorts=col_X:...` KanbanView wrote — making the per-column
      // sort non-persistent across navigation + refresh.
      const urlSorts = route.query.sorts as string | undefined
      if (urlSorts) {
        query.sorts = urlSorts
      }
    }
    router.replace({ path: '/app', query })
  },
)

// ─── Design SSE — mirror the kanban pattern ─────────────────────────────
//
// Bus-backed design-event subscription (Chunk 6 of
// design-mode-redesign plan). The store opens its bus listener on the
// FIRST truthy activeWorkspaceId and just updates the filter on
// subsequent changes — same ONE-connection-per-app-lifetime contract
// as the kanban SSE store. The bus itself is installed once by
// App.vue; this watcher only schedules the subscription.
//
// `didInitDesignSse` keeps the SSE idempotent across remounts (e.g.
// HMR, route changes that briefly tear down AppLayout).
const designSseStore = useDesignSseStore()
let didInitDesignSse = false

// NEW (Chunk 1, Task 1.3 of design-element-drag-and-drop plan).
// Extracted handlers so they're directly unit-testable. Reads the
// active page id from workspacesStore (mirrored by DesignView in
// Task 1.2) and routes patches to the geometry endpoint vs the
// full-update endpoint based on which keys are present.
const designHandlers = useDesignHandlers()
watch(
  activeWorkspaceId,
  async (newId) => {
    if (!newId) return
    if (!didInitDesignSse) {
      didInitDesignSse = true
      await designSseStore.initDesignSse(newId)
    } else {
      await designSseStore.setActiveWorkspaceId(newId)
    }
  },
  { immediate: true },
)

onUnmounted(() => {
  kanbanSseStore.closeKanbanSse()
  designSseStore.closeDesignSse()
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

const handleNavigate = (
  view: string,
  chatName?: string,
  taskId?: string,
  workspaceId?: string,
  itemId?: string,
  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the
  // 6th positional arg lets the caller pin a specific design page
  // when navigating to `view: 'workspace'`. Empty / undefined
  // means "no page pinned" (DesignView falls back to the first
  // page in the cache). Pre-fix, the workspace branch only wrote
  // workspaceId + itemId to the URL — a click on a design page
  // navigated correctly into DesignView (the store had the page
  // id) but the URL lost it on the next reload, so a refresh
  // restored the wrong page. Now the URL is the source of truth
  // for reload, matching the existing `activeDesignPageId` mirror
  // on line 188.
  pageId?: string,
  // NEW (kanban default-URL, 2026-08-06): when the caller navigates
  // to a kanban workspace item, the Sidebar commits a default
  // `?sorts=col_X:updated_at:desc,...` string here. We mirror it
  // into the URL so a refresh preserves the user's implicit sort
  // choice. Empty / undefined means "no sort param" (folder /
  // design / chat paths). KanbanView's mount-time URL restore
  // reads it back and applies each entry's sort to its column.
  sortsParam?: string,
) => {
  console.log('[handleNavigate]', view)
  if (view.startsWith('chat-')) {
    const chatSessionId = view.replace(/^chat-/, '')
    // Clear any workspace-item active state — navigating to a chat wins.
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.setActiveChat(chatSessionId, chatName)
    // Fetch cwd for folder explorer and git
    fetchChatSessionCwd(chatSessionId)
    router.push({ path: '/app', query: { view: 'chat', session: chatSessionId } })
  } else if (view === 'chat') {
    // Clear any workspace-item active state — the URL is asserting
    // "no chat selected, no workspace item selected".
    workspacesStore.setActiveWorkspaceItem(null)
    navigationStore.clearActiveChat()
    chatSessionCwd.value = ''
    router.push({ path: '/app', query: { view: 'chat' } })
  } else if (view === 'workspace') {
    navigationStore.clearAll()
    chatSessionCwd.value = ''
    // When the caller passes (workspaceId, itemId), mirror them into the
    // URL so the kanban/folder/design item survives a page reload.
    // Without this, `?view=workspace` alone loses the active item on
    // refresh because `activeWorkspaceItemId` is in-memory only.
    const query: Record<string, string> = { view: 'workspace' }
    if (workspaceId && itemId) {
      query.workspaceId = workspaceId
      query.itemId = itemId
      // NEW (design-pages-in-workspace-tree plan, 2026-08-06):
      // also mirror pageId when present so a reload of the
      // design view restores the same page (URL is source of
      // truth, matching the activeDesignPageId mirror on line 188).
      if (pageId) query.pageId = pageId
      // NEW (kanban default-URL, 2026-08-06): also mirror sortsParam
      // when present so a kanban reload restores the per-column
      // sort defaults the user committed to on click.
      if (sortsParam) query.sorts = sortsParam
    }
    // router.replace (not push) so the user can hit back to leave
    // the workspace context without stacking the same URL twice in
    // the history. All other branches in this handler also use
    // replace; the workspace branch was the lone hold-out.
    router.replace({ path: '/app', query })
  } else if (view === 'task') {
    navigationStore.setActiveTask(taskId || null)
    chatSessionCwd.value = ''
    // NEW (add-workspace-id-params, 2026-08-06): include workspaceId
    // + itemId + pageId from the active store state in the URL. Pre-fix
    // this branch wrote only `?view=task&task=X`, dropping the kanban
    // / design breadcrumb. The caller passes `workspaceId` / `itemId`
    // / `pageId` as positional args; we fall back to the active store
    // when those are absent (e.g. legacy call sites).
    router.push({
      path: '/app',
      query: buildTaskUrlQuery({
        taskId: taskId || '',
        activeWorkspaceId: workspaceId ?? workspacesStore.activeWorkspace?.id ?? null,
        activeWorkspaceItemId: itemId ?? workspacesStore.activeWorkspaceItemId,
        activeDesignPageId: pageId ?? workspacesStore.activeDesignPageId,
        activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
      }),
    })
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
  // Navigate back to previous view based on state. If the user
  // opened the file viewer while on a workspace item (folder /
  // kanban / design), preserve the active item IDs in the URL so
  // a page reload restores the design/kanban/folder — otherwise the
  // URL was being stripped to ?view=task or ?view=chat, losing the
  // workspace context. For design items, also preserve pageId so
  // the active design page survives a reload.
  if (workspacesStore.activeWorkspaceItemId) {
    const wsId = activeWorkspaceId.value
    const itemId = workspacesStore.activeWorkspaceItemId
    const pageId = workspacesStore.activeDesignPageId
    const query: Record<string, string> = {
      view: 'workspace',
      workspaceId: wsId,
      itemId,
    }
    if (pageId) query.pageId = pageId
    router.replace({ path: '/app', query })
  } else if (activeTask.value) {
    // NEW (add-workspace-id-params, 2026-08-06): include workspaceId +
    // itemId + pageId when the task is attached to a workspace item.
    // Pre-fix this branch wrote only `?view=task&task=X`, dropping
    // the kanban / design breadcrumb — the user reported this
    // (task_1785774094183).
    router.replace({
      path: '/app',
      query: buildTaskUrlQuery({
        taskId: activeTask.value.id,
        activeWorkspaceId: activeWorkspaceId.value,
        activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
        activeDesignPageId: workspacesStore.activeDesignPageId,
        activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
        currentQuery: route.query,
      }),
    })
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
  // Navigate back to previous view based on state. Preserve the
  // workspace item (folder / kanban / design) IDs when the user
  // opened the skill view while on a workspace item — see
  // closeGitViewer for the same pattern. For design items, also
  // preserve pageId so the active design page survives a reload.
  if (workspacesStore.activeWorkspaceItemId) {
    const wsId = activeWorkspaceId.value
    const itemId = workspacesStore.activeWorkspaceItemId
    const pageId = workspacesStore.activeDesignPageId
    const query: Record<string, string> = {
      view: 'workspace',
      workspaceId: wsId,
      itemId,
    }
    if (pageId) query.pageId = pageId
    router.replace({ path: '/app', query })
  } else if (activeTask.value) {
    // NEW (add-workspace-id-params, 2026-08-06): include workspaceId +
    // itemId + pageId when the task is attached to a workspace item.
    // Pre-fix this branch wrote only `?view=task&task=X`, dropping
    // the kanban / design breadcrumb — the user reported this
    // (task_1785774094183).
    router.replace({
      path: '/app',
      query: buildTaskUrlQuery({
        taskId: activeTask.value.id,
        activeWorkspaceId: activeWorkspaceId.value,
        activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
        activeDesignPageId: workspacesStore.activeDesignPageId,
        activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
        currentQuery: route.query,
      }),
    })
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
// 1-based line number to scroll to when the editor mounts. Set by
// openInCodeEditor when the caller (e.g. diff view) wants the editor to
// land on a specific line; cleared on close and on new file selection.
const codeEditorRequestedLine = ref<number | null>(null)

const openInCodeEditor: OpenInCodeEditorFn = async (opts: OpenInCodeEditorOptions) => {
  console.log('[openInCodeEditor] filePath:', opts.filePath, 'cwd:', opts.cwd, 'line:', opts.line)
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
  codeEditorRequestedLine.value = typeof opts.line === 'number' && opts.line > 0 ? opts.line : null
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
    const query: Record<string, string> = {
      view: 'code-editor',
      file: encodedPath,
      cwd: opts.cwd,
    }
    if (codeEditorRequestedLine.value !== null) {
      query.line = String(codeEditorRequestedLine.value)
    }
    router.replace({
      path: '/app',
      query,
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
  codeEditorRequestedLine.value = null
  // Navigate back to previous view. Preserve the workspace item
  // (folder / kanban / design) IDs when the user opened the code
  // editor while on a workspace item — see closeGitViewer for the
  // same pattern. For design items, also preserve pageId so the
  // active design page survives a reload.
  if (workspacesStore.activeWorkspaceItemId) {
    const wsId = activeWorkspaceId.value
    const itemId = workspacesStore.activeWorkspaceItemId
    const pageId = workspacesStore.activeDesignPageId
    const query: Record<string, string> = {
      view: 'workspace',
      workspaceId: wsId,
      itemId,
    }
    if (pageId) query.pageId = pageId
    router.replace({ path: '/app', query })
  } else if (activeTask.value) {
    // NEW (add-workspace-id-params, 2026-08-06): include workspaceId +
    // itemId + pageId when the task is attached to a workspace item.
    // Pre-fix this branch wrote only `?view=task&task=X`, dropping
    // the kanban / design breadcrumb — the user reported this
    // (task_1785774094183).
    router.replace({
      path: '/app',
      query: buildTaskUrlQuery({
        taskId: activeTask.value.id,
        activeWorkspaceId: activeWorkspaceId.value,
        activeWorkspaceItemId: workspacesStore.activeWorkspaceItemId,
        activeDesignPageId: workspacesStore.activeDesignPageId,
        activeItemType: workspacesStore.activeWorkspaceItem?.item_type ?? null,
        currentQuery: route.query,
      }),
    })
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
const activeTaskWorkspaceItemId = computed(() => workspacesStore.activeTaskWorkspaceItemId)

// ─── KanbanChatDialog open state (plan: 2026-08-06-kanban-chat-as-dialog) ────
//
// The dialog uses `v-model:show` for two-way binding. We drive the
// `show` ref from `activeTask` so the dialog opens whenever the user
// navigates to a kanban task (via URL `?view=task&task=<id>` or by
// clicking a card) and closes when `activeTask` is cleared (via
// @close → handleCloseTaskView → setActiveTask(null)).
//
// The dialog also has its own `close` emit which we forward to
// handleCloseTaskView for URL cleanup.
const kanbanChatDialogOpen = ref(false)
watch(
  () => activeTask.value,
  (t) => {
    kanbanChatDialogOpen.value = !!t
  },
  { immediate: true },
)

// Captured from DesignView's `openChat` payload — the design page's
// own name (NOT the workspace item name). The dialog's header uses
// it as "Design Chat: <pageName>". Mirrors the FK-plan naming
// convention (2026-07-28-design-page-workspace-item-task-fk.md).
// Cleared when activeTask is cleared so a stale pageName from a prior
// chat doesn't leak into the next opened chat's header.
const activeDesignChatPageName = ref<string>('')

// ─── Design chat task FK handle (plan: 2026-08-06-design-chat-as-dialog,
//     bug fix from user report "the chat button keep not popup, chatview") ────
//
// Root cause: the design chat dialog's v-if gate was `activeTask && ...
// item_type === 'design'`. The `activeTask` computed walks
// `workspaces.value[].items[].tasks` looking for the task — but in
// PRODUCTION design items have empty `tasks` arrays after `init()`:
//   - `getWorkspacesItems` returns items WITHOUT tasks
//     (WorkspaceItemInfo struct in llm_history.zig:3208 has no `tasks` field)
//   - `init()` SKIPS `api.getTasks` for `item_type === 'design'`
//     (workspaces.ts:639 — only folders + other types fetch per-item tasks)
//   - The pre-fix 3-column [DesignView | resize-handle | ChatView]
//     layout used the same gate — it was BROKEN in production too.
//     The fix: capture the FK's `workspaceItemTaskId` directly via a
//     separate ref (this one), build a synthetic Task for the dialog,
//     and gate the dialog on THIS ref's truthiness — NOT on the
//     store's `activeTask` computed. `setActiveTask(...)` is still
//     called in `handleDesignOpenChat` (drives URL sync + handleCloseTaskView),
//     but the dialog no longer depends on its computed.
const activeDesignChatTaskId = ref<string>('')
// Watch the store's `activeTaskId` directly (NOT the computed
// `activeTask`) so the watcher fires even when activeTask stays
// null the whole time (the case for design items — see the bug
// comment above). handleCloseTaskView calls setActiveTask(null) →
// activeTaskId.value becomes '' → this watcher fires → clear
// activeDesignChatTaskId.value so the dialog unmounts.
watch(
  () => workspacesStore.activeTaskId,
  (taskId) => {
    if (!taskId) {
      activeDesignChatTaskId.value = ''
      activeDesignChatPageName.value = ''
    }
  },
)

// Synthetic Task for DesignChatDialog. ChatView's API expects a
// Task object with at minimum `id` (chat-id) and `name` (for the
// title fallback). Real design-chat tasks live in
// `workspace_item_tasks` rows accessible via the per-page FK in
// `design_pages.workspace_item_task_id` — but the store's
// `workspaces.value[].items[].tasks` array is empty for design
// items after init() (see the bug comment above), so the store's
// `activeTask` computed returns null and we can't pass it
// directly. Build a minimal Task from the captured FK info.
//
// `name` reads "Design Chat: <pageName>" when pageName is set,
// otherwise falls back to "Design Chat" (matches the dialog's
// header fallback). `taskType: 'standard'` matches the row created
// at page-create time per the FK plan.
const activeDesignChatTask = computed<TaskType | null>(() => {
  if (!activeDesignChatTaskId.value) return null
  return {
    id: activeDesignChatTaskId.value,
    name: activeDesignChatPageName.value
      ? `Design Chat: ${activeDesignChatPageName.value}`
      : 'Design Chat',
    description: '',
    taskType: 'standard',
  } as TaskType
})

// ─── DesignChatDialog open state (plan: 2026-08-06-design-chat-as-dialog) ────
//
// Same v-model:show pattern as KanbanChatDialog above. The design
// dialog opens whenever activeDesignChatTaskId is set AND the
// active item is a design — the gating happens in the template
// (v-if), not here. We drive `show` from `activeDesignChatTaskId`
// (NOT from `activeTask` like the kanban version) because the
// store's `activeTask` is null for design items (their tasks
// array is empty post-init; see the bug comment below).
//
// 2026-08-06: prior to this plan, the design chat was rendered as a
// RIGHT-side column of a 3-column DesignView | resize-handle |
// ChatView layout, with a floating collapse button to hide it. The
// 3-column took ~40% of the canvas even when "minimised". Switching
// to a centred modal dialog (mirrors KanbanChatDialog) reclaims the
// full canvas width — the dialog opens on top of the canvas with a
// dimmed backdrop. The collapse-state + design resize handle +
// DESIGN_WIDTH_STORAGE_KEY localStorage are removed below.
const designChatDialogOpen = ref(false)
watch(
  () => activeDesignChatTaskId.value,
  (id) => {
    designChatDialogOpen.value = !!id
  },
  { immediate: true },
)

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
  // CHATVIEW-BUG (fix): setActiveTask(null) does NOT clear the
  // navigation store's active chat anymore (the unconditional clear
  // broke the chat-nav paths in Sidebar.vue:316-322 and
  // ChatsList.vue:220-232). Since this is the ONLY path that needs
  // both the task AND the chat cleared (the user is closing the
  // chatview column of the 3-column kanban+chat layout and dropping
  // back to the workspace view), we now clear the chat explicitly
  // here. Without this explicit clear, the next page reload would
  // restore activeChatId from localStorage and pop the user back
  // into a chat they thought they had closed.
  workspacesStore.setActiveTask(null)
  navigationStore.clearActiveChat()
  // 2026-08-06 (design-chat-as-dialog bug fix): clearing
  // activeTaskId above triggers the watcher at the top of this
  // block which clears `activeDesignChatTaskId` and
  // `activeDesignChatPageName` — that's how the dialog unmounts.
  // (The watcher watches activeTaskId directly, NOT the computed
  // activeTask, because activeTask is null for design items the
  // whole time — see the comment at activeDesignChatTaskId.)
  // Preserve (workspaceId, itemId, pageId) when navigating back to
  // the workspace view — the active kanban/design item (and, for
  // design items, the active page) should survive a page reload.
  // Without this, the URL would be stripped to ?view=workspace and
  // a refresh would land on the empty state. The 3-column layout
  // already implies the user is on a workspace item (design or
  // kanban), so activeWorkspaceItemId is guaranteed truthy here —
  // but we guard anyway in case the chatview branch wins for an
  // unrelated chat session. pageId is design-item-scoped (empty
  // for kanban/folder items); only include it when set so the URL
  // stays clean for non-design items.
  const wsId = activeWorkspaceId.value
  const itemId = workspacesStore.activeWorkspaceItemId
  const pageId = workspacesStore.activeDesignPageId
  const query: Record<string, string> = { view: 'workspace' }
  if (wsId && itemId) {
    query.workspaceId = wsId
    query.itemId = itemId
    if (pageId) query.pageId = pageId
  }
  // Restore the kanban per-column sort state (kanban-sort-by plan,
  // 2026-08-06 — `?sorts=col_x:name:asc,...`). Sidebar's
  // handleSelectTask snapshots the user's sort choice before
  // navigating into the task view; we read it back here and put it
  // back into the URL. Without this, the round-trip drops the sort
  // (the user reported this 2026-08-06: "when click chatview, my
  // sort url is gone"). One round-trip's worth of state — the
  // store value is consumed once and cleared so a subsequent
  // close-without-a-task-open doesn't accidentally restore a stale
  // sort.
  if (workspacesStore.savedSortsParam) {
    query.sorts = workspacesStore.savedSortsParam
    workspacesStore.savedSortsParam = ''
  }
  router.replace({ path: '/app', query })
}

// ─── Design 3-column resize (separate from kanban) ─────────────────────
//
// Design canvases need significantly more horizontal room than
// kanbans — a typical Figma-style page is 1440px wide, and
// DesignView itself contains its own 320px Layers+Properties
// sidebar at full width. The chat panel was eating the canvas
// because the old KANBAN constants (default 40%, max 720px) were
// reused for design (commit d0a05eb0, 2026-07-14) — 40% of the
// main area minus 320px internal sidebar left the canvas viewport
// visibly cramped (the user reported this 2026-07-25).
//
// Design uses its own constants + a SEPARATE localStorage key
// (kanban-column-width is also used by kanban view, so reusing it
// would bleed prefs across modes). State and handlers mirror the
// kanban block above but reference DESIGN_*.
//
// Bounds rationale + the entire RESIZE state machine
// (DESIGN_MIN_WIDTH / DESIGN_MAX_WIDTH / DESIGN_DEFAULT_WIDTH /
// DESIGN_WIDTH_STORAGE_KEY / loadDesignColumnWidth /
// designColumnWidth / isDesignResizing / designResizeStartX /
// designResizeStartWidth / startDesignResize / handleDesignResize /
// stopDesignResize / designColumnStyle) + the COLLAPSE state
// machine (DESIGN_CHAT_COLLAPSED_KEY / loadDesignChatCollapsed /
// designChatCollapsed / toggleDesignChat) have been REMOVED as part
// of the design-chat-as-dialog plan (2026-08-06). The design chat
// no longer sits in a 3-column split — it's a centred modal dialog
// (DesignChatDialog) that opens on top of the full-width canvas.
// The resize handle and collapse toggle are gone with the 3-column
// branch.

// ─── Kanban main-content view (was inline in WorkspaceItem.vue;
// now mounted here so the board lives in the main content area, not
// in the sidebar). KanbanView consumes every event locally — the
// "+ Add" flow opens the KanbanTaskDetailDialog in create mode
// inside KanbanView (it owns the columns list, so resolving the
// target column is trivial), and the other events (move-task,
// add-column, etc.) are forwarded to the workspaces store here
// or to Sidebar for modal-opening handlers. AppLayout never wires
// any kanban events through sidebarRef — that path was removed in
// the kanban-add-task-via-detail-dialog feature. ──────────────

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

/**
 * Forward a kanban rename (from either the Settings dialog header
 * pencil or the KanbanView header pencil) to the store. Both
 * children emit `rename-item` with the trimmed new name; the
 * store action optimistic-updates + rolls back on error.
 *
 * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
 */
const handleKanbanRenameItem = (newName: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanItemName(ws.id, activeWorkspaceItem.value.id, newName)
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

// ─── CopyKanbanSpecDialog ────────────────────────────────────────────────
//
// Per-board "copy columns from another kanban" flow. Triggered by
// the "Copy spec…" footer button in KanbanSettingsDialog. The
// dialog itself is a modal with a source picker + Replace/Append
// radio; this handler delegates to workspacesStore.copyKanbanSpecFrom
// which calls POST /kanban/copy_spec_from and refreshes the target's
// local kanban_columns from the backend's response.
const showCopyKanbanSpecDialog = ref(false)

const handleOpenCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = true
}

const handleCloseCopyKanbanSpec = () => {
  showCopyKanbanSpecDialog.value = false
}

const handleCopyKanbanSpec = (sourceItemId: string, mode: 'replace' | 'append') => {
  if (!activeWorkspaceItem.value || !activeWorkspace.value) return
  void workspacesStore
    .copyKanbanSpecFrom(activeWorkspace.value.id, activeWorkspaceItem.value.id, sourceItemId, mode)
    .then(() => {
      showCopyKanbanSpecDialog.value = false
    })
}

// + Add on a column: handled LOCALLY by KanbanView (no longer
// bubbles up here). KanbanView opens the KanbanTaskDetailDialog
// in create mode, then calls workspacesStore.addTask +
// moveTaskToColumn on submit. AppLayout doesn't wire this event
// anymore — see the comment at the top of the kanban section.

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

// ─── Design mode event handlers (Chunk 8 of design-mode-redesign) ────
//
// <DesignView> emits these when the user interacts with the canvas:
// tabs, layers, properties panel, Monaco editor. We forward them to
// the workspaces store + useDesignHandlers composable.
//
// pageId note: DesignView keeps the active page id in a LOCAL ref
// (its `activePageId`); the workspaces store does not yet track the
// active page. The selectPage/selectElement emits are currently
// noops — the parent doesn't need the info, the child already
// owns the state. Element mutations need pageId, which the store's
// `activeDesignPageId` (mirrored by DesignView's `watch(activePageId,
// ...)`) provides.
//
// Page CRUD (add / delete) used to live here too — we would bounce
// the click event up from DesignView, call the API, and trust that
// DesignView would re-fetch its pages list. It didn't, leaving the
// user staring at stale tabs until they reloaded the page. The
// fix moved the page CRUD into DesignView itself (which owns the
// `pages` state), so AppLayout no longer needs addPage /
// deletePage handlers.
const handleDesignSelectPage = (_pageId: string) => {
  // TODO (v2): workspacesStore.setActiveDesignPage(_pageId) once the
  // store tracks the active page. For now DesignView owns the page
  // state internally; the parent doesn't need to mirror it.
  void _pageId
}

const handleDesignSelectElement = (_elementId: string) => {
  // TODO (v2): workspacesStore.setActiveDesignElement(_elementId) so
  // other tabs / the right sidebar can show the element's properties.
  // For now selection state lives inside DesignView.
  void _elementId
}

// NEW: design-mode chat toggle (top-right 💬 button in DesignView).
// Finds or creates a per-page "Design Chat: <pageName>" standard
// task on the active design item and sets it as the active task,
// which triggers the 3-column "DesignView | resize-handle |
// ChatView" template below. Reuses the same per-page chat task
// across reopens (so history persists) — the look-up is by
// workspace_item_id + name = "Design Chat: <pageName>". Each
// design page gets a DISJOINT chat task; switching pages while a
// chat is open does NOT swap the active chat (the chat stays
// bound to the page that opened it; closing + reopening binds
// to the current page).
//
// Plan: docs/superpowers/plans/2026-07-28-design-per-page-chat-sessions.md
//
// Migration of legacy data: users created before this fix have a
// single "Design Chat" canonical task (the pre-fix behavior). On
// the first 💬 click on any page, that legacy task is RENAMED in
// place to "Design Chat: <activePageName>" via `api.updateTask`.
// The task id is preserved, so all existing `llm_history` rows
// stay attached. New pages the user visits later get fresh tasks
// via the existing `addTask` path.
//
// We could mark the task with a dedicated task_type (e.g.
// 'design_chat') and filter on that, but the existing standard
// task_type already gives us everything we need (no kanban auto-
// assign fires because the parent is not a kanban — see the
// parent_is_kanban check in createStandardTask at task_create.zig
// ~line 294) and adding a new task_type is a migration.
//
// 2026-07-28 FK rewrite (plan:
// docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md):
// DESIGN_CHAT_TASK_NAME and PER_PAGE_CHAT_PREFIX are no longer used
// for chat lookup — the FK is the source of truth. `taskHasMessages`
// is gone too (no need to probe whether a task has messages — the
// FK is always populated at page-create time). The legacy
// pre-FK code that lived here (name matching, N+1 message probe,
// one-shot legacy migration) is removed; see the plan for the
// historical context.

const handleDesignOpenChat = async (payload: {
  pageId: string
  pageName: string
  workspaceItemTaskId: string
}): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item || item.item_type !== 'design') return
  if (!payload.pageId || !payload.pageName) return
  if (!payload.workspaceItemTaskId) return

  // 2026-07-28 FK rewrite (plan:
  // docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md):
  // resolve the chat task via the FK directly. Each design page is
  // paired 1:1 with a workspace_item_tasks row at create time (see
  // design_model.setDesignPage) — the page row carries the task id
  // on the wire. No name matching, no legacy migration, no
  // `taskHasMessages` probe. The previous 2026-07-28 per-page
  // naming-convention implementation has been replaced.
  workspacesStore.setActiveTask(payload.workspaceItemTaskId)
  // 2026-08-06 (plan: design-chat-as-dialog): capture the design
  // page's own name so DesignChatDialog's header reads
  // "Design Chat: <pageName>". Distinct from the workspace item's
  // name (which would be the parent design's name like "Design").
  activeDesignChatPageName.value = payload.pageName
  // Bug fix (2026-08-06, user report "chat button keep not popup,
  // chatview"): the dialog's v-if was previously gated on the
  // store's `activeTask` computed, which is null for design items
  // (their tasks array is empty post-init). Capture the FK's
  // task id into a separate ref that the dialog actually reads;
  // see `activeDesignChatTaskId` declaration above.
  activeDesignChatTaskId.value = payload.workspaceItemTaskId
}

const handleDesignUpdateElement = async (
  elementId: string,
  patch: Partial<{
    x: number
    y: number
    width: number
    height: number
    rotation: number
    [k: string]: unknown
  }>,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  // Deprecated back-compat path (PATCH /geometry). New typed events
  // emit translateElement / resizeElement instead — see below.
  await designHandlers.updateElement(ws.id, item.id, elementId, patch)
}

/**
 * NEW (2026-08-06, split-move-resize plan) — handler for the
 * `translateElement` event fired by DesignView during a single-element
 * drag (move mode). Routes to useDesignHandlers.translateElement →
 * POST /translate. Backend handles cascade-to-descendants for groups.
 */
const handleDesignTranslateElement = async (
  elementId: string,
  dx: number,
  dy: number,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.translateElement(ws.id, item.id, elementId, dx, dy)
}

/**
 * NEW (2026-08-06, split-move-resize plan) — handler for the
 * `resizeElement` event fired by DesignView during a resize gesture.
 * Routes to useDesignHandlers.resizeElement → POST /resize. Resize
 * never cascades (Figma convention).
 */
const handleDesignResizeElement = async (
  elementId: string,
  patch: Partial<{
    x: number
    y: number
    width: number
    height: number
    rotation: number
    [k: string]: unknown
  }>,
): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.resizeElement(ws.id, item.id, elementId, patch)
}

const handleDesignDeleteElement = async (elementId: string): Promise<void> => {
  const ws = activeWorkspace.value
  const item = activeWorkspaceItem.value
  if (!ws || !item) return
  await designHandlers.deleteElement(ws.id, item.id, elementId)
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
      // Optional 1-based line number to scroll to on mount (set when the user
      // clicks a line in the diff view). Only valid numbers > 0 are honored.
      const lineParam = query.line as string | undefined
      const parsedLine = lineParam ? parseInt(lineParam, 10) : NaN
      const requestedLine = Number.isFinite(parsedLine) && parsedLine > 0 ? parsedLine : null

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
          codeEditorRequestedLine.value = requestedLine
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

// Expose the design chat open handler so tests can simulate the
// user clicking the 💬 button in DesignView (which emits `openChat`).
// In production, this is reached via the DesignView emit chain —
// tests don't render DesignView because they stub it. Cheap seam.
defineExpose({
  handleDesignOpenChat,
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
          :line="codeEditorRequestedLine ?? undefined"
          @close="closeCodeEditor"
          @save="handleCodeEditorSave"
        />
      </div>

      <!-- Kanban view (kanban-embed-chatview plan, Task 5). The kanban
           now owns the chat pane + resize handle internally — the old
           3-column sibling-of-KanbanView branch (was at lines
           1716-1814) is GONE. KanbanView renders the full-width board
           when no task is active, or the board+chat side-by-side when
           a task belonging to this kanban is selected. The :key on
           KanbanView forces a fresh mount when the user navigates
           from one kanban to another (KanbanView fetches columns on
           mount). `@close-chat` fires when ChatView's close button is
           clicked — AppLayout handles URL routing + state cleanup. -->
      <KanbanView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'kanban'"
        :key="'kanban-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
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
        @rename-item="handleKanbanRenameItem"
        @close-chat="handleCloseTaskView"
      />
      <!--
        Kanban chat dialog (plan: 2026-08-06-kanban-chat-as-dialog).
        Mounted at the AppLayout level (NOT inside KanbanView) so the
        chat opens as a centered modal overlay rather than a side-by-
        side layout. Gated on `activeTaskWorkspaceItemId === activeWorkspaceItem.id`
        so the dialog only opens for kanban items — design / routine
        / standalone chat use their own mounts. `v-model:show` is
        driven by the kanbanChatDialogOpen ref, kept in sync with
        `activeTask` via a watcher so the dialog opens when the user
        navigates to a kanban task and closes when they navigate away.
        URL routing is handled by AppLayout's existing
        handleCloseTaskView (re-used via @close).
      -->
      <KanbanChatDialog
        v-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'kanban' &&
          activeTask &&
          activeTaskWorkspaceItemId === activeWorkspaceItem.id
        "
        v-model:show="kanbanChatDialogOpen"
        :task="activeTask"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :project-name="activeWorkspaceItem.name ?? ''"
        :cwd="activeWorkspaceItem.path ?? ''"
        @close="handleCloseTaskView"
      />
      <!--
        Design chat dialog (plan: 2026-08-06-design-chat-as-dialog).
        Mirrors the KanbanChatDialog mount above — same Teleport
        pattern, same v-model:show binding driven by `activeTask`.
        Mounted at the AppLayout level (NOT inside DesignView) so the
        chat opens as a centred modal overlay rather than a side-by-
        side column. Gated on `item_type === 'design'` so the dialog
        only opens for design items — kanban / folder / standalone
        chat use their own mounts. The pre-fix design+chat 3-column
        branch (data-design-three-column) was removed; the dialog
        reclaims the full canvas width. URL routing is handled by
        AppLayout's existing handleCloseTaskView (re-used via @close).
      -->
      <DesignChatDialog
        v-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.item_type === 'design' &&
          activeDesignChatTaskId
        "
        v-model:show="designChatDialogOpen"
        :task="activeDesignChatTask"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        :page-name="activeDesignChatPageName"
        :project-name="activeWorkspace?.name ?? ''"
        :cwd="activeWorkspaceItem.path ?? ''"
        @close="handleCloseTaskView"
      />
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
      <!--
        STALE MOUNT removed (kanban-chat-as-dialog plan, 2026-08-06).
        This <KanbanView> mount was a v-else-if continuation of the
        chain that started with the <KanbanChatDialog v-if> at line 1691.
        Vue evaluates v-if / v-else-if / v-else within one chain,
        but KanbanChatDialog's `v-if` (not `v-else-if`) started a
        NEW chain — so this mount and the correct mount at line 1655
        (also a v-else-if but in a different outer chain) both fired
        when activeWorkspaceItem.item_type === 'kanban' and no chat
        task was active. Result: the kanban board rendered TWICE,
        stacked vertically (visible in the user's screenshot 2026-08-06).
        The correct mount is the one at line 1655 above; this stale
        copy was a leftover from before the kanban-embed-chatview plan
        unified AppLayout's main-content chain.
      -->
      <!-- Design view (Chunk 8 of design-mode-redesign). Mirrors the
           single-column kanban branch above: full-bleed render when
           a design workspace item is active and no chat is open.
           The :key forces a fresh mount on item switch so the page
           list re-fetches. DesignView emits page/element mutations
           which we forward to the workspaces store (or api layer
           directly for page create — no store action yet).

           2026-08-06 (plan: design-chat-as-dialog): the design chat
           no longer shares this branch with a side-by-side chat
           column. The previous 3-column [DesignView | resize-handle |
           ChatView] layout (added in commit d0a05eb0, 2026-07-14)
           took ~40-65% of the canvas for ChatView even when
           "minimised". The chat is now a centred modal dialog
           (DesignChatDialog) mounted at the AppLayout level above —
           the canvas stays full-width behind a dimmed+blurred
           backdrop. The pre-fix data-design-three-column branch,
           data-design-resize-handle, design-chat-collapse-button,
           and design-chat-expand-button are GONE with the resize /
           collapse state machine. -->
      <DesignView
        v-else-if="activeWorkspaceItem && activeWorkspaceItem.item_type === 'design'"
        :key="'design-' + activeWorkspaceItem.id"
        :item="activeWorkspaceItem"
        :workspace-id="activeWorkspace?.id ?? ''"
        :item-id="activeWorkspaceItem.id"
        @select-page="handleDesignSelectPage"
        @select-element="handleDesignSelectElement"
        @update-element="handleDesignUpdateElement"
        @translate-element="handleDesignTranslateElement"
        @resize-element="handleDesignResizeElement"
        @delete-element="handleDesignDeleteElement"
        @open-chat="handleDesignOpenChat"
      />
      <ChatView
        v-else-if="activeChatId.startsWith('chat-')"
        :key="activeChatId"
        :chat-id="activeChatId"
        :chat-name="activeChatName"
        @update-chat-id="handleUpdateChatId"
      />
      <Chats v-else-if="currentView === 'chat'" />
      <!--
        Workspace memories view (for non-kanban / non-design items with
        a path). Mirrors the kanban / design branches above but for
        any other item_type (folder, etc.) — the dedicated views above
        should win first in the chain, but the explicit `item_type !==
        'kanban'` / `'design'` guards are defensive: they prevent the
        memories view from ever rendering in those cases even if the
        chain is reordered. Item's own header (🧠 + name + path) lives
        inside WorkspaceItemMemoriesView, so no outer header is needed.
        Regression test: AppLayout.memoriesGate.spec.ts.
      -->
      <div
        v-else-if="
          activeWorkspaceItem &&
          activeWorkspaceItem.path &&
          activeWorkspaceItem.item_type !== 'kanban' &&
          activeWorkspaceItem.item_type !== 'design'
        "
        class="flex-1 min-h-0"
      >
        <WorkspaceItemMemoriesView
          :key="activeWorkspaceItem.id"
          :cwd="activeWorkspaceItem.path"
          :item-name="activeWorkspaceItem.name"
        />
      </div>
      <!--
        Workspace view branch — no-path centered card + workspaces
        picker. Renders when `currentView === 'workspace'` AND no
        earlier branch in the chain matched (kanban / design / folder
        memories / chat- / Chats all win first — their dedicated
        mounts handle the active item). The `!activeWorkspaceItem`
        guard on the INNER testid ensures mutual exclusivity with
        the dedicated branches above. Without it, the kanban
        branch above + the chain break from the v-if KanbanChatDialog
        would resolve to this branch when currentView is 'workspace'
        even if a kanban is active, causing the workspace folder
        preview to render UNDER the kanban board (regression
        introduced in commit d0a05eb0; pinned by
        AppLayout.kanban.spec.ts → "kanban renders alone, workspace
        folder preview is not in DOM"). The chain-order test
        (AppLayout.memoriesGate.spec.ts → "kanban branch BEFORE the
        workspace view branch") pins that this v-else-if comes AFTER
        the kanban v-else-if in source.
      -->
      <div
        v-else-if="currentView === 'workspace'"
        class="flex-1 flex flex-col"
      >
        <!-- No-path fallback: keep today's centered card. Reached when
             the user navigates to a workspace item that has no `path`
             (e.g. a stub folder with no project root) AND the item
             is not a kanban/design (those have their own dedicated
             views above). The inner `!activeWorkspaceItem` guard on
             the workspaces-picker testid below ensures the kanban
             chain doesn't accidentally show the picker. -->
        <div
          v-if="
            activeWorkspaceItem &&
            activeWorkspaceItem.item_type !== 'kanban' &&
            activeWorkspaceItem.item_type !== 'design'
          "
          class="flex-1 flex flex-col items-center justify-center p-8"
        >
          <div
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
        </div>

        <div
          v-else-if="!activeWorkspaceItem"
          class="flex-1 flex flex-col"
          data-testid="workspace-folder-preview"
        >
          <div class="text-center">
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
      </div>
    </main>

    <!-- Settings page -->
    <SettingsView v-if="currentView === 'settings'" />

    <!-- Right Sidebar (Explorer + Git tabs) — DISABLED 2026-06-29 (task disable-rightsidebar-vue)
    <RightSidebar
      v-if="rightSidebarCwd"
      :cwd="rightSidebarCwd"
      :width="rightSidebarWidth"
      @file-click="handleRightSidebarFileClick"
      @skill-click="handleRightSidebarSkillClick"
      @code-editor-file-click="handleCodeEditorFileClick"
      @resize="handleRightSidebarResize"
    />
    -->

    <!-- Global error notification stack -->
    <NotificationContainer />

    <!-- Global SSE connection status pill. Renders nothing while the
         connection is healthy (state === 'open'); surfaces a small
         "Connecting…" / "Reconnecting…" / "Connection lost" pill in
         the top-right corner when the bus is in a degraded state.
         Fixed-positioned so it stays visible regardless of which
         view (chat / kanban / settings / workspace) is active.
         `pointer-events-none` keeps the pill visible WITHOUT
         capturing clicks — the pill overlaps the top-right of every
         view's chrome (in the kanban 3-column layout it sits on top
         of ChatView's ✕ close button; in design mode it sits on top
         of any future top-right toolbar). The pill is purely
         informational (no controls inside), so passing the click
         through is the right behavior. -->
    <div
      class="fixed top-3 right-3 z-50 pointer-events-none"
      data-testid="sse-status-badge-container"
    >
      <SseStatusBadge />
    </div>

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
      @rename-item="handleKanbanRenameItem"
      @copy-spec="handleOpenCopyKanbanSpec"
    />

    <!--
      CopyKanbanSpecDialog — source picker + Replace/Append radio for
      bulk-copying column spec from another kanban. Mounted as a SIBLING
      of <KanbanSettingsDialog> (not nested) so a user can stack them:
      Settings dialog under, picker over, both visible at once. The picker
      filters out the active kanban as a source (CopyKanbanSpecDialog's
      `availableSources` computed).
      Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
        (Chunk 4, Task 4.3)
    -->
    <CopyKanbanSpecDialog
      :show="showCopyKanbanSpecDialog"
      :workspace-id="activeWorkspace?.id ?? ''"
      :target-item-id="activeWorkspaceItem?.id ?? ''"
      @close="handleCloseCopyKanbanSpec"
      @copy="handleCopyKanbanSpec"
    />
  </div>
</template>

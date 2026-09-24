<script setup lang="ts">
import { ref, watch, inject, onMounted, onUnmounted, nextTick, computed, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { buildAppUrl } from '../../helpers/appUrl'
import { useContextMenu } from '../../composables/useContextMenu'
import { isBackgroundOpenEvent } from '../../helpers/tabTarget'
import { openInNewTab } from '../../helpers/openInNewTab'
import { VirtualScroller, formatRelativeTime } from '../../helpers'
import {
  fetchPrInfoCached,
  fetchPrStatusCached,
  branchUrlFromPrUrl,
} from '../../helpers/prStatusCache'
import { sessionEngineDb, toSessionRow } from '../../sync/SessionEngineDb'
import * as api from '../../api'
import SessionSlider from '../SessionSlider.vue'
import OpenInNewTabMenu from '../shell/OpenInNewTabMenu.vue'
import GitBranchMenu from '../shell/GitBranchMenu.vue'

const router = useRouter()

// Props
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const props = defineProps<{
  collapsed?: boolean
}>()

const emit = defineEmits<{
  navigate: [id: string, chatName?: string]
}>()

// Stores
const navigationStore = useNavigationStore()
const sidebarStore = useSidebarStore()
const workspacesStore = useWorkspacesStore()

// URL-driven "what is the main content area showing?". Derived from
// the URL so the chat row's active background stays in sync with
// refresh / deep links / browser back / forward — no store flag can
// drift. See useCurrentMainView for the full contract.
const currentMainView = useCurrentMainView()

// Workspace scope for the CHATS list (plan: 2026-09-22-revamp-ui-chats).
// The list shows ONLY this workspace's sessions — the backend filters
// via `?workspace_id=`. Source: the URL path workspace when present,
// else the store's active workspace (landing / transition windows).
// Undefined → global list (back-compat; the boot rewrite scopes it on
// the next tick).
const scopedWorkspaceId = computed(() => {
  const v = currentMainView.value
  if (v.kind === 'chat' && v.workspaceId) return v.workspaceId
  if (v.kind === 'workspace' && v.workspaceId) return v.workspaceId
  return workspacesStore.activeWorkspace?.id
})

// Reactive active check for a chat row. Called from the template on
// every render so the row's highlight stays in sync with URL changes
// (pre-fix, `active` was set as a one-shot flag inside `loadChats()`
// — leaving it stale after a chat → workspace navigation).
const isCurrentChat = (sessionId: string): boolean =>
  currentMainView.value.kind === 'chat' && currentMainView.value.sessionId === sessionId

// Migration 082 - "AI is ahead of you" stale-dot check.
// True when the AI has touched the chat since the human's last touch
// (updated_at > last_human_touched_at). Empty / null human-time means
// "never touched" - no comparison to make, no dot.
// Both come from the backend as unix-ms strings (Migration 075
// convention) - we compare as numbers.
const isStale = (human: string | undefined, updated: string | undefined): boolean => {
  if (!human) return false
  if (!updated) return false
  // Both fields are SQLite datetime UTC strings ('YYYY-MM-DD HH:MM:SS')
  // - identical format - so lexicographic string comparison is the
  // most accurate (and fastest) way to detect 'updated_at > human_time'.
  // String comparison matches the SELECT layer's
  // `needs_human_review` predicate (llm_history.zig), which compares
  // `t.last_human_touched_at_nano < CAST(strftime('%s', s.updated_at) * 1000)`
  // - also a unix-vs-datetime comparison that resolves to the same
  // truth (newer string > older string).
  return updated > human
}

// Inject processingState from App.vue
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// Kanban-style git branch badge with PR-status colors (same palette
// as WorkspaceItemTaskCard: green = open, violet = merged, red =
// closed, orange = plain branch). Bold by design so the icon pops
// against the muted chat row.
const prStatuses = ref<Record<string, string>>({})
const prSeqByChat = new Map<string, number>()

type ChatRow = {
  id: string
  cwd?: string
  git_worktree_cwd?: string
  git_branch?: string
}

const effectiveChatCwd = (item: ChatRow): string => item.git_worktree_cwd || item.cwd || ''

const chatBranchStyle = (id: string): Record<string, string> => {
  const s = prStatuses.value[id] || ''
  if (s === 'merged') return { color: 'var(--color-violet)', fontWeight: '600' }
  if (s === 'closed') return { color: 'var(--semantic-error)', fontWeight: '600' }
  if (s === 'open') return { color: 'var(--color-green)', fontWeight: '600' }
  return { color: 'var(--color-orange)', fontWeight: '600' }
}

const chatBranchTitle = (item: ChatRow): string => {
  const branch = item.git_branch || ''
  const s = prStatuses.value[item.id] || ''
  const base =
    s === 'merged'
      ? `PR merged — ${branch}`
      : s === 'closed'
        ? `PR closed — ${branch}`
        : s === 'open'
          ? `PR open — ${branch}`
          : branch
  // Surface the worktree path alongside the branch so the full
  // checkout location stays discoverable on hover.
  if (item.git_worktree_cwd) return `${base} — ${item.git_worktree_cwd}`
  return base
}

const refreshChatPrStatus = async (item: ChatRow) => {
  const branch = item.git_branch || ''
  const cwd = effectiveChatCwd(item)
  if (!branch || !cwd) {
    if (prStatuses.value[item.id]) delete prStatuses.value[item.id]
    return
  }
  const seq = (prSeqByChat.get(item.id) || 0) + 1
  prSeqByChat.set(item.id, seq)
  // Shared cache: dedupes the list-load burst across rows, retries
  // transient failures, resolves '' (fail-silent) when unknown.
  const status = await fetchPrStatusCached(cwd, branch)
  if (prSeqByChat.get(item.id) !== seq) return
  if (status) prStatuses.value[item.id] = status
  else if (prStatuses.value[item.id]) delete prStatuses.value[item.id]
}

// Note: the navItems watcher that triggers refreshChatPrStatus lives
// below, right after the navItems declaration (TDZ: watch() evaluates
// its source eagerly, so it must run after `const navItems`).

// Helper to check if a session is processing

// State
const chatsLoading = ref(false)
const navItems = ref<
  {
    id: string
    name: string
    active?: boolean
    processing?: boolean
    relativeTime?: string
    selected_profile_model?: string
    sub_agent_name?: string
    parent_session_id?: string
    cwd?: string
    git_worktree_cwd?: string
    git_branch?: string
    is_auto_retry_until_stop?: string
    last_human_touched_at?: string
    updated_at?: string
    // Raw `updated_at` sort value (matches the backend
    // `sort_by=updated_at` order). Used for display sorting and for
    // cache-first scroll-back (`loadOlderFromCache`).
    sortKey?: string
  }[]
>([])
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>(navigationStore.chatsSortDirection)
const chatsTotal = ref(0)

// Resolve PR colors whenever the row list (re)populates — same burst
// pattern as the kanban board mount.
watch(
  navItems,
  (items) => {
    for (const item of items || []) {
      if (item.git_branch) void refreshChatPrStatus(item)
    }
  },
  { deep: false },
)

// Right-click "Open in new tab" for a chat row. Position state +
// dismiss wiring live in useContextMenu; the row payload (chat id)
// lives here so @open can target it.
const { menuPos, openAt, close: closeContextMenu } = useContextMenu()
const contextMenuChatId = ref<string | null>(null)

const onChatRowContextMenu = (event: MouseEvent, item: { id: string; name: string }) => {
  contextMenuChatId.value = item.id
  openAt(event)
}

const openContextMenuInBackground = () => {
  const id = contextMenuChatId.value
  contextMenuChatId.value = null
  closeContextMenu()
  if (!id) return
  openChatInNewTab({ id })
}

// Right-click menu on the git icon: open GitHub branch / PR URLs in
// a new tab. Separate position state from the row menu so a git-icon
// right-click never opens the chat menu. URLs resolve via the shared
// PR-info cache (GET /api/git/pr/status already returns pr_url);
// the branch URL derives from the PR repo base + /tree/<branch>.
const { menuPos: gitMenuPos, openAt: openGitMenuAt, close: closeGitMenu } = useContextMenu()
const gitMenuBranch = ref('')
const gitMenuBranchUrl = ref('')
const gitMenuPrUrl = ref('')

const onGitIconContextMenu = async (event: MouseEvent, item: ChatRow) => {
  event.preventDefault()
  event.stopPropagation()
  const branch = item.git_branch || ''
  const cwd = effectiveChatCwd(item)
  gitMenuBranch.value = branch
  gitMenuBranchUrl.value = ''
  gitMenuPrUrl.value = ''
  openGitMenuAt(event)
  if (!branch || !cwd) return
  try {
    const info = await fetchPrInfoCached(cwd, branch)
    // Stale guard: user may have right-clicked another icon while
    // this fetch was in flight.
    if (gitMenuBranch.value !== branch) return
    gitMenuPrUrl.value = info.prUrl || ''
    gitMenuBranchUrl.value = branchUrlFromPrUrl(info.prUrl || '', branch)
  } catch {
    // Fail-silent: menu stays open with disabled items.
  }
}

const openGitBranchInBackground = () => {
  const url = gitMenuBranchUrl.value
  closeGitMenu()
  if (!url) return
  window.open(url, '_blank', 'noopener')
}

const openGitPrInBackground = () => {
  const url = gitMenuPrUrl.value
  closeGitMenu()
  if (!url) return
  window.open(url, '_blank', 'noopener')
}

// Sort toggle extracted to a method so the template stays a single
// expression. An inline multi-statement handler needs a semicolon
// separator, which the repo prettier config (semi:false,
// printWidth:100) strips when it wraps the long line, breaking the
// Vue template compiler (see ChatsList activeFromUrl specs).
const onSortToggle = () => {
  chatsSortDirection.value = chatsSortDirection.value === 'desc' ? 'asc' : 'desc'
  loadChats()
}

// Chats resize handling
const isChatsResizing = ref(false)
const chatsResizeStartY = ref(0)
const chatsResizeStartPx = ref(0)

// ChatsList maintains its OWN navItems mirror of workspacesStore
// state, populated by loadChats(). To keep navItems in sync with
// session renames/deletes/creates, we subscribe to the store's
// session event fan-out (registered via workspacesStore.onSessionEvent).
// The callback re-runs loadChats() — the simplest correct path since
// navItems has its own shape (relativeTime, processing flag, etc.)
// that's not derived from the workspace tree.
//
// Without this subscription, session events would update the
// workspace tree but leave the sidebar stale until manual reload.
// See `docs/superpowers/plans/2026-06-30-unify-sse-endpoints.md`
// Chunk 5 / Task 5.3 for the migration context.

// Virtual scroller ref
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
const virtualScrollerRef = ref<any>(null)

// Get computed chats height in pixels from percentage
const getChatsHeightPx = (): number => {
  const aside = document.querySelector('aside')
  if (!aside) return 200
  const navHeight = aside.clientHeight - 56 - 48 // header + footer
  return (navHeight * sidebarStore.chatsHeight) / 100
}

const startChatsResize = (e: MouseEvent) => {
  e.preventDefault()
  e.stopPropagation()
  console.log('[ChatsList] startChatsResize', e.clientY)
  isChatsResizing.value = true
  chatsResizeStartY.value = e.clientY
  chatsResizeStartPx.value = getChatsHeightPx()
  document.addEventListener('mousemove', handleChatsResize, { passive: false })
  document.addEventListener('mouseup', stopChatsResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'row-resize'
}

const handleChatsResize = (e: MouseEvent) => {
  e.preventDefault()
  if (!isChatsResizing.value) return
  console.log(
    '[ChatsList] handleChatsResize',
    e.clientY,
    'delta:',
    e.clientY - chatsResizeStartY.value,
  )
  const deltaY = e.clientY - chatsResizeStartY.value
  const newHeightPx = Math.max(80, chatsResizeStartPx.value + deltaY)
  // Convert back to percentage
  const aside = document.querySelector('aside')
  if (!aside) return
  const navHeight = aside.clientHeight - 56 - 48
  const newPercent = (newHeightPx / navHeight) * 100
  console.log('[ChatsList] newPercent:', newPercent)
  sidebarStore.setChatsHeight(newPercent)
}

const stopChatsResize = () => {
  isChatsResizing.value = false
  document.removeEventListener('mousemove', handleChatsResize)
  document.removeEventListener('mouseup', stopChatsResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

// Watch for local changes and sync to store
watch(chatsSortDirection, (newVal) => {
  navigationStore.setChatsSortDirection(newVal)
})

// Watch for processingState changes from App.vue
watch(
  processingState,
  (state) => {
    navItems.value = navItems.value.map((item) => ({
      ...item,
      processing: !!state[item.id], // Show spinner for ANY processing chat, not just active
    }))
  },
  { deep: true },
)

// Public methods for parent to call
// Amber stale-dot clear (yellow-dot-fix): optimistic patch + best-effort
// backend touch. isStale() predicate is unchanged — clearing the dot
// is done by aligning last_human_touched_at to updated_at.
const optimisticClearStaleDot = (id: string) => {
  const item = navItems.value.find((i) => i.id === id)
  if (item && item.updated_at) {
    item.last_human_touched_at = item.updated_at
    item.relativeTime = formatRelativeTime(item.last_human_touched_at)
  }
}

// Loop-guard (touched-echo fix): fireSessionTouched fires at most ONCE
// per sessionId per component lifetime. Without this, loadChats() →
// POST touched → backend SSE session.updated → onSessionEvent →
// loadChats() → POST touched … loops forever (alternating
// GET /llm/session + POST /touched in the Network tab).
const touchedFiredFor = new Set<string>()
const touchedAtMs = new Map<string, number>()
// Echo window: a session.updated arriving within this long after our
// own touched POST is assumed to be the backend echo of that POST,
// not an independent rename — skip the refetch for it.
const TOUCH_ECHO_SUPPRESS_MS = 5000

const fireSessionTouched = (id: string) => {
  if (!id || touchedFiredFor.has(id)) return
  touchedFiredFor.add(id)
  touchedAtMs.set(id, Date.now())
  api.markSessionTouched(id).catch((e) => {
    // Allow retry on failure: a failed stamp never reached the DB,
    // so no SSE echo is coming — drop the guards.
    touchedFiredFor.delete(id)
    touchedAtMs.delete(id)
    console.error('Failed to mark session touched:', e)
  })
}

// Sidebar local-first: the cache partition key. Matches the
// `scopedWorkspaceId` refetch boundary — each workspace paints its own
// cached rows, `'all'` when unscoped (back-compat).
const sessionCacheKey = (): string => scopedWorkspaceId.value ?? 'all'

// Single mapper for server session → row view model, shared by the
// cache paint and the network paint so both shapes stay identical
// (same "no shape drift" rule as ChatView's toChatMessages).
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
const toNavItem = (session: any) => ({
  id: session.session_id,
  name: session.session_name || 'New Chat',
  // active state now derives from the URL via isCurrentChat() in
  // the template (sidebar-single-active fix 2026-08-06). Storing
  // it here would freeze the highlight at loadChats() time and
  // leave stale `active: true` after navigation away from chat.
  active: false,
  processing: !!processingState.value[session.session_id], // Show spinner for any processing chat
  // Migration 082 — prefer human-touched timestamp when present.
  relativeTime: formatRelativeTime(session.last_human_touched_at || session.updated_at),
  selected_profile_model: session.selected_profile_model || '',
  sub_agent_name: session.sub_agent_name || '',
  parent_session_id: session.parent_session_id || '',
  cwd: session.cwd || '',
  git_worktree_cwd: session.git_worktree_cwd || '',
  git_branch: session.git_branch || '',
  // Migration 063 — defaulted to "0" in getChats mapping so the
  // `=== '1'` badge check below is well-defined.
  is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
  // Migration 082 — captured separately for the stale-dot check
  // (compares updated_at vs last_human_touched_at to render the
  // amber "AI is ahead of you" indicator).
  last_human_touched_at: session.last_human_touched_at || '',
  updated_at: session.updated_at || '',
  sortKey: session.updated_at || '',
})

// Display order for cached paints. The engine stores newest-first;
// the backend serves `direction` order — re-apply it here so a warm
// mount in asc mode matches the network order exactly.
const sortNavItemsForDisplay = () => {
  const asc = chatsSortDirection.value === 'asc'
  navItems.value.sort((a, b) => {
    const ak = a.sortKey ?? ''
    const bk = b.sortKey ?? ''
    if (ak === bk) return 0
    return (ak < bk ? -1 : 1) * (asc ? 1 : -1)
  })
}

const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  // Local-first mount (mirrors ChatView): paint the workspace cache
  // instantly, then revalidate page 1 in the background. The ctx guard
  // drops late paints after a fast workspace switch.
  const ctx = sessionCacheKey()
  const isCurrentCtx = () => sessionCacheKey() === ctx
  try {
    console.log('[ChatsList] loadChats called, cache-first...')
    const cached = await sessionEngineDb.primeFromCache(ctx, 30)
    if (cached.length > 0 && isCurrentCtx()) {
      navItems.value = cached.map((r) => toNavItem(r.raw))
      sortNavItemsForDisplay()
      chatsLoading.value = false
      restoreActiveFromUrl()
    }
    const delta = await sessionEngineDb.loadDelta(ctx, 30)
    if (delta && isCurrentCtx()) {
      navItems.value = delta.items.map((r) => toNavItem(r.raw))
      sortNavItemsForDisplay()
      chatsHasMore.value = delta.hasMore
      chatsNextCursor.value = delta.nextCursor
      chatsTotal.value = delta.total
      restoreActiveFromUrl()
    } else if (cached.length === 0 && isCurrentCtx()) {
      // Cold miss + network failure: keep the empty fallback so the
      // UI doesn't crash while the apiFetch toast shows the error.
      navItems.value = []
    }
  } catch (err) {
    console.error('Failed to load chats:', err)
    navItems.value = []
  } finally {
    console.log(
      '[ChatsList] loadChats finished, chatsLoading:',
      chatsLoading.value,
      'navItems:',
      navItems.value.length,
    )
    chatsLoading.value = false
  }
}

// Deep-link / refresh cover, extracted so both the cache paint and
// the delta paint can run it: if the URL already shows a chat,
// optimistic-clear its dot + fire the touch so the dot clears
// without waiting for the next SSE refresh. fireSessionTouched is
// once-per-lifetime guarded, so the double call is a no-op.
const restoreActiveFromUrl = () => {
  // If we found and activated a saved chat, restore it in AppLayout
  const activeItem = navItems.value.find((item) => item.active)
  if (activeItem) {
    navigationStore.setActiveChatName(activeItem.name)
    emit('navigate', `chat-${activeItem.id}`, activeItem.name)
  }

  const current = currentMainView.value
  if (current.kind === 'chat' && current.sessionId) {
    // Fresh-tab title: a deep link never left-clicks, so
    // activeChatName is empty/stale and the browser tab would read
    // plain "Nalar". The name is usually already in this list —
    // fall back to a single-session fetch past page 1.
    const match = navItems.value.find((i) => i.id === current.sessionId)
    if (match && match.name && match.name !== 'New Chat') {
      navigationStore.setActiveChatName(match.name)
    } else {
      const sessionId = current.sessionId
      void api.getSession(sessionId).then((sess) => {
        const now = currentMainView.value
        if (now.kind === 'chat' && now.sessionId === sessionId && sess?.sessionName) {
          navigationStore.setActiveChatName(sess.sessionName)
        }
      })
    }
    optimisticClearStaleDot(current.sessionId)
    fireSessionTouched(current.sessionId)
  }
}

const loadMoreChats = async () => {
  if (!chatsHasMore.value || chatsLoading.value || !chatsNextCursor.value) return
  const ctx = sessionCacheKey()
  // Cache-first scroll-back in desc mode (mirrors ChatView.fetchOlderPage):
  // the write-through below accumulates every fetched page, so older rows
  // are usually already local. Cursor unchanged, id-dedupe covers overlap.
  // Asc mode stays network-only — "older" has no meaning against a
  // backend cursor that pages in display order.
  if (chatsSortDirection.value === 'desc' && navItems.value.length > 0) {
    const oldest = navItems.value[navItems.value.length - 1]?.sortKey ?? ''
    const cached = await sessionEngineDb.loadOlderFromCache(ctx, oldest, 20)
    if (cached.length > 0) {
      const seen = new Set(navItems.value.map((i) => i.id))
      const fresh = cached.filter((r) => !seen.has(r.id))
      if (fresh.length > 0) {
        navItems.value.push(...fresh.map((r) => toNavItem(r.raw)))
        return
      }
    }
  }
  chatsLoading.value = true
  try {
    const data = await api.getChats(
      'updated_at',
      chatsSortDirection.value,
      20,
      chatsNextCursor.value,
      scopedWorkspaceId.value,
    )
    const newItems = (data.sessions || []).map(toNavItem)
    navItems.value.push(...newItems)
    // Write-through so later mounts and scroll-backs hit the cache.
    await sessionEngineDb.putLocal(ctx, (data.sessions || []).map(toSessionRow))
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
  } catch (err) {
    console.error('Failed to load more chats:', err)
  } finally {
    chatsLoading.value = false
  }
}

const toggleNavSection = () => {
  const wasExpanded = sidebarStore.navExpanded
  sidebarStore.toggleNavExpanded()
  // If just became expanded and no chats loaded, reload
  if (!wasExpanded && navItems.value.length === 0) {
    loadChats()
  }
}

// Workspace switch refetch (plan: 2026-09-22-revamp-ui-chats). The
// list is scoped per workspace, so a scope change clears the old
// workspace's rows FIRST (no stale frame) and refetches. Clearing
// before the async fetch lands is what keeps the wrong workspace's
// chats from flashing on a fast switch.
watch(scopedWorkspaceId, () => {
  navItems.value = []
  chatsNextCursor.value = null
  chatsHasMore.value = false
  loadChats()
})

/**
 * Ctrl/Cmd+click, middle click and the context menu open a chat in a
 * real browser tab (window.open) instead of navigating — the browser
 * gesture. A plain click keeps the previous behaviour. Path-based
 * (plan: 2026-09-22-revamp-ui-chats): /app/{ws}/chat/{sid}.
 */
const openChatInNewTab = (item: { id: string }) => {
  const wsId = scopedWorkspaceId.value
  if (wsId) {
    openInNewTab(router, buildAppUrl({ workspaceId: wsId, chatSessionId: item.id }))
  } else {
    openInNewTab(router, { path: '/app', query: { view: 'chat', session: item.id } })
  }
}

const onChatRowClick = (event: MouseEvent, item: { id: string; name: string }) => {
  if (isBackgroundOpenEvent(event)) {
    openChatInNewTab(item)
    return
  }
  void setActive(item.id)
}

const onChatRowAuxClick = (event: MouseEvent, item: { id: string; name: string }) => {
  if (event.button !== 1) return
  event.preventDefault()
  openChatInNewTab(item)
}

const setActive = async (id: string) => {
  // 1) Existing navigation first, synchronously, so the UI never blocks.
  const chat = navItems.value.find((item) => item.id === id)
  const chatName = chat?.name || ''
  navigationStore.setActiveChatName(chatName)
  // Mutually exclusive active state: chat wins, clear workspace item.
  workspacesStore.setActiveWorkspaceItem(null)
  // ...and clear any active task (inverse direction: task → chat).
  workspacesStore.setActiveTask(null)
  navItems.value = navItems.value.map((item) => ({ ...item, active: item.id === id }))
  navigationStore.setActiveChat(id, chatName)
  // Update URL with session ID (path-based: /app/{ws}/chat/{sid}).
  const wsId = scopedWorkspaceId.value
  if (wsId) {
    router.replace(buildAppUrl({ workspaceId: wsId, chatSessionId: id }))
  } else {
    router.replace({ path: '/app', query: { view: 'chat', session: id } })
  }
  // 2) Optimistic clear: align human time to updated_at so isStale()
  // flips false immediately (no wait for the next list refresh).
  optimisticClearStaleDot(id)
  // 3) Best-effort backend stamp (don't await navigation).
  fireSessionTouched(id)
}

const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex((item) => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
    // Keep the cache consistent with the optimistic splice.
    await sessionEngineDb.removeSession(sessionCacheKey(), chatId)
    // Clear from navigation store if this was the active chat
    if (wasActive) {
      navigationStore.clearActiveChat()
      // Mutually exclusive active state: deleting the active chat drops us
      // back to "no chat selected" — also clear the workspace item.
      workspacesStore.setActiveWorkspaceItem(null)
      // ...and clear any active task (inverse direction: task → chat).
      workspacesStore.setActiveTask(null)
    }
    try {
      await api.deleteChat(chatId)
    } catch (err) {
      console.error('Failed to delete chat:', err)
    }
    if (wasActive && navItems.value.length > 0 && navItems.value[0]) {
      navItems.value[0].active = true
      const nextChat = navItems.value[0]
      navigationStore.setActiveChat(nextChat.id, nextChat.name)
      const nextWsId = scopedWorkspaceId.value
      if (nextWsId) {
        router.replace(buildAppUrl({ workspaceId: nextWsId, chatSessionId: nextChat.id }))
      } else {
        router.replace({ path: '/app', query: { view: 'chat', session: nextChat.id } })
      }
    }
  }
}

// Migration 063 — the unattended-mode toggle USED to live as a
// clickable badge in this list. After moving it into the Task
// details dialog (KanbanTaskDetailDialog.vue), the toggle handler
// (`toggleAutoRetry`) was deleted and the badge spans were removed
// from the template — the toggle is now flipped via the dialog's
// `@update-unattended` emit, which the host wires to
// `api.updateSession`. The `is_auto_retry_until_stop` field on
// each navItem is still rendered server-truth via SSE re-fetch, so
// any other UI that wants to show unattended state (e.g. a status
// icon) can read it from `item.is_auto_retry_until_stop === '1'`.

// ─── Session Events via sseBus ─────────────────────────────────────────────────
//
// Session events (renames / deletes / creates) arrive through the
// global sseBus (opened once by App.vue). The workspaces store
// installs its own `bus.on('session', ...)` handler in its `init()`
// for internal tree mutation; we register a second listener here
// (via `workspacesStore.onSessionEvent(cb)`) to re-fetch our
// navItems mirror whenever any session event arrives — the nav
// list isn't derived from the workspace tree, so the internal
// handler's match-by-task-id path is a no-op for us. See Chunk 6
// of the unify-frontend-sse plan.

// Lifecycle
// Subscribe to session events at setup time (synchronously) so the
// `onUnmounted` cleanup hook can also be registered synchronously
// (Vue 3 lifecycle injection APIs must run during setup, not after
// the first `await` inside `onMounted`). The callback re-runs
// loadChats() — works whether it fires before or after mount.
//
// Touched-echo fix: our own POST touched emits a session.updated SSE
// that echoes back within milliseconds. Reloading on that echo would
// re-enter loadChats() → fireSessionTouched → … forever. So:
//  - `updated` events inside the echo window after our own touch are
//    swallowed (no refetch — the optimistic patch already cleared
//    the dot locally);
//  - all other events (created/deleted, renames from elsewhere) go
//    through a short trailing debounce so an SSE burst coalesces
//    into a single GET instead of one per event.
let sseReloadTimer: ReturnType<typeof setTimeout> | undefined
const scheduleSseReload = () => {
  if (sseReloadTimer !== undefined) return // burst already coalesced
  sseReloadTimer = setTimeout(() => {
    sseReloadTimer = undefined
    loadChats()
  }, 400)
}
const unsubSession = workspacesStore.onSessionEvent((event) => {
  if (event.action === 'deleted') {
    // Instant evict: drop the row from the cache and the list now,
    // then let the debounced reload revalidate totals/cursors.
    void sessionEngineDb.removeSession(sessionCacheKey(), event.id)
    navItems.value = navItems.value.filter((i) => i.id !== event.id)
    scheduleSseReload()
    return
  }
  if (event.action === 'updated') {
    const firedAt = touchedAtMs.get(event.id)
    if (firedAt !== undefined && Date.now() - firedAt < TOUCH_ECHO_SUPPRESS_MS) {
      return
    }
  }
  scheduleSseReload()
})
onUnmounted(() => {
  unsubSession()
  if (sseReloadTimer !== undefined) {
    clearTimeout(sseReloadTimer)
    sseReloadTimer = undefined
  }
})

onMounted(async () => {
  console.log('[ChatsList] onMounted called')
  // Wait for DOM to be ready
  await nextTick()
  // Load chats immediately when mounted
  loadChats()
})

// Watch for navItems changes to sync active state
watch(
  navItems,

  (newItems) => {
    // eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
    newItems.forEach((item, index) => {
      if (item.processing && processingState.value[item.id]) {
        item.processing = true // Keep processing state true
      }
    })
  },
  { deep: true },
)

// Watch for processingState changes
watch(processingState, (state) => {
  navItems.value = navItems.value.map((item) => ({
    ...item,
    processing: !!state[item.id], // Show spinner for ANY processing chat, not just active
  }))
})

onUnmounted(() => {
  // No SSE teardown needed — ChatsList no longer owns a session-
  // event stream. The canonical subscription lives in the
  // workspaces store and persists for the app's lifetime.
})

// Cleanup on unmount
const cleanup = () => {
  stopChatsResize()
}

defineExpose({
  loadChats,
  removeChat,
  resetActiveChat: () => {
    navItems.value = navItems.value.map((navItem) => ({ ...navItem, active: false }))
  },
  cleanup,
  updateChatId: (oldId: string, newId: string) => {
    const chatItem = navItems.value.find((item) => item.id === oldId)
    if (chatItem) {
      chatItem.id = newId
    }
  },
  virtualScrollerRef,
})
</script>

<template>
  <!-- Chats Section with Resizable Height -->
  <div
    v-if="!collapsed"
    class="shrink-0 flex flex-col"
    :style="
      sidebarStore.navExpanded
        ? { height: sidebarStore.chatsHeight + '%', minHeight: '80px' }
        : { height: 'auto', minHeight: '0' }
    "
  >
    <!-- Header with expand/collapse toggle. Contract protected by
         sidebarSpacing.spec.ts — the exact class string below is
         grep-matched: 'class="px-3 py-2.5 flex items-center gap-2
         w-full text-left hover:opacity-70 transition-opacity shrink-0
         border-b border-[--color-border]/40"'. Inside the header:
         a single chevron + the section title; the trailing sort
         control uses bare text (no SVG, no decoration) for a minimal
         typographic feel. There is deliberately NO "+ new chat"
         button (removed 2026-09-22 revamp) — new chats are created
         from workspace items (projects), so every chat belongs to a
         workspace and the list below can stay scoped. -->
    <button
      class="px-3 py-2.5 flex items-center gap-2 w-full text-left hover:opacity-70 transition-opacity shrink-0 border-b border-[--color-border]/40"
      @click="toggleNavSection"
    >
      <span
        class="text-xs transition-transform duration-200"
        :style="{ transform: sidebarStore.navExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
        style="color: var(--semantic-text-dim)"
        >▶</span
      >
      <span
        class="text-xs font-semibold uppercase tracking-wider"
        style="color: var(--semantic-text-dim)"
        >Chats</span
      >
      <div class="flex items-center gap-1 ml-auto" v-if="sidebarStore.navExpanded">
        <button
          @click.stop="onSortToggle"
          :title="
            chatsSortDirection === 'desc'
              ? 'Newest first (click to flip)'
              : 'Oldest first (click to flip)'
          "
          :aria-label="chatsSortDirection === 'desc' ? 'Sort: newest first' : 'Sort: oldest first'"
          data-testid="chats-sort-toggle"
          class="w-7 h-7 text-base font-medium transition-opacity duration-150 hover:opacity-100 flex items-center justify-center"
          style="color: var(--semantic-text-dim); opacity: 0.7"
        >
          {{ chatsSortDirection === 'desc' ? '↓' : '↑' }}
        </button>
      </div>
    </button>

    <!-- Chat List -->
    <div v-if="sidebarStore.navExpanded" class="flex-1 min-h-0 flex flex-col overflow-hidden">
      <VirtualScroller
        ref="virtualScrollerRef"
        :totalCount="chatsTotal"
        :items="navItems"
        :default-item-height="48"
        :buffer="5"
        :load-more-threshold="200"
        @load-more="loadMoreChats"
        class="flex-1 min-h-0"
      >
        <template #default="{ item }">
          <button
            @click="onChatRowClick($event, item)"
            @auxclick="onChatRowAuxClick($event, item)"
            @contextmenu.prevent="onChatRowContextMenu($event, item)"
            class="relative w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150 border-t border-transparent overflow-hidden"
            :class="isCurrentChat(item.id) ? 'border-[--color-border]/60' : ''"
            :style="
              isCurrentChat(item.id)
                ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);'
                : 'color: var(--semantic-text-muted);'
            "
          >
            <span class="flex-1 text-left truncate">
              <!-- Git icon first (kanban parity): icon-only branch badge
                   with PR-status colors (green = open, violet = merged,
                   red = closed). Tooltip carries the branch + full
                   worktree path. -->
              <span
                v-if="item.git_branch"
                class="mr-1 inline-flex items-center align-middle cursor-context-menu"
                :style="chatBranchStyle(item.id)"
                :title="chatBranchTitle(item) + ' — right-click to open GitHub'"
                :data-pr-status="prStatuses[item.id] || undefined"
                data-testid="chat-git-branch"
                @contextmenu.prevent.stop="onGitIconContextMenu($event, item)"
              >
                <svg
                  class="w-4 h-4 shrink-0"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  stroke-width="2.5"
                  aria-hidden="true"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
                  />
                </svg>
              </span>
              <!-- Fallback for bound worktrees whose cwd is not a git
                   repo (no branch to show): same icon in bold orange so
                   the binding stays visible. -->
              <span
                v-else-if="item.git_worktree_cwd"
                class="mr-1 inline-flex items-center align-middle"
                style="color: var(--color-orange)"
                :title="item.git_worktree_cwd"
                data-testid="worktree-badge"
              >
                <svg
                  class="w-4 h-4 shrink-0"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  stroke-width="2.5"
                  aria-hidden="true"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
                  />
                </svg>
              </span>
              {{ item.name }}
              <span
                v-if="item.sub_agent_name"
                class="ml-1 text-[10px] font-mono"
                style="color: var(--color-violet)"
                :title="
                  item.parent_session_id ? 'Sub-agent of ' + item.parent_session_id : 'Sub-agent'
                "
                >🔧 {{ item.sub_agent_name }}</span
              >
            </span>
            <!-- Migration 082 - replace AI-tainted updated_at with the human
                 time (last_human_touched_at ?? updated_at). Stale dot
                 appears when the AI has touched since the human's
                 last touch ("AI is ahead of you"). Hover tooltips
                 distinguish "Last human activity" vs "Last activity
                 (never touched by you yet)" so the source of the
                 timestamp is discoverable without a comment.
                 Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md (Task 8) -->
            <span class="text-xs opacity-60 shrink-0 ml-2 flex items-center gap-1">
              <span
                v-if="isStale(item.last_human_touched_at, item.updated_at)"
                class="w-1 h-1 rounded-full bg-amber-400"
                title="AI is still working — your last touch was earlier"
                data-testid="chat-stale-dot"
              />
              <span
                :title="
                  item.last_human_touched_at
                    ? 'Last human activity'
                    : 'Last activity (never touched by you yet)'
                "
                data-testid="chat-time-pill"
                >{{ item.relativeTime || 'now' }}</span
              >
            </span>
            <!-- Per-session LLM circle spinner at the end of this row.
                 Hidden when this session is idle; spins while
                 processingState[item.id] is true. Reads
                 processingState via Vue inject from App.vue — no
                 prop drilling needed. -->
            <SessionSlider :session-id="item.id" />
          </button>
        </template>
      </VirtualScroller>

      <!-- Loading indicator -->
      <div v-if="chatsLoading" class="py-2 text-center shrink-0">
        <span class="text-xs" style="color: var(--semantic-text-dim)">Loading...</span>
      </div>

      <!-- Drag Resize Handle -->
      <div
        class="h-3 cursor-row-resize flex items-center justify-center group/resize shrink-0 mt-1"
        :class="'bg-[--color-border]/20 hover:bg-[--color-border]/40 transition-colors'"
        title="Drag to resize"
        @mousedown="startChatsResize"
      >
        <div
          class="w-2/3 h-0.5 transition-all duration-200 group-hover/resize:h-1 rounded"
          style="background: var(--color-border)"
        />
      </div>
    </div>
  </div>

  <!-- Collapsed state: no chats affordance. The "+" new-chat button
       was removed (2026-09-22 revamp) — new chats come from workspace
       items, so the collapsed sidebar shows nothing here. The wrapper
       div stays so the layout spacing is unchanged. -->
  <div v-else class="mb-2 shrink-0" data-testid="collapsed-chats-placeholder" />

  <OpenInNewTabMenu
    v-if="menuPos"
    :x="menuPos.x"
    :y="menuPos.y"
    @open="openContextMenuInBackground"
  />
  <GitBranchMenu
    v-if="gitMenuPos"
    :x="gitMenuPos.x"
    :y="gitMenuPos.y"
    :branch="gitMenuBranch"
    :branch-url="gitMenuBranchUrl"
    :pr-url="gitMenuPrUrl"
    @open-branch="openGitBranchInBackground"
    @open-pr="openGitPrInBackground"
  />
</template>

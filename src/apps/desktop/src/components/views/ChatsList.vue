<script setup lang="ts">
import { ref, watch, inject, onMounted, onUnmounted, nextTick, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { VirtualScroller, formatRelativeTime } from '../../helpers'
import * as api from '../../api'
import SessionSlider from '../SessionSlider.vue'

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
  return Number(updated) > Number(human)
}

// Inject processingState from App.vue
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// Helper to check if a session is processing

// State
const chatsLoading = ref(false)
const navItems = ref<{ id: string; name: string; active?: boolean; processing?: boolean; relativeTime?: string; selected_profile_model?: string; git_worktree_cwd?: string; is_auto_retry_until_stop?: string; last_human_touched_at?: string; updated_at?: string }[]>([])
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>(navigationStore.chatsSortDirection)
const chatsTotal = ref(0)

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
const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  try {
    console.log('[ChatsList] loadChats called, fetching from API...')
    const data = await api.getChats('updated_at', chatsSortDirection.value, 30)
    console.log('[ChatsList] API returned:', data)
    const sessions = data.sessions || []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
    navItems.value = sessions.map((session: any) => ({
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
      git_worktree_cwd: session.git_worktree_cwd || '',
      // Migration 063 — defaulted to "0" in getChats mapping so the
      // `=== '1'` badge check below is well-defined.
      is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
        // Migration 082 — captured separately for the stale-dot check
        // (compares updated_at vs last_human_touched_at to render the
        // amber "AI is ahead of you" indicator).
        last_human_touched_at: session.last_human_touched_at || '',
        updated_at: session.updated_at || '',
    }))
    console.log('[ChatsList] navItems set to:', navItems.value)
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
    chatsTotal.value = data.total

    // If we found and activated a saved chat, restore it in AppLayout
    const activeItem = navItems.value.find((item) => item.active)
    if (activeItem) {
      navigationStore.setActiveChatName(activeItem.name)
      emit('navigate', `chat-${activeItem.id}`, activeItem.name)
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

const loadMoreChats = async () => {
  if (!chatsHasMore.value || chatsLoading.value || !chatsNextCursor.value) return
  chatsLoading.value = true
  try {
    const data = await api.getChats(
      'updated_at',
      chatsSortDirection.value,
      20,
      chatsNextCursor.value,
    )
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
    const newItems = (data.sessions || []).map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      active: false,
      processing: false,
      // Migration 082 — prefer human-touched timestamp when present.
      relativeTime: formatRelativeTime(session.last_human_touched_at || session.updated_at),
      // Migration 082 — captured for the stale-dot check (same as loadChats).
      last_human_touched_at: session.last_human_touched_at || '',
      updated_at: session.updated_at || '',
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

const toggleNavSection = () => {
  const wasExpanded = sidebarStore.navExpanded
  sidebarStore.toggleNavExpanded()
  // If just became expanded and no chats loaded, reload
  if (!wasExpanded && navItems.value.length === 0) {
    loadChats()
  }
}

const createChat = () => {
  const name = 'New Chat'
  const newChatId = `session-${Date.now()}`
  // Mutually exclusive active state: a brand-new chat wins, clear workspace item.
  workspacesStore.setActiveWorkspaceItem(null)
  // ...and clear any active task (inverse direction: task → chat).
  workspacesStore.setActiveTask(null)
  navItems.value.forEach((item) => (item.active = false))
  navItems.value.unshift({ id: newChatId, name, active: true, processing: false })
  // Update navigation store
  navigationStore.setActiveChat(newChatId, name)
  emit('navigate', `chat-${newChatId}`, name)
}

const setActive = (id: string) => {
  const chat = navItems.value.find((item) => item.id === id)
  const chatName = chat?.name || ''
  navigationStore.setActiveChatName(chatName)
  // Mutually exclusive active state: chat wins, clear workspace item.
  workspacesStore.setActiveWorkspaceItem(null)
  // ...and clear any active task (inverse direction: task → chat).
  workspacesStore.setActiveTask(null)
  navItems.value = navItems.value.map((item) => ({ ...item, active: item.id === id }))
  navigationStore.setActiveChat(id, chatName)
  // Update URL with session ID
  router.replace({ path: '/app', query: { view: 'chat', session: id } })
}

const confirmDeleteChat = (chatId: string) => {
  // Emit event to parent for delete confirmation
  emit('navigate', 'delete-chat', chatId)
}

const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex((item) => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
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
      router.replace({ path: '/app', query: { view: 'chat', session: nextChat.id } })
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
// the first `await` inside `onMounted`). The callback just re-runs
// loadChats() — works whether it fires before or after mount.
const unsubSession = workspacesStore.onSessionEvent(() => {
  loadChats()
})
onUnmounted(() => {
  unsubSession()
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
         a single chevron + the section title; the trailing sort and
         "+ new chat" controls use bare text (no SVG, no decoration)
         for a minimal typographic feel. -->
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
          @click.stop="chatsSortDirection = chatsSortDirection === 'desc' ? 'asc' : 'desc'; loadChats()"
          :title="chatsSortDirection === 'desc' ? 'Newest first (click to flip)' : 'Oldest first (click to flip)'"
          :aria-label="chatsSortDirection === 'desc' ? 'Sort: newest first' : 'Sort: oldest first'"
          data-testid="chats-sort-toggle"
          class="text-xs font-medium transition-opacity duration-150 hover:opacity-100"
          style="color: var(--semantic-text-dim); opacity: 0.7;"
        >
          {{ chatsSortDirection === 'desc' ? '↓' : '↑' }}
        </button>
        <button
          @click.stop="createChat"
          class="text-xs font-medium transition-opacity duration-150 hover:opacity-100"
          style="color: var(--semantic-text-dim); opacity: 0.7;"
          title="New Chat"
          aria-label="New Chat"
          data-testid="chats-new-chat-button"
        >
          +
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
            @click="setActive(item.id)"
            class="relative w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150 border-t border-transparent overflow-hidden"
            :class="isCurrentChat(item.id) ? 'border-[--color-border]/60' : ''"
            :style="
              isCurrentChat(item.id)
                ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);'
                : 'color: var(--semantic-text-muted);'
            "
          >
            <span class="flex-1 text-left truncate">
              {{ item.name }}
              <span
                v-if="item.selected_profile_model"
                class="ml-1 text-[10px]"
                style="color: var(--color-violet);"
                >🤖 {{ item.selected_profile_model }}</span
              >
              <span
                v-if="item.git_worktree_cwd"
                class="ml-1 text-xs text-emerald-600 dark:text-emerald-400 font-mono"
                :title="item.git_worktree_cwd"
                data-testid="worktree-badge"
                >🌳 worktree</span
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
                :title="item.last_human_touched_at
                  ? 'Last human activity'
                  : 'Last activity (never touched by you yet)'"
                data-testid="chat-time-pill"
              >{{ item.relativeTime || 'now' }}</span>
            </span>
            <button
              v-if="item.id !== 'chat'"
              @click.stop="confirmDeleteChat(item.id)"
              class="w-5 h-5 rounded text-sm leading-none flex items-center justify-center opacity-0 group-hover/chat:opacity-100 transition-opacity hover:text-red-400 shrink-0"
              style="color: var(--semantic-text-dim)"
              title="Delete chat"
            >
              ×
            </button>
            <!-- Per-session LLM slider at the bottom edge of this row.
                 Hidden when this session is idle; slides while
                 processingState[item.id] is true. Replaces the old
                 yellow spinner (was: 9-line <span>/<div> animate-spin
                 block). Reads processingState via Vue inject from
                 App.vue — no prop drilling needed. The component
                 self-positions (absolute bottom-0), so this row's
                 button just needs `position: relative`. -->
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
          style="background: var(--color-border);"
        />
      </div>
    </div>
  </div>

  <!-- Collapsed Chats Button. Bare text "+" with a thin border,
       matching the collapsed workspace tile style for visual
       consistency. NO chat-bubble SVG — the user wants minimal,
       icon-free design. Hover just darkens the text color. -->
  <div v-else class="mb-2 shrink-0">
    <button
      @click="createChat"
      data-testid="collapsed-new-chat-button"
      title="New Chat"
      aria-label="New Chat"
      class="w-9 h-9 rounded-md flex items-center justify-center text-sm transition-colors duration-150 hover:text-[--semantic-text]"
      style="color: var(--semantic-text-dim);"
    >
      +
    </button>
  </div>
</template>

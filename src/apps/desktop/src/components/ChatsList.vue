<script setup lang="ts">
import { ref, watch, inject, onMounted, onUnmounted, nextTick, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../stores/navigation'
import { useWorkspacesStore } from '../stores/workspaces'
import { useSidebarStore } from '../stores/sidebar'
import { VirtualScroller, formatRelativeTime } from '../helpers'
import * as api from '../api'

const router = useRouter()

// Props
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

// Inject processingState from App.vue
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// Helper to check if a session is processing

// State
const chatsLoading = ref(false)
const navItems = ref<{ id: string; name: string; active?: boolean; processing?: boolean; relativeTime?: string; selected_profile_model?: string; git_worktree_cwd?: string }[]>([])
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
    const savedSessionId = navigationStore.sessionId
    const sessions = data.sessions || []
    navItems.value = sessions.map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      active: savedSessionId === session.session_id,
      processing: !!processingState.value[session.session_id], // Show spinner for any processing chat
      relativeTime: formatRelativeTime(session.updated_at),
      selected_profile_model: session.selected_profile_model || '',
      git_worktree_cwd: session.git_worktree_cwd || '',
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
    const newItems = (data.sessions || []).map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      active: false,
      processing: false,
      relativeTime: formatRelativeTime(session.updated_at),
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

// ─── Session Events SSE ────────────────────────────────────────────────────────
//
// The sessions SSE plumbing (connect / disconnect + handleSessionEvent)
// was removed with the unify-SSE migration (Chunk 5 / Task 5.3):
//   - `workspacesStore.subscribeToSessionEvents()` is the SINGLE
//     subscription point for session events; it runs on store init.
//   - The workspace store already handles `updated` and `deleted`
//     (it ignores `created` by design — see workspaces.ts:1530).
//   - The ChatsList receives the same `SessionEvent` flow through
//     Vue reactivity (workspacesStore state is shared).
//   - No local SSE connection, no <SseStatusBadge> binding needed.

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
    <!-- Header with expand/collapse toggle -->
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
        <select
          v-model="chatsSortDirection"
          @change="loadChats"
          @click.stop
          class="text-xs px-1.5 py-0.5 rounded cursor-pointer"
          style="background: var(--semantic-card-bg); color: var(--semantic-text-dim); border: none"
        >
          <option value="desc">↓</option>
          <option value="asc">↑</option>
        </select>
        <button
          @click.stop="createChat"
          class="w-5 h-5 rounded flex items-center justify-center transition-colors hover:opacity-70"
          style="color: var(--semantic-text-dim)"
          title="New Chat"
        >
          <span class="text-sm">+</span>
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
            class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150 border-t border-transparent"
            :class="item.active ? 'border-[--color-border]/60' : ''"
            :style="
              item.active
                ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text);'
                : 'color: var(--semantic-text-muted);'
            "
          >
            <span
              v-if="item.processing === true"
              class="w-5 h-5 flex items-center justify-center shrink-0"
            >
              <div
                class="w-4 h-4 border-2 rounded-full animate-spin"
                style="border-color: var(--color-yellow); border-top-color: transparent"
              ></div>
            </span>
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
            <span class="text-xs opacity-60 shrink-0 ml-2">{{ item.relativeTime || 'now' }}</span>
            <button
              v-if="item.id !== 'chat'"
              @click.stop="confirmDeleteChat(item.id)"
              class="w-5 h-5 rounded flex items-center justify-center opacity-0 group-hover/chat:opacity-100 transition-opacity hover:text-red-400 shrink-0"
              style="color: var(--semantic-text-dim)"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M6 18L18 6M6 6l12 12"
                />
              </svg>
            </button>
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

  <!-- Collapsed Chats Button -->
  <div v-else class="mb-3 shrink-0">
    <button
      @click="createChat"
      class="w-full h-10 rounded-lg flex items-center justify-center transition-colors hover:opacity-80"
      style="color: var(--semantic-text-muted)"
    >
      <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
      </svg>
    </button>
  </div>
</template>

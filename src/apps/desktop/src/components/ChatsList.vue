<script setup lang="ts">
import { ref, watch, inject, onMounted, onUnmounted, nextTick, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../stores/navigation'
import { useSidebarStore } from '../stores/sidebar'
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

// Inject processingState from App.vue
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// Helper to check if a session is processing

// State
const chatsLoading = ref(false)
const navItems = ref<{ id: string; name: string; active?: boolean; processing?: boolean }[]>([])
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>(navigationStore.chatsSortDirection)

// Chats resize handling
const isChatsResizing = ref(false)
const chatsResizeStartY = ref(0)
const chatsResizeStartPx = ref(0)

// SSE connection for session events
const sessionsEventSource = ref<EventSource | null>(null)

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
  console.log('[ChatsList] handleChatsResize', e.clientY, 'delta:', e.clientY - chatsResizeStartY.value)
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
watch(processingState, (state) => {
  navItems.value = navItems.value.map(item => ({
    ...item,
    processing: !!state[item.id]  // Show spinner for ANY processing chat, not just active
  }))
}, { deep: true })

const handleChatsScroll = (e: Event) => {
  const target = e.target as HTMLElement
  const scrollBottom = target.scrollHeight - target.scrollTop - target.clientHeight
  if (scrollBottom < 100 && chatsHasMore.value && !chatsLoading.value) {
    loadMoreChats()
  }
}

// Public methods for parent to call
const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  try {
    console.log('[ChatsList] loadChats called, fetching from API...')
    const data = await api.getChats('created_at', chatsSortDirection.value, 20)
    console.log('[ChatsList] API returned:', data)
    const savedSessionId = navigationStore.sessionId
    const sessions = data.sessions || []
    navItems.value = sessions.map((session: any) => ({
      id: session.session_id,
      name: session.session_name || 'New Chat',
      active: savedSessionId === session.session_id,
      processing: !!processingState.value[session.session_id],  // Show spinner for any processing chat
    }))
    console.log('[ChatsList] navItems set to:', navItems.value)
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
    console.log('[ChatsList] loadChats finished, chatsLoading:', chatsLoading.value, 'navItems:', navItems.value.length)
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
      active: false,
      processing: false,
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
  navItems.value.forEach(item => item.active = false)
  navItems.value.unshift({ id: newChatId, name, active: true, processing: false })
  // Update navigation store
  navigationStore.setActiveChat(newChatId, name)
  emit('navigate', `chat-${newChatId}`, name)
}

const setActive = (id: string) => {
  const chat = navItems.value.find(item => item.id === id)
  const chatName = chat?.name || ''
  navigationStore.setActiveChatName(chatName)
  navItems.value = navItems.value.map(item => ({ ...item, active: item.id === id }))
  navigationStore.setActiveChat(id, chatName)
  // Update URL with session ID
  router.replace({ path: '/app', query: { view: 'chat', session: id } })
}

const confirmDeleteChat = (chatId: string) => {
  // Emit event to parent for delete confirmation
  emit('navigate', 'delete-chat', chatId)
}

const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex(item => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
    // Clear from navigation store if this was the active chat
    if (wasActive) {
      navigationStore.clearActiveChat()
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

const connectSessionsSse = () => {
  console.log('[ChatsList] Connecting sessions SSE')
  if (sessionsEventSource.value) {
    sessionsEventSource.value.close()
  }
  sessionsEventSource.value = api.createSessionsSseConnection(
    (event) => {
      console.log('[ChatsList] Received session event:', event)
      handleSessionEvent(event)
    },
    (error) => {
      console.error('[ChatsList] Sessions SSE error:', error)
    },
    () => {
      console.log('[ChatsList] Sessions SSE connected')
    }
  )
}

const disconnectSessionsSse = () => {
  if (sessionsEventSource.value) {
    sessionsEventSource.value.close()
    sessionsEventSource.value = null
  }
}

// Handle session events from SSE - create, update, or delete
const handleSessionEvent = (event: api.SessionEvent) => {
  console.log('[ChatsList] handleSessionEvent:', event)

  if (event.action === 'created') {
    // Prepend new session to top of list
    const newItem = {
      id: event.id,
      name: event.name || 'New Chat',
      active: false,
      processing: false,
    }
    // Check if already exists (avoid duplicates)
    const existingIndex = navItems.value.findIndex(item => item.id === event.id)
    if (existingIndex === -1) {
      navItems.value.unshift(newItem)
    }
  } else if (event.action === 'updated') {
    // Update existing session or create if not found
    const existingIndex = navItems.value.findIndex(item => item.id === event.id)
    if (existingIndex !== -1) {
      const existing = navItems.value[existingIndex]
      if (existing) {
        navItems.value[existingIndex] = {
          ...existing,
          name: event.name || existing.name,
        }
      }
    } else {
      // Create if not exists
      navItems.value.unshift({
        id: event.id,
        name: event.name || 'New Chat',
        active: false,
        processing: false,
      })
    }
  } else if (event.action === 'deleted') {
    // Remove session from list
    const index = navItems.value.findIndex(item => item.id === event.id)
    if (index !== -1) {
      const wasActive = navItems.value[index]?.active ?? false
      navItems.value.splice(index, 1)
      // If was active, navigate to first chat
      if (wasActive && navItems.value.length > 0) {
        const firstItem = navItems.value[0]
        if (firstItem) {
          firstItem.active = true
          emit('navigate', firstItem.id, firstItem.name)
        }
      }
    }
  }
}

// Lifecycle
onMounted(async () => {
  console.log('[ChatsList] onMounted called')
  // Wait for DOM to be ready
  await nextTick()
  // Load chats immediately when mounted
  loadChats()
  connectSessionsSse()
})

// Watch for navItems changes to sync active state
watch(navItems, (newItems) => {
  newItems.forEach((item, index) => {
    if (item.processing && processingState.value[item.id]) {
      item.processing = true  // Keep processing state true
    }
  })
}, { deep: true })

// Watch for processingState changes
watch(processingState, (state) => {
  navItems.value = navItems.value.map(item => ({
    ...item,
    processing: !!state[item.id]  // Show spinner for ANY processing chat, not just active
  }))
})

onUnmounted(() => {
  disconnectSessionsSse()
})

// Cleanup on unmount
const cleanup = () => {
  stopChatsResize()
  disconnectSessionsSse()
}

defineExpose({
  loadChats,
  removeChat,
  resetActiveChat: () => {
    navItems.value = navItems.value.map(navItem => ({ ...navItem, active: false }))
  },
  cleanup,
  updateChatId: (oldId: string, newId: string) => {
    const chatItem = navItems.value.find(item => item.id === oldId)
    if (chatItem) {
      chatItem.id = newId
    }
  }
})
</script>

<template>
  <!-- Chats Section with Resizable Height -->
  <div v-if="!collapsed" class="shrink-0 flex flex-col" :style="sidebarStore.navExpanded ? { height: sidebarStore.chatsHeight + '%', minHeight: '80px' } : { height: 'auto', minHeight: '0' }">

    <!-- Header with expand/collapse toggle -->
    <button
      class="px-3 py-2 flex items-center gap-2 w-full text-left hover:opacity-70 transition-opacity shrink-0"
      @click="toggleNavSection"
    >
      <span
        class="text-xs transition-transform duration-200"
        :style="{ transform: sidebarStore.navExpanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
        style="color: var(--semantic-text-dim);"
      >▶</span>
      <span class="text-xs font-semibold uppercase tracking-wider" style="color: var(--semantic-text-dim);">Chats</span>
      <div class="flex items-center gap-1 ml-auto" v-if="sidebarStore.navExpanded">
        <select
          v-model="chatsSortDirection"
          @change="loadChats"
          @click.stop
          class="text-xs px-1.5 py-0.5 rounded cursor-pointer"
          style="background: var(--semantic-card-bg); color: var(--semantic-text-dim); border: none;"
        >
          <option value="desc">↓</option>
          <option value="asc">↑</option>
        </select>
        <button
          @click.stop="createChat"
          class="w-5 h-5 rounded flex items-center justify-center transition-colors hover:opacity-70"
          style="color: var(--semantic-text-dim);"
          title="New Chat"
        >
          <span class="text-sm">+</span>
        </button>
      </div>
    </button>

    <!-- Chat List -->
    <div v-if="sidebarStore.navExpanded" class="flex-1 min-h-0 flex flex-col">
      <ul ref="chatsContainerRef" @scroll="handleChatsScroll" class="flex-1 overflow-y-auto space-y-0.5 min-h-0">
        <li v-for="item in navItems" :key="item.id" class="group/chat">
          <button
            @click="setActive(item.id)"
            class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-150"
            :style="item.active
              ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text);'
              : 'color: var(--semantic-text-muted);'"
          >
            <span v-if="item.processing === true" class="w-5 h-5 flex items-center justify-center shrink-0">
              <div class="w-4 h-4 border-2 rounded-full animate-spin" style="border-color: var(--color-yellow); border-top-color: transparent;"></div>
            </span>
            <span class="flex-1 text-left truncate">{{ item.name }}</span>
            <button
              v-if="item.id !== 'chat'"
              @click.stop="confirmDeleteChat(item.id)"
              class="w-5 h-5 rounded flex items-center justify-center opacity-0 group-hover/chat:opacity-100 transition-opacity hover:text-red-400 shrink-0"
              style="color: var(--semantic-text-dim);"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </button>
        </li>
        <li v-if="chatsLoading" class="py-2 text-center">
          <span class="text-xs" style="color: var(--semantic-text-dim);">Loading...</span>
        </li>
        <li v-else-if="chatsHasMore">
          <button @click="loadMoreChats" class="w-full py-2 text-xs hover:opacity-70" style="color: var(--color-violet);">
            Load more
          </button>
        </li>
      </ul>

      <!-- Drag Resize Handle -->
      <div
        class="h-3 cursor-row-resize flex items-center justify-center group/resize shrink-0 mt-1"
        @mousedown="startChatsResize"
      >
        <div
          class="w-full h-0.5 transition-all duration-200 group-hover/resize:h-1 rounded"
          style="background: linear-gradient(90deg, transparent, var(--color-border), transparent);"
        />
      </div>
    </div>
  </div>

  <!-- Collapsed Chats Button -->
  <div v-else class="mb-3 shrink-0">
    <button
      @click="createChat"
      class="w-full h-10 rounded-lg flex items-center justify-center transition-colors hover:opacity-80"
      style="color: var(--semantic-text-muted);"
    >
      <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
      </svg>
    </button>
  </div>
</template>

<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, nextTick, computed } from 'vue'
import { marked } from 'marked'
import * as api from '../api'
import { stripThinkingTags } from '@/helpers';

const props = defineProps<{
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
}>()

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
}>()

// Default type is 'chat' for backward compatibility
const viewType = computed(() => props.type ?? 'chat')

// Task info (used when type === 'task')
const taskInfo = computed(() => ({
  taskId: (props as any).taskId ?? '',
  taskName: (props as any).taskName ?? props.chatName ?? '',
  projectName: (props as any).projectName ?? ''
}))

// Check if session is pending (needs creation on first message)
const isPendingSession = computed(() => props.chatId.startsWith('pending-'))

interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp: Date
  tool_name?: string
}

// Escape HTML to prevent XSS
const escapeHtml = (text: string): string => {
  const div = document.createElement('div')
  div.textContent = text
  return div.innerHTML
}

// Format tool output for display (handles <stdout>, <stderr>, <success>, <error> tags)

// Tool icons (emoji)
// Render markdown content to HTML
const renderResponse = (content: string, role: string, tool_name: string | undefined): string => {
  if (!content) return ''
  try {
    // Strip thinking tags before rendering

    if (role === 'assistant') {
      const cleanContent = stripThinkingTags(content)
      return marked.parse(cleanContent, { async: false }) as string
    }

    if (role === 'tool_calls') {
      const cleanContent = stripThinkingTags(content)
      return marked.parse(cleanContent, { async: false }) as string
    }


    if (role === 'tool') {
      if (tool_name === 'text_replace') {
        const mathPath = content.match(/<path>(.*?)<\/path>/);
        const mathSuccess = content.match(/<success>([\s\S]*?)<\/success>/);
        const path = mathPath ? mathPath[1] : null;
        const isSuccess = mathSuccess ? mathSuccess[1] === 'true' : false;
        const error = content.match(/<error>(.*?)<\/error>/);

        if (isSuccess) {
          return `<span class="tool-inline">${tool_name} → ${path}${isSuccess ? ' ✓' : `${error} ✗`}</span>`;
        }

        return `<span class="tool-inline">${tool_name} → ${`${error} ✗`}</span>`;
      }

      if (tool_name === 'read_file') {
        const mathPath = content.match(/<path>(.*?)<\/path>/);
        const path = mathPath ? mathPath[1] : null;
        return `<span class="tool-inline">${tool_name} → ${path}</span>`;
      }

      if (tool_name === 'write_file') {
        const mathPath = content.match(/<path>(.*?)<\/path>/);
        const path = mathPath ? mathPath[1] : null;
        return `<span class="tool-inline">${tool_name} → ${path}</span>`;
      }

      if (tool_name === 'bash' || tool_name === 'run_command') {
        const mathCmd = content.match(/<command>([\s\S]*?)<\/command>/);
        const command = mathCmd && mathCmd[1] ? mathCmd[1].trim() : null;
        return `<span class="tool-inline">${tool_name} → $ ${command || 'unknown command'}</span>`;
      }

      if (tool_name === 'search') {
        // Parse search results format: <file path="..." total="..." count="...">...</file>
        const mathQuery = content.match(/<query>(.*?)<\/query>/) || content.match(/"(.*?)"/);
        const query = mathQuery ? mathQuery[1] : null;

        // Check if we have file match format
        const fileMatch = content.match(/<file path="([^"]+)" total="(\d+)" count="(\d+)">/);
        if (fileMatch) {
          const filePath = fileMatch[1];
          const matchCount = fileMatch[3];
          return `<span class="tool-inline">search → "${query || 'unknown'}"</span><br><span class="tool-inline-result">  ${filePath} (${matchCount})</span>`;
        }
        const warningQuery = content.match(/<warning>(.*?)<\/warning>/);
        return `<span class="tool-inline">search → "${warningQuery || 'unknown'}"</span>`;
      }

      if (tool_name === 'glob') {
        const mathPattern = content.match(/<pattern>(.*?)<\/pattern>/) || content.match(/"(.*?)"/);
        const pattern = mathPattern ? mathPattern[1] : null;
        const mathResults = content.match(/<count>(\d+)<\/count>/);
        const count = mathResults ? mathResults[1] : null;
        const resultsText = count ? ` (${count} files)` : '';
        return `<span class="tool-inline">${tool_name} → "${pattern || 'unknown'}"${resultsText}</span>`;
      }

      if (tool_name === 'web_search') {
        const mathQuery = content.match(/<query>(.*?)<\/query>/) || content.match(/"(.*?)"/);
        const query = mathQuery ? mathQuery[1] : null;
        return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`;
      }

      if (tool_name === 'mcp_context7_query-docs' || tool_name === 'context7') {
        const mathQuery = content.match(/<query>(.*?)<\/query>/);
        const query = mathQuery ? mathQuery[1] : null;
        return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`;
      }

      if (tool_name === 'list_skills' || tool_name === 'get_skill' || tool_name === 'add_skill' || tool_name === 'edit_skill') {
        return `<span class="tool-inline">${tool_name}</span>`;
      }

      if (tool_name === 'spawn_sub_agent') {
        const mathCount = content.match(/<count>(\d+)<\/count>/);
        const count = mathCount ? mathCount[1] : null;
        return `<span class="tool-inline">${tool_name} → ${count || '0'} agents spawned</span>`;
      }

      if (tool_name === 'update_activity') {
        const thoughtQuery = content.match(/<thought>(.*?)<\/thought>/);

        return `<span class="tool-inline">${tool_name || 'tool'} → ${thoughtQuery}</span>`;
      }

      /// Default tool badge for other tools
      return `<span class="tool-inline">${tool_name || 'tool'} → ${escapeHtml(content)}</span>`;
    }


    // Default: return escaped content for unhandled roles
    return escapeHtml(content)
  } catch {
    return escapeHtml(content)
  }
}

// Session ID extracted from props on mount
const sessionId = ref('')

// Pagination state
const messageCursor = ref<string | null>(null)
const PAGE_SIZE = 40

// SSE connection
const eventSource = ref<EventSource | null>(null)
const isStreaming = ref(false)
const streamingContent = ref('')

// Scroll refs
const messagesContainer = ref<HTMLElement | null>(null)

// State
const messages = ref<Message[]>([])
const inputText = ref('')
const isLoading = ref(false)
const isLoadingMore = ref(false)
const error = ref<string | null>(null)
const hasMoreMessages = ref(true)
const isAtBottom = ref(true)
const cwd = ref('')
const maxTotalTokens = ref(0)
const maxCapacityTotalTokens = ref(200000)
const isLLMProcessing = ref(false)

// Poll for LLM processing status
let processingPollInterval: ReturnType<typeof setInterval> | null = null

const checkLLMProcessing = async () => {
  if (!sessionId.value || isPendingSession.value) {
    isLLMProcessing.value = false
    return
  }

  try {
    const { workers } = await api.getWorkers(undefined, 50, sessionId.value)
    isLLMProcessing.value = workers.length > 0
  } catch (err) {
    console.error('Failed to check LLM processing:', err)
    isLLMProcessing.value = false
  }
}

const startProcessingPoll = () => {
  // Check immediately
  checkLLMProcessing()
  // Then poll every 2 seconds
  if (processingPollInterval) clearInterval(processingPollInterval)
  processingPollInterval = setInterval(checkLLMProcessing, 2000)
}

const stopProcessingPoll = () => {
  if (processingPollInterval) {
    clearInterval(processingPollInterval)
    processingPollInterval = null
  }
}

// Git status state
const gitStatus = ref<api.GitStatus | null>(null)
let gitStatusPollInterval: ReturnType<typeof setInterval> | null = null

const checkGitStatus = async () => {
  if (!cwd.value) {
    gitStatus.value = null
    return
  }

  try {
    const status = await api.getGitStatus(cwd.value)
    gitStatus.value = status
  } catch (err) {
    console.error('Failed to check git status:', err)
    gitStatus.value = null
  }
}

const startGitStatusPoll = () => {
  // Check immediately
  checkGitStatus()
  // Then poll every 30 seconds
  if (gitStatusPollInterval) clearInterval(gitStatusPollInterval)
  gitStatusPollInterval = setInterval(checkGitStatus, 30000)
}

const stopGitStatusPoll = () => {
  if (gitStatusPollInterval) {
    clearInterval(gitStatusPollInterval)
    gitStatusPollInterval = null
  }
}

// Filter out empty messages for display (check stripped content)
const filteredMessages = computed(() =>
  messages.value.filter((m) => {
    const stripped = stripThinkingTags(m.content)
    return stripped && stripped.trim() !== ''
  })
)

// Group consecutive tool messages together for cleaner display
interface MessageGroup {
  role: 'user' | 'assistant' | 'tool'
  messages: Message[]
  timestamp: Date
}

const messageGroups = computed((): MessageGroup[] => {
  const groups: MessageGroup[] = []

  for (const msg of filteredMessages.value) {
    const lastGroup = groups[groups.length - 1]

    // Group consecutive tool messages from the same tool sequence
    if (msg.role === 'tool' && lastGroup && lastGroup.role === 'tool') {
      lastGroup.messages.push(msg)
      // Keep the latest timestamp
      if (msg.timestamp > lastGroup.timestamp) {
        lastGroup.timestamp = msg.timestamp
      }
    } else {
      // Start a new group
      groups.push({
        role: msg.role === 'tool' ? 'tool' : (msg.role as 'user' | 'assistant'),
        messages: [msg],
        timestamp: msg.timestamp
      })
    }
  }

  return groups
})

// ─── Chat History ────────────────────────────────────────────────────────────

const loadChatHistory = async (loadMore = false) => {
  // Skip loading for pending sessions (they have no history yet)
  if (!sessionId.value || isPendingSession.value) return

  if (loadMore) {
    isLoadingMore.value = true
  } else {
    isLoading.value = true
    messageCursor.value = null
  }
  error.value = null

  try {
    const data = await api.getChatHistory(
      sessionId.value,
      PAGE_SIZE,
      messageCursor.value ?? undefined
    )

    // Update cwd from response (only on first load)
    if (!loadMore && data.cwd) {
      cwd.value = data.cwd
    }

    // Update token info from response (only on first load)
    if (!loadMore) {
      if (data.max_total_tokens !== undefined) {
        maxTotalTokens.value = data.max_total_tokens
      }
      if (data.max_capacity_total_tokens !== undefined) {
        maxCapacityTotalTokens.value = data.max_capacity_total_tokens
      }
    }

    const newMessages = (data.messages || []).map((msg) => ({
      id: msg.id || `msg-${msg.created_at}`,
      role: msg.role as 'user' | 'assistant' | 'system',
      content: msg.content,
      timestamp: new Date(msg.created_at * 1000),
      tool_name: msg.tool_name,
    }))

    if (loadMore) {
      const oldHeight = messagesContainer.value?.scrollHeight ?? 0
      messages.value = [...newMessages.slice().reverse(), ...messages.value]
      await nextTick()
      // Restore scroll position after prepending messages
      if (messagesContainer.value && oldHeight > 0) {
        messagesContainer.value.scrollTop += messagesContainer.value.scrollHeight - oldHeight
      }
    } else {
      messages.value = newMessages.slice().reverse()
    }

    messageCursor.value = data.next_cursor
    hasMoreMessages.value = data.has_more

    if (!loadMore) {
      await nextTick()
      scrollToBottom(true)
    }
  } catch (err) {
    console.error('Failed to load chat history:', err)
    error.value = 'Failed to load messages'
    if (!loadMore) messages.value = []
  } finally {
    isLoading.value = false
    isLoadingMore.value = false
  }
}

// ─── Scroll ──────────────────────────────────────────────────────────────────

const scrollToBottom = async (force = false) => {
  await nextTick()
  if (messagesContainer.value) {
    const container = messagesContainer.value
    if (force || isAtBottom.value) {
      container.scrollTop = container.scrollHeight
    }
  }
}

const handleScroll = async () => {
  if (!messagesContainer.value) return

  const container = messagesContainer.value
  const { scrollTop, scrollHeight, clientHeight } = container

  isAtBottom.value = scrollHeight - scrollTop - clientHeight < 100

  if (
    scrollTop < 200 &&
    !isLoadingMore.value &&
    hasMoreMessages.value &&
    messages.value.length > 0
  ) {
    await loadChatHistory(true)
    await nextTick()
    if (messagesContainer.value) {
      const newScrollHeight = messagesContainer.value.scrollHeight
      messagesContainer.value.scrollTop = newScrollHeight - scrollHeight
    }
  }
}

// ─── SSE ─────────────────────────────────────────────────────────────────────

const connectSse = () => {
  console.log('[connectSse] Connecting SSE for session:', sessionId.value)
  if (!sessionId.value) return

  disconnectSse()

  isStreaming.value = true
  streamingContent.value = ''

  eventSource.value = api.createSseConnection(
    sessionId.value,
    (event: api.SseEvent) => {
      console.log('[SSE ChatView] Received event:', event)

      // connected event
      if (event.type === 'connected' && event.session_id) {
        console.log('SSE connected, session:', event.session_id)
        return
      }

      // skip non-message events
      if (event.type !== 'chunk' && event.type !== 'full') {
        return
      }

      // streaming chunk - update UI with incremental content
      if (event.type === 'chunk' && event.content) {
        streamingContent.value = event.content
        updateStreamingMessage()
        return
      }

      // final message
      if (event.type === 'full' && event.finish_reason && event.content) {

        // replace any streaming placeholder with final message
        messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))

        // Parse role from event - use 'tool' for tool results, 'assistant' for regular responses
        const role = event.role as 'user' | 'assistant' | 'system' | 'tool' ||
          (event.tool_call_id ? 'tool' : 'assistant')

        // Create message using same format as loadChatHistory
        messages.value.push({
          id: event.id || `assistant-${Date.now()}`,
          role: role,
          content: event.content,
          timestamp: new Date(),
          tool_name: event.tool_name,
        })
        streamingContent.value = ''
        isStreaming.value = false
        nextTick(() => scrollToBottom(true))

        if (event.total_tokens) {
          maxTotalTokens.value = event.total_tokens;
        }

        if (event.finish_reason == 'stop') {

        }

        return
      }

      // reasoning only
      if (event.reasoning_content && !event.content) {
        console.log('Reasoning:', event.reasoning_content)
      }





    },
    (err) => {
      console.error('SSE error:', err)
      isStreaming.value = false
      streamingContent.value = ''
    },
    () => {
      console.log('SSE connected')
    }
  )
}

const disconnectSse = () => {
  if (eventSource.value) {
    eventSource.value.close()
    eventSource.value = null
  }
  isStreaming.value = false
  streamingContent.value = ''
  // remove any pending streaming placeholder
  messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
}

const updateStreamingMessage = () => {
  console.log('[updateStreamingMessage] streamingContent:', streamingContent.value)
  const existingMsg = messages.value.find(
    (m) => m.role === 'assistant' && m.id.startsWith('streaming-')
  )
  if (existingMsg) {
    existingMsg.content = streamingContent.value
  } else {
    messages.value.push({
      id: `streaming-${Date.now()}`,
      role: 'assistant',
      content: streamingContent.value,
      timestamp: new Date(),
    })
  }
  // Skip scroll if content is just thinking tags
  const stripped = stripThinkingTags(streamingContent.value)
  if (stripped && stripped.trim() !== '') {
    nextTick(() => scrollToBottom(true))
  }
}

// ─── Init ──────────────────────────────────────────────────────────────────────

// Component is recreated (via key) when chat changes, so just init once
onMounted(async () => {
  sessionId.value = props.chatId.replace(/^chat-/, '')

  // Initialize cwd from props if provided (for task view)
  if (props.cwd) {
    cwd.value = props.cwd
  }

  if (sessionId.value) {
    await loadChatHistory()
    connectSse()
    startProcessingPoll()
    startGitStatusPoll()
  }
})

onUnmounted(() => {
  disconnectSse()
  stopProcessingPoll()
  stopGitStatusPoll()
})

watch(
  () => messages.value.length,
  () => nextTick(() => scrollToBottom())
)

// Watch for cwd changes to refresh git status
watch(
  () => cwd.value,
  (newCwd) => {
    if (newCwd) {
      checkGitStatus()
    } else {
      gitStatus.value = null
    }
  }
)


// ─── Send Message ─────────────────────────────────────────────────────────────

const sendMessage = async () => {
  if (!inputText.value.trim()) return

  const userMessage = inputText.value
  inputText.value = ''

  await nextTick()
  scrollToBottom(true)

  disconnectSse()

  // Handle pending session - create real session first
  let currentSessionId = sessionId.value

  try {
    await api.sendChatMessage(currentSessionId, userMessage, cwd.value)
    connectSse()
  } catch (err) {
    console.error('Failed to send message:', err)
    messages.value.push({
      id: `error-${Date.now()}`,
      role: 'assistant',
      content: 'Sorry, I encountered an error. Please try again.',
      timestamp: new Date(),
    })
  }
}

const formatTime = (date: Date) => {
  if (!date || isNaN(date.getTime())) return ''
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

const handleShiftEnter = () => {
  // Allow Shift+Enter to insert newline - default textarea behavior
}

// ─── Compact ──────────────────────────────────────────────────────────────────

const isCompacting = ref(false)
const compactError = ref<string | null>(null)

const compactSession = async () => {
  if (!sessionId.value || isCompacting.value) return

  isCompacting.value = true
  compactError.value = null

  try {
    const result = await api.compactSession(sessionId.value)
    if (result.success) {
      // Reload chat history after compaction
      await loadChatHistory()
    } else {
      compactError.value = result.message || "Failed to compact"
    }
  } catch (err) {
    console.error("Failed to compact session:", err)
    compactError.value = "Failed to compact session"
  } finally {
    isCompacting.value = false
  }
}

</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Header -->
    <div class="px-6 py-4 flex items-center gap-3"
      style="border-bottom: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);">
      <div class="w-10 h-10 rounded-full flex items-center justify-center text-lg"
        style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));">
        <span v-if="viewType === 'task'">✓</span>
        <span v-else>💬</span>
      </div>
      <div>
        <h2 class="text-base font-semibold" style="color: var(--semantic-text);">
          {{ viewType === 'task' ? taskInfo.taskName : chatName }}
        </h2>
        <p class="text-xs" style="color: var(--semantic-text-dim);">
          <span v-if="viewType === 'task'">{{ taskInfo.projectName }}</span>
          <span v-else-if="isLoading">Loading...</span>
          <span v-else-if="error" style="color: var(--color-red);">{{ error }}</span>
          <span v-else-if="isStreaming" style="color: var(--color-violet);">Receiving...</span>
          <span v-else-if="isLLMProcessing" style="color: var(--color-orange);">⚡ Processing</span>
          <span v-else-if="compactError" style="color: var(--color-red);">Compact failed</span>
          <span v-else>{{ messages.length }} message{{ messages.length !== 1 ? 's' : '' }}</span>
        </p>
      </div>
      <!-- Compact button in header right -->
      <div class="ml-auto flex items-center gap-2">
        <button @click="compactSession" :disabled="isCompacting || isLoading || isLLMProcessing || !sessionId"
          class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200"
          :class="isCompacting || isLoading || isLLMProcessing || !sessionId ? 'opacity-50 cursor-not-allowed' : 'hover:scale-105'"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
          :title="isCompacting ? 'Compacting...' : 'Compact conversation history'">
          <span v-if="isCompacting" class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
            style="border-color: var(--color-violet); border-top-color: transparent;"></span>
          <span v-else>🗜️</span>
          <span>{{ isCompacting ? 'Compacting...' : 'Compact' }}</span>
        </button>
        <!-- Token usage display -->
        <div v-if="maxTotalTokens > 0 || maxCapacityTotalTokens > 0"
          class="flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
          <span style="color: var(--semantic-text-dim);">Tokens:</span>
          <span style="color: var(--semantic-text);">{{ maxTotalTokens.toLocaleString() }}</span>
          <span v-if="maxCapacityTotalTokens > 0" style="color: var(--semantic-text-dim);">/ {{
            maxCapacityTotalTokens.toLocaleString() }}</span>
          <div v-if="maxCapacityTotalTokens > 0" class="w-16 h-2 rounded-full overflow-hidden"
            style="background-color: var(--color-border);">
            <div class="h-full rounded-full transition-all duration-300" :style="{
              width: Math.min(100, (maxTotalTokens / maxCapacityTotalTokens) * 100) + '%',
              backgroundColor: (maxTotalTokens / maxCapacityTotalTokens) > 0.8 ? 'var(--color-red)' : (maxTotalTokens / maxCapacityTotalTokens) > 0.6 ? 'var(--color-orange)' : 'var(--color-violet)'
            }"></div>
          </div>
        </div>
        <!-- Git status display -->
        <div v-if="gitStatus && gitStatus.is_git_repo" class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          :title="gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'">
          <span>🌿</span>
          <span style="color: var(--semantic-text);">{{ gitStatus.branch || 'main' }}</span>
          <span v-if="!gitStatus.is_clean" style="color: var(--color-orange);">●</span>
          <span v-else style="color: var(--color-green);">✓</span>
        </div>
      </div>
    </div>

    <!-- Messages -->
    <div ref="messagesContainer" class="flex-1 overflow-y-auto" @scroll="handleScroll">
      <!-- Loading More -->
      <div v-if="isLoadingMore" class="flex justify-center py-4">
        <div class="flex items-center gap-2 px-4 py-2 rounded-full" style="background-color: var(--semantic-card-bg);">
          <div class="w-4 h-4 border-2 rounded-full animate-spin"
            style="border-color: var(--color-violet); border-top-color: transparent;"></div>
          <span class="text-sm" style="color: var(--semantic-text-dim);">Loading more...</span>
        </div>
      </div>

      <!-- Empty State -->
      <div v-if="!isLoading && messages.length === 0" class="flex flex-col items-center justify-center h-full px-4">
        <div class="w-16 h-16 rounded-2xl mb-4 flex items-center justify-center text-3xl"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));">
          💬
        </div>
        <h3 class="text-lg font-medium mb-2" style="color: var(--semantic-text);">
          How can I help you?
        </h3>
        <p class="text-sm text-center" style="color: var(--semantic-text-dim);">
          Start a conversation by typing a message below
        </p>
      </div>

      <!-- Message List -->
      <div v-else class="max-w-4xl mx-auto px-4 py-6 space-y-4">
        <!-- Load More Button (when content doesn't overflow) -->
        <div v-if="hasMoreMessages" class="flex justify-center pb-2">
          <button @click="loadChatHistory(true)" :disabled="isLoadingMore"
            class="flex items-center gap-2 px-4 py-2 rounded-full text-sm transition-all duration-200 hover:scale-105"
            :class="isLoadingMore ? 'opacity-50 cursor-not-allowed' : ''"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text);">
            <div v-if="isLoadingMore" class="w-4 h-4 border-2 rounded-full animate-spin"
              style="border-color: var(--color-violet); border-top-color: transparent;"></div>
            <span v-else>↑</span>
            <span>{{ isLoadingMore ? 'Loading...' : 'Load more messages' }}</span>
          </button>
        </div>

        <div v-for="(group, groupIndex) in messageGroups" :key="groupIndex" class="flex gap-3"
          :class="group.role === 'user' ? 'flex-row-reverse' : 'flex-row'">
          <!-- Bubble -->
          <div class="max-w-[90%] min-w-0">
            <div class="px-4 py-2.5 rounded-2xl text-sm leading-relaxed"
              :class="group.role === 'user' ? 'whitespace-pre-wrap break-words' : 'markdown-content'" :style="group.role === 'user'
                ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                : 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border-bottom-left-radius: 6px; border: 1px solid var(--color-border);'
                ">
              <template v-if="group.role === 'user'">
                {{ group.messages[0]!.content }}
              </template>
              <template v-else-if="group.role === 'tool'">
                <div class="tool-sequence">
                  <div v-for="(msg, idx) in group.messages" :key="idx" class="tool-item"
                    :class="idx < group.messages.length - 1 ? 'tool-item-border' : ''">
                    <span v-html="renderResponse(msg.content, msg.role, msg.tool_name)"></span>
                  </div>
                </div>
              </template>
              <template v-else>
                <!-- eslint-disable-next-line vue/no-v-html -->
                <span
                  v-html="renderResponse(group.messages[0]!.content, group.role, group.messages[0]!.tool_name)"></span>
              </template>
            </div>
            <div class="text-xs mt-1 px-1" :class="group.role === 'user' ? 'text-right' : 'text-left'"
              style="color: var(--semantic-text-dim);">
              {{ formatTime(group.timestamp) }}
            </div>
          </div>
        </div>

        <div ref="bottomMarker"></div>
      </div>
    </div>

    <!-- Scroll to bottom button -->
    <Transition name="fade">
      <button v-if="!isAtBottom && messages.length > 0" @click="scrollToBottom(true)"
        class="absolute bottom-24 right-8 p-3 rounded-full shadow-lg transition-all duration-200 hover:scale-105"
        style="background-color: var(--color-violet); color: var(--color-bg);">
        <svg xmlns="http://www.w3.org/2000/svg" class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
        </svg>
      </button>
    </Transition>

    <!-- Input -->
    <div class="p-4" style="border-top: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);">
      <form @submit.prevent="sendMessage" class="max-w-4xl mx-auto flex gap-3 items-end">
        <textarea v-model="inputText" placeholder="Type a message... (Shift+Enter for new line)" rows="3"
          class="flex-1 px-4 py-3 rounded-xl text-sm outline-none transition-all duration-200 resize-none" style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text);
            border: 1px solid var(--color-border);
            min-height: 60px;
            max-height: 200px;
          " @keydown.enter.exact.prevent="sendMessage" @keydown.shift.enter="handleShiftEnter"></textarea>
        <button type="button" @click="sendMessage"
          class="px-5 py-3 rounded-xl font-medium text-sm transition-all duration-200"
          style="background-color: var(--color-violet); color: var(--color-bg);"
          onmouseover="this.style.opacity='0.85';" onmouseout="this.style.opacity='1';">
          Send
        </button>
      </form>
    </div>
  </div>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}

.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

/* Tool output styles */
:deep(.tool-output) {
  padding: 0.5rem 0.75rem;
  border-radius: 0.375rem;
  margin: 0.25rem 0;
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  line-height: 1.5;
}

:deep(.tool-stdout) {
  background-color: rgba(59, 130, 246, 0.1);
  border-left: 3px solid #3b82f6;
  color: var(--semantic-text);
}

:deep(.tool-stderr) {
  background-color: rgba(245, 158, 11, 0.1);
  border-left: 3px solid #f59e0b;
  color: var(--semantic-text);
}

:deep(.tool-success) {
  background-color: rgba(34, 197, 94, 0.1);
  border-left: 3px solid #22c55e;
  color: var(--semantic-text);
}

:deep(.tool-error) {
  background-color: rgba(239, 68, 68, 0.1);
  border-left: 3px solid #ef4444;
  color: var(--semantic-text);
}

:deep(.tool-tag) {
  font-weight: 600;
  margin-right: 0.5rem;
}

:deep(.file-path) {
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  padding: 0.25rem 0.5rem;
  background-color: rgba(139, 92, 246, 0.1);
  border-radius: 0.25rem;
  margin: 0.125rem 0;
  color: var(--semantic-text);
}

:deep(.search-file) {
  font-weight: 600;
  font-size: 0.875rem;
  color: var(--color-violet);
  margin-top: 0.5rem;
}

:deep(.search-line) {
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  padding: 0.125rem 0.5rem;
}

:deep(.line-num) {
  color: var(--semantic-text-dim);
  user-select: none;
  margin-right: 1rem;
  min-width: 3rem;
  display: inline-block;
}

:deep(.line-content) {
  white-space: pre-wrap;
  word-break: break-all;
}

:deep(.file-content) {
  margin-top: 0.25rem;
  font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
  font-size: 0.8125rem;
  line-height: 1.5;
  background-color: rgba(0, 0, 0, 0.04);
  border-radius: 0.375rem;
  padding: 0.5rem 0;
  overflow-x: auto;
}

/* Tool sequence grouping */
:deep(.tool-sequence) {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}

:deep(.tool-item) {
  padding: 0.25rem 0;
}

:deep(.tool-item-border) {
  border-bottom: 1px dashed var(--color-border);
  padding-bottom: 0.5rem;
}

:deep(.tool-item-border:last-child) {
  border-bottom: none;
  padding-bottom: 0;
}

/* Tool inline style */
:deep(.tool-inline) {
  font-size: 0.8rem;
  color: var(--color-violet);
  font-family: monospace;
}

:deep(.tool-inline-result) {
  font-size: 0.8rem;
  color: var(--semantic-text-dim);
  font-family: monospace;
}
</style>

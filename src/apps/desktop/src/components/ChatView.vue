<script setup lang="ts">
import { ref, watch, onMounted, onUnmounted, nextTick, computed, type Ref } from 'vue'
import { marked } from 'marked'
import * as api from '../api'
import { getThinkingTags, isThinkingTags, stripThinkingTags } from '@/helpers'
import FileInput from './FileInput.vue'
import FolderExplorer from './FolderExplorer.vue'
import DiffView from './tool_outputs/DiffView.vue'
import ReadFile from './tool_outputs/ReadFile.vue'
import WriteFile from './tool_outputs/WriteFile.vue'
import UpdateActivity from './UpdateActivity.vue'
import Search from './tool_outputs/Search.vue'
import Glob from './Glob.vue'
import TextReplace from './tool_outputs/TextReplace.vue'
import Bash from './Bash.vue'
import GetSkill from './GetSkill.vue'
import ViewSkill from './tool_outputs/ViewSkill.vue'
import ListSkills from './tool_outputs/ListSkills.vue'
import AddSkill from './tool_outputs/AddSkill.vue'
import EditSkill from './tool_outputs/EditSkill.vue'
import RemoveSkill from './tool_outputs/RemoveSkill.vue'
import RemoveFile from './tool_outputs/RemoveFile.vue'
import SpawnSubAgent from './tool_outputs/SpawnSubAgent.vue'

const props = defineProps<{
  chatId: string
  chatName: string
  type?: 'chat' | 'task'
  cwd?: string
}>()

const emit = defineEmits<{
  'update-chat-id': [oldId: string, newId: string]
}>()

// Check if session is pending (needs creation on first message)
const isPendingSession = computed(() => props.chatId.startsWith('pending-'))

// Active workspace item for FolderExplorer (passed as prop for task view, from store otherwise)

interface Message {
  id: string
  role: 'user' | 'assistant' | 'system' | 'tool'
  content: string
  timestamp: Date
  tool_name?: string
  diffview_before?: string
  diffview_after?: string
  image_urls?: string[]
}

// Escape HTML to prevent XSS
const escapeHtml = (text: string): string => {
  const div = document.createElement('div')
  div.textContent = text
  return div.innerHTML
}

// Copy code content to clipboard
const copyCodeContent = async (codeContent: string) => {
  try {
    await navigator.clipboard.writeText(codeContent)
  } catch (err) {
    console.error('Failed to copy code:', err)
  }
}

// Setup copy buttons on code blocks after render
const setupCodeBlockCopyButtons = () => {
  nextTick(() => {
    const container = messagesContainer.value
    if (!container) return
    const codeBlocks = container.querySelectorAll('.markdown-content pre')
    codeBlocks.forEach((block) => {
      if (block.querySelector('.code-copy-btn')) return // Already has copy button
      const code = block.querySelector('code')
      if (!code) return
      const content = code.textContent || ''
      const btn = document.createElement('button')
      btn.className = 'code-copy-btn'
      btn.innerHTML = '📋'
      btn.title = 'Copy code'
      btn.style.cssText =
        'position: absolute; top: 8px; right: 8px; padding: 4px 8px; font-size: 12px; cursor: pointer; border: none; background: rgba(255,255,255,0.1); border-radius: 4px; opacity: 0.7; transition: opacity 0.2s;'
      btn.onmouseover = () => (btn.style.opacity = '1')
      btn.onmouseout = () => (btn.style.opacity = '0.7')
      btn.onclick = (e) => {
        e.stopPropagation()
        copyCodeContent(content)
      }
      ;(block as HTMLElement).style.position = 'relative'
      block.appendChild(btn)
    })
  })
}

// Format tool output for display (handles <stdout>, <stderr>, <success>, <error> tags)

// Render markdown content to HTML
const renderResponse = (
  content: string,
  role: string,
  tool_name: string | undefined,
  diffviewBefore?: string,
  diffviewAfter?: string,
): string => {
  content = content.trim()
  if (!content) return ''
  try {
    // Strip thinking tags before rendering

    if (role === 'assistant') {
      if (isThinkingTags(content)) {
        return getThinkingTags(content)
      }

      const cleanContent = stripThinkingTags(content)
      return marked.parse(cleanContent, { async: false }) as string
    }

    if (role === 'tool_calls') {
      if (isThinkingTags(content)) {
        return getThinkingTags(content)
      }

      const cleanContent = stripThinkingTags(content)
      return marked.parse(cleanContent, { async: false }) as string
    }

    if (role === 'tool') {
      if (tool_name === 'read_file') {
        const mathPath = content.match(/<path>(.*?)<\/path>/)
        const path = mathPath ? mathPath[1] : null
        const errorArr = content.match(/<error>(.*?)<\/error>/)
        if (errorArr) {
          const errorQuery = errorArr[0]
          return `<span class="tool-inline">${tool_name} → ${path} ${errorQuery}</span>`
        }
        return `<span class="tool-inline">${tool_name} → ${path}</span>`
      }

      if (tool_name === 'search') {
        // Return a simple summary - Search component handles full display
        const fileMatch = content.match(/<file path="([^"]+)" total="(\d+)" count="(\d+)">/)
        if (fileMatch) {
          const matchCount = fileMatch[3]
          return `<span class="tool-inline">search → ${matchCount} matches</span>`
        }

        const warningMatch = content.match(/<warning>(.*?)<\/warning>/)
        if (warningMatch) {
          return `<span class="tool-inline">search → ${warningMatch[1]}</span>`
        }

        const errorMatch = content.match(/<error>(.*?)<\/error>/)
        return `<span class="tool-inline">search → ${errorMatch?.[1] || 'unknown'}</span>`
      }

      if (tool_name === 'glob') {
        // Return a simple summary - Glob component handles full display
        const patternMatch = content.match(/pattern="([^"]+)"/)
        const totalMatch = content.match(/total="(\d+)"/)
        const returnedMatch = content.match(/returned="(\d+)"/)
        const warningMatch = content.match(/<warning>(.*?)<\/warning>/)

        if (warningMatch) {
          return `<span class="tool-inline">glob → ${warningMatch[1]}</span>`
        }

        const pattern = patternMatch ? patternMatch[1] : 'unknown'
        const total = totalMatch ? totalMatch[1] : '0'
        const returned = returnedMatch ? returnedMatch[1] : total
        const resultsText = total !== '0' ? ` (${returned} files)` : ''
        return `<span class="tool-inline">glob → "${pattern}"${resultsText}</span>`
      }

      if (tool_name === 'web_search') {
        const mathQuery = content.match(/<query>(.*?)<\/query>/) || content.match(/"(.*?)"/)
        const query = mathQuery ? mathQuery[1] : null
        return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`
      }

      if (tool_name === 'mcp_context7_query-docs' || tool_name === 'context7') {
        const mathQuery = content.match(/<query>(.*?)<\/query>/)
        const query = mathQuery ? mathQuery[1] : null
        return `<span class="tool-inline">${tool_name} → "${query || 'unknown'}"</span>`
      }

      if (
        tool_name === 'list_skills' ||
        tool_name === 'get_skill' ||
        tool_name === 'add_skill' ||
        tool_name === 'edit_skill' ||
        tool_name === 'view_skill'
      ) {
        return `<span class="tool-inline">${tool_name}</span>`
      }

      if (tool_name === 'spawn_sub_agent') {
        // Parse agent count and summary from XML
        const agentMatches = content.match(/<agent name="([^"]*)" success="([^"]*)">/g)
        const agentCount = agentMatches ? agentMatches.length : 0
        const summaryMatch = content.match(/<summary succeeded="(\d+)" failed="(\d+)" \/>/)
        const succeeded = summaryMatch ? summaryMatch[1] : '0'
        const failed = summaryMatch ? summaryMatch[2] : '0'
        return `<span class="tool-inline">${tool_name} → ${agentCount} agents (${succeeded} succeeded, ${failed} failed)</span>`
      }

      /// Default tool badge for other tools
      return `<span class="tool-inline">${tool_name || 'tool'} → ${escapeHtml(content)}</span>`
    }

    // Default: return escaped content for unhandled roles
    return escapeHtml(content)
  } catch {
    return escapeHtml(content)
  }
}

// Session ID extracted from props on mount
const sessionId = ref('')

// Local LLM processing state - per session
const isLLMProcessing = ref(false)
let processingPollInterval: ReturnType<typeof setInterval> | null = null

const checkLLMProcessing = async () => {
  if (!sessionId.value) {
    isLLMProcessing.value = false
    return
  }
  try {
    const { workers } = await api.getWorkers(undefined, 50, sessionId.value)
    isLLMProcessing.value = workers.length > 0
  } catch {
    isLLMProcessing.value = false
  }
}

const startProcessingPoll = () => {
  checkLLMProcessing()
  if (processingPollInterval) clearInterval(processingPollInterval)
  processingPollInterval = setInterval(checkLLMProcessing, 2000)
}

const stopProcessingPoll = () => {
  if (processingPollInterval) {
    clearInterval(processingPollInterval)
    processingPollInterval = null
  }
}

// Pagination state
const messageCursor = ref<string | null>(null)
const PAGE_SIZE = 40

// SSE connection
const eventSource = ref<EventSource | null>(null)
const queueEventSource = ref<EventSource | null>(null)
const isStreaming = ref(false)
const streamingContent = ref('')

// Queue state
const queuedMessages = ref<api.QueuedMessage[]>([])

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

// Track which tool items are expanded (by index)
const expandedToolIds = ref<Set<string>>(new Set())

// Image preview state
const previewImageUrl = ref<string | null>(null)

const openImagePreview = (url: string) => {
  previewImageUrl.value = url
}

const closeImagePreview = () => {
  previewImageUrl.value = null
}

// Toggle expanded state for a tool item
const toggleToolExpanded = (groupIndex: number, msgIndex: number) => {
  const key = `${groupIndex}-${msgIndex}`
  const newSet = new Set(expandedToolIds.value)
  if (newSet.has(key)) {
    newSet.delete(key)
  } else {
    newSet.add(key)
  }
  expandedToolIds.value = newSet
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
  }),
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
        timestamp: msg.timestamp,
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
      messageCursor.value ?? undefined,
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
      role: msg.role as 'user' | 'assistant' | 'system' | 'tool',
      content: msg.content,
      timestamp: new Date((msg.created_at || 0) * 1000), // Backend sends created_at in seconds
      tool_name: msg.tool_name,
      diffview_before: msg.diffview_before,
      diffview_after: msg.diffview_after,
      image_urls: msg.image_url ? msg.image_url.split('|') : undefined,
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
      setupCodeBlockCopyButtons()
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

const isAlreadyConnectedSSE = ref(false)
const connectSse = () => {
  console.log('[connectSse] Connecting SSE for session:', sessionId.value)
  if (!sessionId.value) return

  if (isAlreadyConnectedSSE.value == false) disconnectSse()

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
        const role =
          (event.role as 'user' | 'assistant' | 'system' | 'tool') ||
          (event.tool_call_id ? 'tool' : 'assistant')

        // Create message using same format as loadChatHistory
        messages.value.push({
          id: event.id || `assistant-${Date.now()}`,
          role: role,
          content: event.content,
          timestamp: new Date(),
          tool_name: event.tool_name,
          diffview_before: event.diffview_before,
          diffview_after: event.diffview_after,
        })
        streamingContent.value = ''
        isStreaming.value = false
        nextTick(() => scrollToBottom(false))
        setupCodeBlockCopyButtons()

        if (event.total_tokens) {
          maxTotalTokens.value = event.total_tokens
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
      isAlreadyConnectedSSE.value = true
    },
  )

  // Connect to queue messages SSE
  queueEventSource.value = api.createQueueMessagesSseConnection(
    sessionId.value,
    (event: api.QueueMessageEvent) => {
      console.log('[QueueMessages SSE] Received event:', event)
      if (event.action === 'queued') {
        // Add new queued message
        queuedMessages.value.push({
          id: event.id ?? `q-${Date.now()}`,
          message: event.message,
        })
      } else if (event.action === 'deleted') {
        // Remove deleted message
        queuedMessages.value = queuedMessages.value.filter((m) => m.message !== event.message)
      }
    },
    (err) => {
      console.error('QueueMessages SSE error:', err)
    },
    () => {
      console.log('QueueMessages SSE connected')
    },
  )
}

const disconnectSse = () => {
  if (eventSource.value) {
    eventSource.value.close()
    eventSource.value = null
  }
  if (queueEventSource.value) {
    queueEventSource.value.close()
    queueEventSource.value = null
  }
  isStreaming.value = false
  streamingContent.value = ''
  // remove any pending streaming placeholder
  messages.value = messages.value.filter((m) => !m.id.startsWith('streaming-'))
}

const updateStreamingMessage = () => {
  console.log('[updateStreamingMessage] streamingContent:', streamingContent.value)
  const existingMsg = messages.value.find(
    (m) => m.role === 'assistant' && m.id.startsWith('streaming-'),
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
    nextTick(() => scrollToBottom(false))
  }
  // Setup copy buttons for any code blocks
  nextTick(() => setupCodeBlockCopyButtons())
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
    startGitStatusPoll()
    startProcessingPoll()

    // Fetch initial queue count
    try {
      const result = await api.getQueuedMessages(sessionId.value)
      queuedMessages.value = result.messages
    } catch (err) {
      console.error('Failed to get queued messages:', err)
    }
  }
})

onUnmounted(() => {
  disconnectSse()
  stopGitStatusPoll()
  stopProcessingPoll()
})

watch(
  () => messages.value.length,
  () => nextTick(() => scrollToBottom()),
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
  },
)

// Watch for session changes to restart processing poll
watch(
  () => sessionId.value,
  (newSessionId, oldSessionId) => {
    if (newSessionId !== oldSessionId) {
      stopProcessingPoll()
      if (newSessionId) {
        startProcessingPoll()
      } else {
        isLLMProcessing.value = false
      }
    }
  },
)

// ─── Send Message ─────────────────────────────────────────────────────────────

const handleFileInputSubmit = async (userMessage: string, files?: File[]) => {
  await nextTick()
  scrollToBottom(true)

  // Handle pending session - create real session first
  let currentSessionId = sessionId.value

  // Convert files to base64 image_urls
  let imageUrls: string[] = []
  if (files && files.length > 0) {
    const fileToBase64 = (file: File): Promise<string> => {
      return new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result as string)
        reader.onerror = reject
        reader.readAsDataURL(file)
      })
    }
    imageUrls = await Promise.all(files.map((f) => fileToBase64(f)))
  }

  try {
    await api.sendChatMessage(currentSessionId, userMessage, cwd.value, imageUrls)
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
      compactError.value = result.message || 'Failed to compact'
    }
  } catch (err) {
    console.error('Failed to compact session:', err)
    compactError.value = 'Failed to compact session'
  } finally {
    isCompacting.value = false
  }
}
</script>

<template>
  <div class="flex h-full w-full">
    <!-- Main Chat Content -->
    <div class="flex flex-col h-full flex-1 min-w-0">
      <!-- Messages -->
      <div
        ref="messagesContainer"
        tabindex="0"
        class="flex-1 overflow-y-auto"
        @scroll="handleScroll"
      >
        <!-- Loading More -->
        <div v-if="isLoadingMore" class="flex justify-center py-4">
          <div
            class="flex items-center gap-2 px-4 py-2 rounded-full"
            style="background-color: var(--semantic-card-bg)"
          >
            <div
              class="w-4 h-4 border-2 rounded-full animate-spin"
              style="border-color: var(--color-violet); border-top-color: transparent"
            ></div>
            <span class="text-sm" style="color: var(--semantic-text-dim)">Loading more...</span>
          </div>
        </div>

        <!-- Empty State -->
        <div
          v-if="!isLoading && messages.length === 0"
          class="flex flex-col items-center justify-center h-full px-4"
        >
          <div
            class="w-16 h-16 rounded-2xl mb-4 flex items-center justify-center text-3xl"
            style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue))"
          >
            💬
          </div>
          <h3 class="text-lg font-medium mb-2" style="color: var(--semantic-text)">
            How can I help you?
          </h3>
          <p class="text-sm text-center" style="color: var(--semantic-text-dim)">
            Start a conversation by typing a message below
          </p>
        </div>

        <!-- Message List -->
        <div v-else class="max-w-4xl mx-auto px-4 py-6 space-y-4">
          <!-- Load More Button (when content doesn't overflow) -->
          <div v-if="hasMoreMessages" class="flex justify-center pb-2">
            <button
              @click="loadChatHistory(true)"
              :disabled="isLoadingMore"
              class="flex items-center gap-2 px-4 py-2 rounded-full text-sm transition-all duration-200 hover:scale-105"
              :class="isLoadingMore ? 'opacity-50 cursor-not-allowed' : ''"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            >
              <div
                v-if="isLoadingMore"
                class="w-4 h-4 border-2 rounded-full animate-spin"
                style="border-color: var(--color-violet); border-top-color: transparent"
              ></div>
              <span v-else>↑</span>
              <span>{{ isLoadingMore ? 'Loading...' : 'Load more messages' }}</span>
            </button>
          </div>

          <div
            v-for="(group, groupIndex) in messageGroups"
            :key="groupIndex"
            class="flex gap-3"
            :class="group.role === 'user' ? 'flex-row-reverse' : 'flex-row'"
          >
            <!-- Bubble -->
            <div class="max-w-[90%] min-w-0">
              <div
                class="px-4 py-2.5 rounded-2xl text-sm leading-relaxed"
                role="button"
                tabindex="0"
                :class="
                  group.role === 'user' ? 'whitespace-pre-wrap break-words' : 'markdown-content'
                "
                :style="
                  group.role === 'user'
                    ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                    : 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border-bottom-left-radius: 6px; border: 1px solid var(--color-border);'
                "
              >
                <template v-if="group.role === 'user'">
                  <div
                    v-if="
                      group.messages[0]?.image_urls && group.messages[0]!.image_urls!.length > 0
                    "
                    class="mb-2"
                  >
                    <div class="flex flex-wrap gap-2">
                      <img
                        v-for="(imgUrl, imgIdx) in group.messages[0]!.image_urls"
                        :key="imgIdx"
                        :src="imgUrl"
                        alt="Attached image"
                        class="max-w-full rounded-lg max-h-64 cursor-pointer hover:opacity-90"
                        @click="openImagePreview(imgUrl)"
                      />
                    </div>
                  </div>
                  {{ group.messages[0]!.content }}
                </template>
                <template v-else-if="group.role === 'tool'">
                  <div class="tool-sequence">
                    <div
                      v-for="(msg, idx) in group.messages"
                      :key="idx"
                      class="tool-item"
                      :class="idx < group.messages.length - 1 ? 'tool-item-border' : ''"
                    >
                      <!-- ReadFile component for read_file tool -->
                      <ReadFile
                        v-if="msg.tool_name === 'read_file'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- WriteFile component for write_file tool -->
                      <WriteFile
                        v-else-if="msg.tool_name === 'write_file'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- UpdateActivity component for update_activity tool -->
                      <UpdateActivity
                        v-else-if="msg.tool_name === 'update_activity'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- Search component for search tool -->
                      <Search
                        v-else-if="msg.tool_name === 'search'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- Glob component for glob tool -->
                      <Glob v-else-if="msg.tool_name === 'glob'" :content="msg.content" />
                      <!-- TextReplace component for text_replace tool -->
                      <TextReplace
                        v-else-if="msg.tool_name === 'text_replace'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                        :diffview-before="msg.diffview_before"
                        :diffview-after="msg.diffview_after"
                      />
                      <!-- Bash component for bash tool -->
                      <Bash
                        v-else-if="msg.tool_name === 'bash' || msg.tool_name === 'run_command'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- GetSkill component for get_skill tool -->
                      <GetSkill
                        v-else-if="msg.tool_name === 'get_skill'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- ViewSkill component for view_skill tool -->
                      <ViewSkill
                        v-else-if="msg.tool_name === 'view_skill'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- ListSkills component for list_skills tool -->
                      <ListSkills
                        v-else-if="msg.tool_name === 'list_skills'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- AddSkill component for add_skill tool -->
                      <AddSkill
                        v-else-if="msg.tool_name === 'add_skill'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- EditSkill component for edit_skill tool -->
                      <EditSkill
                        v-else-if="msg.tool_name === 'edit_skill'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- RemoveSkill component for remove_skill tool -->
                      <RemoveSkill
                        v-else-if="msg.tool_name === 'remove_skill'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- RemoveFile component for remove_file tool -->
                      <RemoveFile
                        v-else-if="msg.tool_name === 'remove_file'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- SpawnSubAgent component for spawn_sub_agent tool -->
                      <SpawnSubAgent
                        v-else-if="msg.tool_name === 'spawn_sub_agent'"
                        :content="msg.content"
                        :expanded="expandedToolIds.has(`${groupIndex}-${idx}`)"
                      />
                      <!-- Default tool rendering for other tools -->
                      <div v-else class="tool-expandable">
                        <button
                          class="tool-summary"
                          @click="toggleToolExpanded(groupIndex, idx)"
                          :style="[
                            'cursor: pointer; padding: 2px 4px; border-radius: 4px; transition: background-color 0.15s; text-align: left; width: 100%; border: none; background: transparent; font: inherit; color: inherit;',
                            expandedToolIds.has(`${groupIndex}-${idx}`)
                              ? 'border-bottom: 1px dashed var(--color-border);'
                              : '',
                          ]"
                        >
                          <span
                            v-html="
                              renderResponse(
                                msg.content,
                                msg.role,
                                msg.tool_name,
                                msg.diffview_before,
                                msg.diffview_after,
                              )
                            "
                          ></span>
                        </button>
                        <div
                          v-if="expandedToolIds.has(`${groupIndex}-${idx}`)"
                          class="tool-full-content"
                        >
                          <!-- <pre class="tool-content-pre">{{ msg.content.trim() }}</pre> -->
                          <!-- Show diff view when expanded and diff data available -->
                          <DiffView
                            v-if="msg.diffview_before && msg.diffview_after"
                            :before="msg.diffview_before"
                            :after="msg.diffview_after"
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                </template>
                <template v-else>
                  <!-- eslint-disable-next-line vue/no-v-html -->
                  <span
                    v-html="
                      renderResponse(
                        group.messages[0]!.content,
                        group.role,
                        group.messages[0]!.tool_name,
                        group.messages[0]!.diffview_before,
                        group.messages[0]!.diffview_after,
                      )
                    "
                  ></span>
                </template>
              </div>
              <div
                class="text-xs mt-1 px-1"
                :class="group.role === 'user' ? 'text-right' : 'text-left'"
                style="color: var(--semantic-text-dim)"
              >
                {{ formatTime(group.timestamp) }}
              </div>
            </div>
          </div>

          <div ref="bottomMarker"></div>
        </div>
      </div>

      <!-- Scroll to bottom button -->
      <Transition name="fade">
        <button
          v-if="!isAtBottom && messages.length > 0"
          @click="scrollToBottom(true)"
          class="absolute bottom-24 right-8 p-3 rounded-full shadow-lg transition-all duration-200 hover:scale-105"
          style="background-color: var(--color-violet); color: var(--color-bg)"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 14l-7 7m0 0l-7-7m7 7V3"
            />
          </svg>
        </button>
      </Transition>

      <!-- Input -->
      <div
        class="p-4"
        style="
          border-top: 1px solid var(--color-border);
          background-color: var(--semantic-sidebar-bg);
        "
      >
        <div class="max-w-4xl mx-auto">
          <FileInput
            :cwd="cwd"
            :queuedMessages="queuedMessages"
            :isLoading="isLoading"
            :isLLMProcessing="isLLMProcessing"
            @submit="handleFileInputSubmit"
            @files-selected="handleFileInputSubmit"
          />
          <!-- Status bar: compact, tokens, git branch below input -->
          <div class="flex items-center gap-2 mt-3">
            <!-- Compact button -->
            <button
              @click="compactSession"
              :disabled="isCompacting || isLoading || isLLMProcessing || !sessionId"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200"
              :class="
                isCompacting || isLoading || isLLMProcessing || !sessionId
                  ? 'opacity-50 cursor-not-allowed'
                  : 'hover:scale-105'
              "
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :title="isCompacting ? 'Compacting...' : 'Compact conversation history'"
            >
              <span
                v-if="isCompacting"
                class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
                style="border-color: var(--color-violet); border-top-color: transparent"
              ></span>
              <span v-else>🗜️</span>
              <span>{{ isCompacting ? 'Compacting...' : 'Compact' }}</span>
            </button>
            <!-- Token usage display -->
            <div
              v-if="maxTotalTokens > 0 || maxCapacityTotalTokens > 0"
              class="flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
            >
              <span style="color: var(--semantic-text-dim)">Tokens:</span>
              <span style="color: var(--semantic-text)">{{ maxTotalTokens.toLocaleString() }}</span>
              <span v-if="maxCapacityTotalTokens > 0" style="color: var(--semantic-text-dim)"
                >/ {{ maxCapacityTotalTokens.toLocaleString() }}</span
              >
              <div
                v-if="maxCapacityTotalTokens > 0"
                class="w-16 h-2 rounded-full overflow-hidden"
                style="background-color: var(--color-border)"
              >
                <div
                  class="h-full rounded-full transition-all duration-300"
                  :style="{
                    width: Math.min(100, (maxTotalTokens / maxCapacityTotalTokens) * 100) + '%',
                    backgroundColor:
                      maxTotalTokens / maxCapacityTotalTokens > 0.8
                        ? 'var(--color-red)'
                        : maxTotalTokens / maxCapacityTotalTokens > 0.6
                          ? 'var(--color-orange)'
                          : 'var(--color-violet)',
                  }"
                ></div>
              </div>
            </div>
            <!-- Git status display -->
            <div
              v-if="gitStatus && gitStatus.is_git_repo"
              class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
              "
              :title="
                gitStatus.status === 'clean' ? 'Working tree clean' : 'Working tree has changes'
              "
            >
              <span>🌿</span>
              <span style="color: var(--semantic-text)">{{ gitStatus.branch || 'main' }}</span>
              <span v-if="!gitStatus.is_clean" style="color: var(--color-orange)">●</span>
              <span v-else style="color: var(--color-green)">✓</span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Image Preview Popup -->
    <Teleport to="body">
      <div v-if="previewImageUrl" class="image-preview-overlay" @click="closeImagePreview">
        <div class="image-preview-content" @click.stop>
          <button type="button" class="image-preview-close" @click="closeImagePreview">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
          <img :src="previewImageUrl" alt="Preview" class="image-preview-img" />
        </div>
      </div>
    </Teleport>
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
  overflow-x: hidden;
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

/* Code block copy button */
:deep(.markdown-content pre) {
  overflow-x: auto;
}

:deep(.markdown-content pre:hover .code-copy-btn) {
  opacity: 1;
}

/* Image preview popup */
.image-preview-overlay {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background-color: rgba(0, 0, 0, 0.85);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 9999;
  padding: 20px;
}

.image-preview-content {
  position: relative;
  max-width: 90vw;
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  align-items: center;
}

.image-preview-close {
  position: absolute;
  top: -40px;
  right: 0;
  background: none;
  border: none;
  color: white;
  cursor: pointer;
  padding: 8px;
  opacity: 0.7;
  transition: opacity 0.2s;
}

.image-preview-close:hover {
  opacity: 1;
}

.image-preview-img {
  max-width: 100%;
  max-height: calc(90vh - 60px);
  object-fit: contain;
  border-radius: 8px;
}
</style>

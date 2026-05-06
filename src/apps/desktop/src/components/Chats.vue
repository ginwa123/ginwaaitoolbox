<script setup lang="ts">
import { ref, nextTick, onMounted } from 'vue'

interface Message {
  id: string
  role: 'user' | 'assistant'
  content: string
  timestamp: Date
  isStreaming?: boolean
}

const messages = ref<Message[]>([
  {
    id: '1',
    role: 'assistant',
    content: 'Hello! I am your AI coding assistant. How can I help you today?',
    timestamp: new Date()
  }
])

const inputText = ref('')
const isLoading = ref(false)
const isAtBottom = ref(true)
const messagesContainer = ref<HTMLElement | null>(null)

// Scroll to bottom of messages
const scrollToBottom = async (force = false) => {
  await nextTick()
  if (messagesContainer.value) {
    if (force || isAtBottom.value) {
      messagesContainer.value.scrollTop = messagesContainer.value.scrollHeight
    }
  }
}

// Handle scroll events
const handleScroll = () => {
  if (!messagesContainer.value) return

  const container = messagesContainer.value
  const scrollTop = container.scrollTop
  const scrollHeight = container.scrollHeight
  const clientHeight = container.clientHeight

  // Check if user is at bottom (within 100px tolerance)
  isAtBottom.value = scrollHeight - scrollTop - clientHeight < 100
}

// Watch for messages changes to auto-scroll
const unwatch = watch(messages, () => {
  nextTick(() => scrollToBottom())
}, { deep: true })

// Watch for streaming state changes
watch(() => messages.value.some(m => m.isStreaming), (isStreaming) => {
  if (isStreaming) {
    nextTick(() => scrollToBottom(true))
  }
})

// Helper to watch messages
import { watch } from 'vue'

const sendMessage = () => {
  if (!inputText.value.trim()) return

  // Add user message
  const userMsg: Message = {
    id: `user-${Date.now()}`,
    role: 'user',
    content: inputText.value,
    timestamp: new Date()
  }
  messages.value.push(userMsg)

  // Clear input
  const userMessage = inputText.value
  inputText.value = ''

  // Scroll to bottom after user message
  nextTick(() => scrollToBottom(true))

  // Create streaming assistant message
  const streamMsg: Message = {
    id: `assistant-${Date.now()}`,
    role: 'assistant',
    content: '',
    timestamp: new Date(),
    isStreaming: true
  }
  messages.value.push(streamMsg)

  // Simulate streaming response
  simulateStreaming(streamMsg, `You said: "${userMessage}". This is a demo streaming response. `)
}

const simulateStreaming = async (msg: Message, response: string) => {
  isLoading.value = true

  // Simulate character-by-character streaming
  for (let i = 0; i < response.length; i++) {
    // Check if message was removed (e.g., new message sent)
    if (!messages.value.includes(msg)) break

    msg.content += response[i]

    // Scroll during streaming
    await nextTick()
    if (msg.isStreaming) {
      scrollToBottom(true)
    }

    // Random delay to simulate network latency
    await new Promise(resolve => setTimeout(resolve, 20 + Math.random() * 30))
  }

  // Mark streaming as complete
  msg.isStreaming = false
  isLoading.value = false

  await nextTick()
  scrollToBottom(true)
}

const formatTime = (date: Date) => {
  if (!date || isNaN(date.getTime())) {
    return ''
  }
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

onMounted(() => {
  nextTick(() => scrollToBottom(true))
})
</script>

<template>
  <div class="flex flex-col h-full relative">
    <!-- Messages List - Centered & Constrained -->
    <div
      ref="messagesContainer"
      class="flex-1 overflow-y-auto"
      @scroll="handleScroll"
    >
      <div class="max-w-4xl mx-auto px-4 py-6 space-y-4">
        <div
          v-for="message in messages"
          :key="message.id"
          class="flex gap-3"
          :class="message.role === 'user' ? 'flex-row-reverse' : 'flex-row'"
        >
          <!-- Avatar -->
          <div
            class="w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0 text-sm font-medium"
            :style="message.role === 'user'
              ? 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);'
              : 'background: linear-gradient(135deg, var(--color-green), var(--color-aqua)); color: var(--color-bg);'"
          >
            {{ message.role === 'user' ? 'U' : 'AI' }}
            <!-- Streaming indicator -->
            <span v-if="message.isStreaming" class="absolute -bottom-1 -right-1">
              <span class="w-2 h-2 bg-green-400 rounded-full animate-pulse"></span>
            </span>
          </div>

          <!-- Message Bubble -->
          <div class="max-w-[90%]">
            <div
              class="px-4 py-2.5 rounded-2xl text-sm leading-relaxed whitespace-pre-wrap"
              :style="message.role === 'user'
                ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                : 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border-bottom-left-radius: 6px; border: 1px solid var(--color-border);'"
            >
              {{ message.content }}
              <span v-if="message.isStreaming" class="inline-block w-2 h-4 ml-1 animate-pulse" style="background-color: var(--color-violet);"></span>
            </div>
            <div
              class="text-xs mt-1 px-1 flex items-center gap-2"
              :class="message.role === 'user' ? 'flex-row-reverse' : 'flex-row'"
            >
              <span style="color: var(--semantic-text-dim);">
                {{ formatTime(message.timestamp) }}
              </span>
              <span v-if="message.isStreaming" class="text-xs" style="color: var(--color-violet);">
                Streaming...
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Scroll to bottom button -->
    <Transition name="fade">
      <button
        v-if="!isAtBottom && messages.length > 0"
        @click="scrollToBottom(true)"
        class="absolute bottom-24 right-8 p-3 rounded-full shadow-lg transition-all duration-200 hover:scale-105"
        style="background-color: var(--color-violet); color: var(--color-bg);"
      >
        <svg xmlns="http://www.w3.org/2000/svg" class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
        </svg>
      </button>
    </Transition>

    <!-- Input Area - Centered -->
    <div
      class="p-4"
      style="border-top: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
    >
      <form @submit.prevent="sendMessage" class="max-w-4xl mx-auto flex gap-3">
        <input
          v-model="inputText"
          type="text"
          placeholder="Type a message..."
          class="flex-1 px-4 py-3 rounded-xl text-sm outline-none transition-all duration-200"
          style="
            background-color: var(--semantic-card-bg);
            color: var(--semantic-text);
            border: 1px solid var(--color-border);
          "
          :disabled="isLoading"
        />
        <button
          type="submit"
          class="px-5 py-3 rounded-xl font-medium text-sm transition-all duration-200"
          style="background-color: var(--color-violet); color: var(--color-bg);"
          onmouseover="this.style.opacity='0.85';"
          onmouseout="this.style.opacity='1';"
          :disabled="isLoading"
          :style="{ opacity: isLoading ? 0.5 : 1 }"
        >
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
</style>

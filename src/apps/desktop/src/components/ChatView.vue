<script setup lang="ts">
import { ref } from 'vue'

const props = defineProps<{
  chatId: string
  chatName: string
}>()

interface Message {
  id: string
  role: 'user' | 'assistant'
  content: string
  timestamp: Date
}

const messages = ref<Message[]>([
  {
    id: '1',
    role: 'assistant',
    content: `Welcome to "${props.chatName}"! How can I help you today?`,
    timestamp: new Date()
  }
])

const inputText = ref('')

const sendMessage = () => {
  if (!inputText.value.trim()) return

  messages.value.push({
    id: Date.now().toString(),
    role: 'user',
    content: inputText.value,
    timestamp: new Date()
  })

  const userMessage = inputText.value
  inputText.value = ''

  setTimeout(() => {
    messages.value.push({
      id: (Date.now() + 1).toString(),
      role: 'assistant',
      content: `You said: "${userMessage}". This is a demo response.`,
      timestamp: new Date()
    })
  }, 500)
}

const formatTime = (date: Date) => {
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Messages List -->
    <div class="flex-1 overflow-y-auto">
      <div class="max-w-2xl mx-auto px-4 py-6 space-y-4">
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
          </div>

          <!-- Message Bubble -->
          <div class="max-w-[80%]">
            <div 
              class="px-4 py-2.5 rounded-2xl text-sm leading-relaxed"
              :style="message.role === 'user'
                ? 'background-color: var(--color-blue-1); color: var(--semantic-text); border-bottom-right-radius: 6px;'
                : 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border-bottom-left-radius: 6px; border: 1px solid var(--color-border);'"
            >
              {{ message.content }}
            </div>
            <div 
              class="text-xs mt-1 px-1"
              :class="message.role === 'user' ? 'text-right' : 'text-left'"
              style="color: var(--semantic-text-dim);"
            >
              {{ formatTime(message.timestamp) }}
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Input Area -->
    <div 
      class="p-4"
      style="border-top: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
    >
      <form @submit.prevent="sendMessage" class="max-w-2xl mx-auto flex gap-3">
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
        />
        <button
          type="submit"
          class="px-5 py-3 rounded-xl font-medium text-sm transition-all duration-200"
          style="background-color: var(--color-violet); color: var(--color-bg);"
          onmouseover="this.style.opacity='0.85';"
          onmouseout="this.style.opacity='1';"
        >
          Send
        </button>
      </form>
    </div>
  </div>
</template>
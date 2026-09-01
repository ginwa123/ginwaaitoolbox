<script setup lang="ts">
import { ref, computed, onMounted, watch } from 'vue'
import { getChats, getLlmHistory, type LlmHistoryInspectorResponse, type LlmHistoryChainMessage } from '../../api'

type CurlTab = 'anthropic' | 'openai' | 'openai_response'

const sessions = ref<{ id: string; name: string }[]>([])
const sessionsLoading = ref(false)
const sessionsError = ref<string | null>(null)
const searchQuery = ref('')
const selectedSessionId = ref<string>('')
const dropdownOpen = ref(false)

const chain = ref<LlmHistoryChainMessage[]>([])
const curl = ref<LlmHistoryInspectorResponse['curl'] | null>(null)
const bodies = ref<LlmHistoryInspectorResponse['bodies'] | null>(null)
const model = ref('')
const urlStyle = ref('')
const loading = ref(false)
const error = ref<string | null>(null)

const activeCurlTab = ref<CurlTab>('anthropic')
const copiedCurl = ref(false)
const copiedJson = ref(false)
const expandedMessages = ref<Set<number>>(new Set())

// Session picker: filtered list
const filteredSessions = computed(() => {
  const q = searchQuery.value.trim().toLowerCase()
  if (!q) return sessions.value
  return sessions.value.filter(
    s => s.name.toLowerCase().includes(q) || s.id.toLowerCase().includes(q),
  )
})

const selectedSessionName = computed(() => {
  const found = sessions.value.find(s => s.id === selectedSessionId.value)
  return found ? found.name : selectedSessionId.value
})

// Chain viewer helpers
const roleBadgeClass = (role: string): string => {
  switch (role) {
    case 'system': return 'bg-zinc-600 text-zinc-100'
    case 'user': return 'bg-blue-600 text-white'
    case 'assistant': return 'bg-emerald-600 text-white'
    case 'tool': return 'bg-amber-600 text-white'
    default: return 'bg-zinc-600 text-zinc-100'
  }
}

const isExpanded = (idx: number): boolean => expandedMessages.value.has(idx)

const toggleExpand = (idx: number) => {
  if (expandedMessages.value.has(idx)) {
    expandedMessages.value.delete(idx)
  } else {
    expandedMessages.value.add(idx)
  }
}

const truncateContent = (content: string, limit = 2000): { text: string; truncated: boolean } => {
  if (content.length <= limit) return { text: content, truncated: false }
  return { text: content.slice(0, limit), truncated: true }
}

// Curl tab helpers
const activeCurlString = computed(() => {
  if (!curl.value) return ''
  return curl.value[activeCurlTab.value] ?? ''
})

const activeBodyPretty = computed(() => {
  if (!bodies.value) return ''
  const body = bodies.value[activeCurlTab.value]
  if (body == null) return ''
  try {
    return JSON.stringify(body, null, 2)
  } catch {
    return String(body)
  }
})

const copyCurl = async () => {
  const text = activeCurlString.value
  if (!text) return
  await navigator.clipboard.writeText(text)
  copiedCurl.value = true
  setTimeout(() => { copiedCurl.value = false }, 2000)
}

const copyJson = async () => {
  const text = activeBodyPretty.value
  if (!text) return
  await navigator.clipboard.writeText(text)
  copiedJson.value = true
  setTimeout(() => { copiedJson.value = false }, 2000)
}

// Fetch sessions
const fetchSessions = async () => {
  sessionsLoading.value = true
  sessionsError.value = null
  try {
    const data = await getChats('updated_at', 'desc', 50)
    sessions.value = (data.sessions || []).map(s => ({
      id: s.session_id,
      name: s.session_name || 'New Chat',
    }))
    // Default to most-recent (first in list)
    if (sessions.value.length > 0 && !selectedSessionId.value) {
      const first = sessions.value[0]
      if (first) {
        selectedSessionId.value = first.id
      }
    }
  } catch (e) {
    sessionsError.value = e instanceof Error ? e.message : String(e)
  } finally {
    sessionsLoading.value = false
  }
}

// Fetch history for selected session
const fetchHistory = async (sessionId: string) => {
  if (!sessionId) return
  loading.value = true
  error.value = null
  chain.value = []
  curl.value = null
  bodies.value = null
  expandedMessages.value = new Set()
  try {
    const data = await getLlmHistory(sessionId)
    chain.value = data.chain ?? []
    curl.value = data.curl ?? null
    bodies.value = data.bodies ?? null
    model.value = data.model ?? ''
    urlStyle.value = data.url_style ?? ''
    // System message expanded by default, others collapsed
    const expanded = new Set<number>()
    chain.value.forEach((msg, idx) => {
      if (msg.role === 'system') expanded.add(idx)
    })
    expandedMessages.value = expanded
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    // Try to extract body from ApiError
    const apiErr = e as { body?: string; status?: number }
    if (apiErr.body) {
      try {
        const parsed = JSON.parse(apiErr.body)
        error.value = parsed.error || msg
      } catch {
        error.value = msg
      }
    } else {
      error.value = msg
    }
  } finally {
    loading.value = false
  }
}

const selectSession = (id: string) => {
  selectedSessionId.value = id
  dropdownOpen.value = false
  searchQuery.value = ''
}

watch(selectedSessionId, (newId) => {
  if (newId) fetchHistory(newId)
})

onMounted(() => {
  fetchSessions()
})

// Expose for tests
defineExpose({ fetchSessions, fetchHistory })
</script>

<template>
  <div class="flex flex-col gap-6" data-testid="llm-history-settings">
    <!-- Session Picker -->
    <div class="shrink-0">
      <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text);">Session</label>
      <div class="relative">
        <button
          data-testid="session-picker-trigger"
          class="w-full flex items-center justify-between gap-2 px-3 py-2.5 rounded-lg text-sm text-left"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
          @click="dropdownOpen = !dropdownOpen"
        >
          <span class="truncate">
            <template v-if="sessionsLoading">Loading sessions…</template>
            <template v-else-if="selectedSessionId">{{ selectedSessionName }} <span class="opacity-50 text-xs">({{ selectedSessionId }})</span></template>
            <template v-else-if="sessions.length === 0">No sessions</template>
            <template v-else>Select a session</template>
          </span>
          <span class="shrink-0 text-xs" style="color: var(--semantic-text-muted);">▾</span>
        </button>

        <!-- Dropdown -->
        <div
          v-if="dropdownOpen"
          data-testid="session-picker-dropdown"
          class="absolute z-10 mt-1 w-full rounded-lg shadow-lg overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <!-- Search input -->
          <div class="p-2" style="border-bottom: 1px solid var(--color-border);">
            <input
              v-model="searchQuery"
              data-testid="session-picker-search"
              type="text"
              placeholder="Search sessions…"
              class="w-full px-3 py-1.5 rounded text-sm outline-none"
              style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            />
          </div>
          <!-- Session list -->
          <div class="max-h-48 overflow-y-auto">
            <button
              v-for="s in filteredSessions"
              :key="s.id"
              data-testid="session-picker-option"
              class="w-full text-left px-3 py-2 text-sm hover:opacity-80 transition-opacity"
              :style="s.id === selectedSessionId ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);' : 'color: var(--semantic-text);'"
              @click="selectSession(s.id)"
            >
              <span class="font-medium">{{ s.name }}</span>
              <span class="ml-2 text-xs opacity-50">{{ s.id }}</span>
            </button>
            <div
              v-if="filteredSessions.length === 0"
              class="px-3 py-4 text-sm text-center"
              style="color: var(--semantic-text-muted);"
            >
              No matching sessions
            </div>
          </div>
        </div>
      </div>
      <div v-if="sessionsError" class="mt-2 text-sm" style="color: var(--color-red);">{{ sessionsError }}</div>
      <div v-if="model || urlStyle" class="mt-2 flex gap-2 text-xs" style="color: var(--semantic-text-muted);">
        <span v-if="model" data-testid="history-model">model: {{ model }}</span>
        <span v-if="urlStyle" data-testid="history-url-style">url_style: {{ urlStyle }}</span>
      </div>
    </div>

    <!-- Loading -->
    <div v-if="loading" data-testid="history-loading" class="flex items-center justify-center py-8">
      <div class="w-6 h-6 border-2 rounded-full animate-spin" style="border-color: var(--color-border); border-top-color: var(--color-violet);"></div>
      <span class="ml-3 text-sm" style="color: var(--semantic-text-muted);">Loading history…</span>
    </div>

    <!-- Error -->
    <div
      v-else-if="error"
      data-testid="history-error"
      class="rounded-lg px-4 py-3 text-sm"
      style="background-color: rgba(239, 68, 68, 0.1); border: 1px solid rgba(239, 68, 68, 0.3); color: var(--color-red);"
    >
      {{ error }}
    </div>

    <!-- Empty -->
    <div
      v-else-if="!loading && chain.length === 0 && selectedSessionId"
      data-testid="history-empty"
      class="rounded-lg px-4 py-8 text-sm text-center"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);"
    >
      No messages yet for this session
    </div>

    <!-- Chain Viewer -->
    <div v-else-if="chain.length > 0" data-testid="chain-viewer" class="flex flex-col gap-3">
      <h3 class="text-sm font-semibold" style="color: var(--semantic-text);">Chain ({{ chain.length }} messages)</h3>
      <div
        v-for="(msg, idx) in chain"
        :key="idx"
        data-testid="chain-card"
        :data-role="msg.role"
        class="rounded-lg overflow-hidden"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      >
        <!-- Card header -->
        <button
          class="w-full flex items-center gap-2 px-3 py-2 text-left hover:opacity-80 transition-opacity"
          :data-testid="`chain-card-header-${idx}`"
          @click="toggleExpand(idx)"
        >
          <span
            class="px-2 py-0.5 rounded text-xs font-semibold uppercase shrink-0"
            :class="roleBadgeClass(msg.role)"
            :data-testid="`chain-card-role-${idx}`"
          >{{ msg.role }}</span>
          <span v-if="msg.id" class="text-xs truncate" style="color: var(--semantic-text-muted);">{{ msg.id }}</span>
          <span v-if="msg.created_at" class="text-xs shrink-0" style="color: var(--semantic-text-muted);">{{ msg.created_at }}</span>
          <span class="ml-auto text-xs shrink-0" style="color: var(--semantic-text-muted);">{{ isExpanded(idx) ? '▾' : '▸' }}</span>
        </button>

        <!-- Card body -->
        <div v-if="isExpanded(idx)" class="px-3 pb-3 space-y-3" style="border-top: 1px solid var(--color-border);">
          <!-- Content -->
          <div v-if="msg.content" class="pt-3">
            <div class="text-xs font-medium mb-1" style="color: var(--semantic-text-muted);">content</div>
            <pre
              class="text-sm whitespace-pre-wrap break-words rounded p-3 max-h-96 overflow-y-auto"
              style="background-color: var(--semantic-content-bg); color: var(--semantic-text);"
              :data-testid="`chain-card-content-${idx}`"
            >{{ truncateContent(msg.content).text }}<span v-if="truncateContent(msg.content).truncated" style="color: var(--semantic-text-muted);"> … (truncated, {{ msg.content.length }} chars total)</span></pre>
          </div>

          <!-- Reasoning content (amber block) -->
          <div v-if="msg.reasoning_content" class="rounded p-3" style="background-color: rgba(245, 158, 11, 0.08); border: 1px solid rgba(245, 158, 11, 0.2);">
            <div class="text-xs font-medium mb-1" style="color: #f59e0b;">reasoning_content</div>
            <pre
              class="text-sm whitespace-pre-wrap break-words"
              style="color: var(--semantic-text);"
              :data-testid="`chain-card-reasoning-${idx}`"
            >{{ msg.reasoning_content }}</pre>
          </div>

          <!-- Tool calls -->
          <div v-if="msg.tool_calls && msg.tool_calls.length > 0">
            <div class="text-xs font-medium mb-1" style="color: var(--semantic-text-muted);">tool_calls</div>
            <pre
              class="text-xs whitespace-pre-wrap break-words rounded p-3 max-h-64 overflow-y-auto"
              style="background-color: var(--semantic-content-bg); color: var(--semantic-text);"
              :data-testid="`chain-card-tool-calls-${idx}`"
            >{{ JSON.stringify(msg.tool_calls, null, 2) }}</pre>
          </div>

          <!-- Tool call id / name -->
          <div v-if="msg.tool_call_id || msg.tool_name" class="flex gap-3 text-xs" style="color: var(--semantic-text-muted);">
            <span v-if="msg.tool_call_id" :data-testid="`chain-card-tool-call-id-${idx}`">tool_call_id: {{ msg.tool_call_id }}</span>
            <span v-if="msg.tool_name" :data-testid="`chain-card-tool-name-${idx}`">tool_name: {{ msg.tool_name }}</span>
          </div>
        </div>
      </div>
    </div>

    <!-- Curl Tabs -->
    <div v-if="curl && bodies" data-testid="curl-tabs" class="flex flex-col gap-3">
      <h3 class="text-sm font-semibold" style="color: var(--semantic-text);">Curl previews</h3>

      <!-- Tab strip -->
      <div class="flex gap-1 p-1 rounded-lg w-fit" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <button
          data-testid="curl-tab-anthropic"
          class="px-3 py-1.5 rounded text-xs font-medium transition-colors"
          :style="activeCurlTab === 'anthropic' ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);' : 'color: var(--semantic-text-muted);'"
          @click="activeCurlTab = 'anthropic'"
        >Anthropic</button>
        <button
          data-testid="curl-tab-openai"
          class="px-3 py-1.5 rounded text-xs font-medium transition-colors"
          :style="activeCurlTab === 'openai' ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);' : 'color: var(--semantic-text-muted);'"
          @click="activeCurlTab = 'openai'"
        >OpenAI Chat</button>
        <button
          data-testid="curl-tab-openai_response"
          class="px-3 py-1.5 rounded text-xs font-medium transition-colors"
          :style="activeCurlTab === 'openai_response' ? 'background-color: var(--semantic-active-bg); color: var(--semantic-active-text);' : 'color: var(--semantic-text-muted);'"
          @click="activeCurlTab = 'openai_response'"
        >OpenAI Responses</button>
      </div>

      <!-- Curl command -->
      <div class="rounded-lg overflow-hidden" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <div class="flex items-center justify-between px-3 py-2" style="border-bottom: 1px solid var(--color-border);">
          <span class="text-xs font-medium" style="color: var(--semantic-text-muted);">
            <template v-if="activeCurlTab === 'anthropic'">POST /v1/messages</template>
            <template v-else-if="activeCurlTab === 'openai'">POST /v1/chat/completions</template>
            <template v-else>POST /v1/responses</template>
          </span>
          <button
            data-testid="copy-curl-btn"
            class="px-3 py-1 rounded text-xs font-medium transition-colors"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-active-text);"
            @click="copyCurl"
          >{{ copiedCurl ? 'Copied!' : 'Copy curl' }}</button>
        </div>
        <pre
          data-testid="curl-pre"
          class="text-xs whitespace-pre-wrap break-words p-3 max-h-64 overflow-y-auto"
          style="color: var(--semantic-text);"
        >{{ activeCurlString }}</pre>
      </div>

      <!-- JSON body -->
      <div class="rounded-lg overflow-hidden" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);">
        <div class="flex items-center justify-between px-3 py-2" style="border-bottom: 1px solid var(--color-border);">
          <span class="text-xs font-medium" style="color: var(--semantic-text-muted);">JSON body</span>
          <button
            data-testid="copy-json-btn"
            class="px-3 py-1 rounded text-xs font-medium transition-colors"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-active-text);"
            @click="copyJson"
          >{{ copiedJson ? 'Copied!' : 'Copy JSON' }}</button>
        </div>
        <pre
          data-testid="json-pre"
          class="text-xs whitespace-pre-wrap break-words p-3 max-h-96 overflow-y-auto"
          style="color: var(--semantic-text);"
        >{{ activeBodyPretty }}</pre>
      </div>
    </div>
  </div>
</template>

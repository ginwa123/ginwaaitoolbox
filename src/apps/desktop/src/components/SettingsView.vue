<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'

const router = useRouter()

// Settings sidebar state
const activeSettingsTab = ref('model')

// Settings state
const apiEndpoint = ref('')
const apiKey = ref('')
const model = ref('')
const temperature = ref(0.7)
const maxTokens = ref('')
const systemPrompt = ref('')

onMounted(() => {
  apiEndpoint.value = localStorage.getItem('settings-api-endpoint') || ''
  apiKey.value = localStorage.getItem('settings-api-key') || ''
  model.value = localStorage.getItem('settings-model') || ''
  temperature.value = parseFloat(localStorage.getItem('settings-temperature') || '0.7')
  maxTokens.value = localStorage.getItem('settings-max-tokens') || ''
  systemPrompt.value = localStorage.getItem('settings-system-prompt') || ''
})

const saveSettings = () => {
  localStorage.setItem('settings-api-endpoint', apiEndpoint.value)
  localStorage.setItem('settings-api-key', apiKey.value)
  localStorage.setItem('settings-model', model.value)
  localStorage.setItem('settings-temperature', temperature.value.toString())
  localStorage.setItem('settings-max-tokens', maxTokens.value)
  localStorage.setItem('settings-system-prompt', systemPrompt.value)
  alert('Settings saved!')
}

const resetSettings = () => {
  apiEndpoint.value = ''
  apiKey.value = ''
  model.value = ''
  temperature.value = 0.7
  maxTokens.value = ''
  systemPrompt.value = ''
  localStorage.removeItem('settings-api-endpoint')
  localStorage.removeItem('settings-api-key')
  localStorage.removeItem('settings-model')
  localStorage.removeItem('settings-temperature')
  localStorage.removeItem('settings-max-tokens')
  localStorage.removeItem('settings-system-prompt')
}

const emit = defineEmits<{
  close: []
}>()

const goBack = () => {
  emit('close')
}

const setSettingsTab = (tab: string) => {
  activeSettingsTab.value = tab
}
</script>

<template>
  <!-- Fullscreen Settings Overlay -->
  <div class="fixed inset-0 z-50 flex" style="background-color: var(--semantic-content-bg);">
    <!-- Settings Sidebar -->
    <div
      class="h-full flex flex-col shrink-0"
      style="width: 240px; background-color: var(--semantic-sidebar-bg); border-right: 1px solid var(--color-border);"
    >
      <!-- Settings Header -->
      <div
        class="h-14 flex items-center px-4 shrink-0"
        style="border-bottom: 1px solid var(--color-border);"
      >
        <button
          @click="goBack"
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80 mr-3"
          style="color: var(--semantic-text-muted);"
          title="Back"
        >
          <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </button>
        <h1
          class="text-lg font-semibold"
          style="color: var(--semantic-text);"
        >Settings</h1>
      </div>

      <!-- Settings Menu -->
      <nav class="flex-1 py-4 px-3 overflow-y-auto">
        <button
          @click="setSettingsTab('model')"
          class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 mb-1"
          :style="activeSettingsTab === 'model'
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <span class="text-lg">🤖</span>
          <span>Model</span>
        </button>

        <button
          @click="setSettingsTab('skills')"
          class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200"
          :style="activeSettingsTab === 'skills'
            ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
            : `color: var(--semantic-text-muted);`"
        >
          <span class="text-lg">🛠️</span>
          <span>Skills</span>
        </button>
      </nav>
    </div>

    <!-- Settings Content -->
    <main class="flex-1 flex flex-col overflow-hidden">
      <!-- Model Tab Content -->
      <div v-if="activeSettingsTab === 'model'" class="flex-1 overflow-y-auto p-6">
        <div class="max-w-2xl mx-auto space-y-6">
          <!-- API Configuration Section -->
          <div
            class="rounded-xl p-6"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          >
            <h2
              class="text-base font-semibold mb-4"
              style="color: var(--semantic-text);"
            >API Configuration</h2>

            <div class="space-y-4">
              <!-- API Endpoint -->
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                  style="color: var(--semantic-text-muted);"
                >API Endpoint</label>
                <input
                  v-model="apiEndpoint"
                  type="text"
                  placeholder="https://api.example.com/v1"
                  class="w-full px-4 py-2.5 rounded-lg border text-sm"
                  style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
                />
              </div>

              <!-- API Key -->
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                  style="color: var(--semantic-text-muted);"
                >API Key</label>
                <input
                  v-model="apiKey"
                  type="password"
                  placeholder="sk-..."
                  class="w-full px-4 py-2.5 rounded-lg border text-sm"
                  style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
                />
              </div>

              <!-- Model -->
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                  style="color: var(--semantic-text-muted);"
                >Model</label>
                <input
                  v-model="model"
                  type="text"
                  placeholder="gpt-4o-mini"
                  class="w-full px-4 py-2.5 rounded-lg border text-sm"
                  style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
                />
              </div>
            </div>
          </div>

          <!-- Model Parameters Section -->
          <div
            class="rounded-xl p-6"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          >
            <h2
              class="text-base font-semibold mb-4"
              style="color: var(--semantic-text);"
            >Model Parameters</h2>

            <div class="space-y-4">
              <!-- Temperature -->
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                  style="color: var(--semantic-text-muted);"
                >
                  Temperature: {{ temperature.toFixed(1) }}
                </label>
                <input
                  v-model.number="temperature"
                  type="range"
                  min="0"
                  max="2"
                  step="0.1"
                  class="w-full"
                />
                <div class="flex justify-between text-xs mt-1" style="color: var(--semantic-text-dim);">
                  <span>Precise</span>
                  <span>Creative</span>
                </div>
              </div>

              <!-- Max Tokens -->
              <div>
                <label
                  class="block text-sm font-medium mb-2"
                  style="color: var(--semantic-text-muted);"
                >Max Tokens</label>
                <input
                  v-model="maxTokens"
                  type="number"
                  placeholder="4096"
                  class="w-full px-4 py-2.5 rounded-lg border text-sm"
                  style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
                />
              </div>
            </div>
          </div>

          <!-- System Prompt Section -->
          <div
            class="rounded-xl p-6"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          >
            <h2
              class="text-base font-semibold mb-4"
              style="color: var(--semantic-text);"
            >System Prompt</h2>

            <textarea
              v-model="systemPrompt"
              placeholder="Enter system prompt for the AI..."
              rows="6"
              class="w-full px-4 py-2.5 rounded-lg border text-sm resize-none"
              style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
            />
          </div>

          <!-- Actions -->
          <div class="flex gap-3">
            <button
              @click="saveSettings"
              class="px-6 py-2.5 rounded-lg font-medium text-sm transition-colors duration-200"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
            >
              Save Settings
            </button>
            <button
              @click="resetSettings"
              class="px-6 py-2.5 rounded-lg font-medium text-sm transition-colors duration-200"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
            >
              Reset to Defaults
            </button>
          </div>
        </div>
      </div>

      <!-- Skills Tab Content -->
      <div v-else-if="activeSettingsTab === 'skills'" class="flex-1 overflow-y-auto p-6">
        <div class="max-w-2xl mx-auto">
          <div
            class="rounded-xl p-6"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          >
            <h2
              class="text-base font-semibold mb-4"
              style="color: var(--semantic-text);"
            >Skills</h2>
            <p style="color: var(--semantic-text-muted);">
              Configure AI skills and capabilities here.
            </p>
          </div>
        </div>
      </div>
    </main>
  </div>
</template>
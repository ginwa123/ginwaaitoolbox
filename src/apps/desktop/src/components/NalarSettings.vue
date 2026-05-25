<script setup lang="ts">
import { ref, onMounted, computed } from 'vue'
import { getNalarConfig, saveNalarConfig } from '../api'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

// Settings state
const apiEndpoint = ref('')
const apiKey = ref('')
const model = ref('')
const temperature = ref(0.7)
const maxTokens = ref('')
const systemPrompt = ref('')

// Profiles state
const profiles = ref<Profile[]>([])
const activeProfile = ref<string | null>(null)
const editingProfile = ref<Profile | null>(null)
const isAddingProfile = ref(false)

interface Profile {
  name: string
  model: string
  base_url: string
  thinking: string
  temperature: string
  api_key: string
}

const emptyProfile = (): Profile => ({
  name: '',
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  api_key: ''
})

const parseJsonValue = (val: any): string => {
  if (val === null || val === undefined) return ''
  if (typeof val === 'string') return val
  return String(val)
}

onMounted(async () => {
  // Load from localStorage as fallback
  apiEndpoint.value = localStorage.getItem('settings-api-endpoint') || ''
  apiKey.value = localStorage.getItem('settings-api-key') || ''
  model.value = localStorage.getItem('settings-model') || ''
  temperature.value = parseFloat(localStorage.getItem('settings-temperature') || '0.7')
  maxTokens.value = localStorage.getItem('settings-max-tokens') || ''
  systemPrompt.value = localStorage.getItem('settings-system-prompt') || ''
  
  // Try to load from nalar.json via API
  try {
    const data = await getNalarConfig()
    if (data) {
      apiEndpoint.value = data.api_endpoint || ''
      apiKey.value = data.api_key || ''
      model.value = data.model || ''
      temperature.value = data.temperature ?? 0.7
      maxTokens.value = data.max_tokens?.toString() || ''
      systemPrompt.value = data.system_prompt || ''
      
      // Load profiles
      if (data.profiles) {
        const profilesList: Profile[] = []
        for (const [name, profile] of Object.entries(data.profiles)) {
          profilesList.push({
            name,
            model: parseJsonValue((profile as any).model),
            base_url: parseJsonValue((profile as any).base_url),
            thinking: parseJsonValue((profile as any).thinking),
            temperature: parseJsonValue((profile as any).temperature),
            api_key: parseJsonValue((profile as any).api_key)
          })
        }
        profiles.value = profilesList
      }
      
      activeProfile.value = data.active_profile || null
    }
  } catch {
    // Use localStorage fallback
  }
})

const saveSettings = async () => {
  const settings: any = {
    api_endpoint: apiEndpoint.value,
    api_key: apiKey.value,
    model: model.value,
    temperature: temperature.value,
    max_tokens: maxTokens.value ? parseInt(maxTokens.value) : null,
    system_prompt: systemPrompt.value
  }
  
  // Handle profiles with add/update/delete actions
  const profileChanges: any[] = []
  
  for (const profile of profiles.value) {
    profileChanges.push({
      name: profile.name,
      action: 'update',
      model: profile.model,
      base_url: profile.base_url,
      thinking: profile.thinking,
      temperature: profile.temperature,
      api_key: profile.api_key
    })
  }
  
  // Handle deleted profiles
  const originalData = await getNalarConfig().catch(() => null)
  if (originalData?.profiles) {
    const currentNames = new Set(profiles.value.map(p => p.name))
    for (const originalName of Object.keys(originalData.profiles)) {
      if (!currentNames.has(originalName)) {
        profileChanges.push({
          name: originalName,
          action: 'delete'
        })
      }
    }
  }
  
  if (profileChanges.length > 0) {
    settings.profiles = profileChanges
  }
  
  if (activeProfile.value) {
    settings.active_profile = activeProfile.value
  }
  
  try {
    await saveNalarConfig(settings)
    emit('notification', 'Settings saved to config.json!', 'success')
  } catch {
    localStorage.setItem('settings-api-endpoint', apiEndpoint.value)
    localStorage.setItem('settings-api-key', apiKey.value)
    localStorage.setItem('settings-model', model.value)
    localStorage.setItem('settings-temperature', temperature.value.toString())
    localStorage.setItem('settings-max-tokens', maxTokens.value)
    localStorage.setItem('settings-system-prompt', systemPrompt.value)
    emit('notification', 'Settings saved!', 'success')
  }
}

const resetSettings = () => {
  apiEndpoint.value = ''
  apiKey.value = ''
  model.value = ''
  temperature.value = 0.7
  maxTokens.value = ''
  systemPrompt.value = ''
  profiles.value = []
  activeProfile.value = null
  localStorage.removeItem('settings-api-endpoint')
  localStorage.removeItem('settings-api-key')
  localStorage.removeItem('settings-model')
  localStorage.removeItem('settings-temperature')
  localStorage.removeItem('settings-max-tokens')
  localStorage.removeItem('settings-system-prompt')
  emit('notification', 'Settings reset to defaults', 'success')
}

const startAddProfile = () => {
  editingProfile.value = emptyProfile()
  isAddingProfile.value = true
}

const startEditProfile = (profile: Profile) => {
  editingProfile.value = { ...profile }
  isAddingProfile.value = false
}

const cancelEditProfile = () => {
  editingProfile.value = null
  isAddingProfile.value = false
}

const saveProfile = () => {
  if (!editingProfile.value) return
  
  if (isAddingProfile.value) {
    profiles.value.push({ ...editingProfile.value })
  } else {
    const index = profiles.value.findIndex(p => p.name === editingProfile.value!.name)
    if (index !== -1) {
      profiles.value[index] = { ...editingProfile.value }
    }
  }
  
  editingProfile.value = null
  isAddingProfile.value = false
}

const deleteProfile = (name: string) => {
  profiles.value = profiles.value.filter(p => p.name !== name)
  if (activeProfile.value === name) {
    activeProfile.value = null
  }
}

const selectActiveProfile = (name: string) => {
  activeProfile.value = name
}

defineExpose({ saveSettings, resetSettings })
</script>

<template>
  <div class="max-w-2xl mx-auto space-y-6">
    <!-- API Configuration Section -->
    <div
      class="rounded-xl p-6"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    >
      <h2
        class="text-base font-semibold mb-4"
        style="color: var(--semantic-text);"
      >Nalar Configuration</h2>

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

    <!-- Profiles Section -->
    <div
      class="rounded-xl p-6"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    >
      <div class="flex justify-between items-center mb-4">
        <h2
          class="text-base font-semibold"
          style="color: var(--semantic-text);"
        >Profiles</h2>
        <button
          @click="startAddProfile"
          class="px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
        >
          + Add Profile
        </button>
      </div>

      <!-- Profile List -->
      <div class="space-y-3">
        <div
          v-for="profile in profiles"
          :key="profile.name"
          class="p-4 rounded-lg border"
          :style="{
            backgroundColor: 'var(--semantic-content-bg)',
            borderColor: activeProfile === profile.name ? 'var(--color-violet)' : 'var(--color-border)'
          }"
        >
          <div class="flex justify-between items-start">
            <div class="flex-1">
              <div class="flex items-center gap-2">
                <span class="font-medium" style="color: var(--semantic-text);">{{ profile.name }}</span>
                <span
                  v-if="activeProfile === profile.name"
                  class="text-xs px-2 py-0.5 rounded"
                  style="background: var(--color-violet); color: white;"
                >
                  Active
                </span>
              </div>
              <div class="text-sm mt-1" style="color: var(--semantic-text-muted);">
                {{ profile.model }} - {{ profile.base_url }}
              </div>
            </div>
            <div class="flex gap-2">
              <button
                @click="selectActiveProfile(profile.name)"
                class="px-3 py-1 text-xs rounded"
                :style="{ backgroundColor: 'var(--semantic-card-bg)', color: 'var(--semantic-text-muted)', border: '1px solid var(--color-border)' }"
              >
                {{ activeProfile === profile.name ? 'Active' : 'Set Active' }}
              </button>
              <button
                @click="startEditProfile(profile)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
              >
                Edit
              </button>
              <button
                @click="deleteProfile(profile.name)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: #ef4444; border: 1px solid var(--color-border);"
              >
                Delete
              </button>
            </div>
          </div>
        </div>

        <div
          v-if="profiles.length === 0"
          class="text-center py-8"
          style="color: var(--semantic-text-muted);"
        >
          No profiles configured. Click "Add Profile" to create one.
        </div>
      </div>

      <!-- Profile Edit Modal -->
      <div
        v-if="editingProfile"
        class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
        @click.self="cancelEditProfile"
      >
        <div
          class="rounded-xl p-6 w-full max-w-md"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <h3 class="text-lg font-semibold mb-4" style="color: var(--semantic-text);">
            {{ isAddingProfile ? 'Add Profile' : 'Edit Profile' }}
          </h3>
          
          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Profile Name</label>
              <input
                v-model="editingProfile.name"
                type="text"
                :disabled="!isAddingProfile"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Model</label>
              <input
                v-model="editingProfile.model"
                type="text"
                placeholder="MiniMax-M2.7"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Base URL</label>
              <input
                v-model="editingProfile.base_url"
                type="text"
                placeholder="https://api.minimax.io/v1"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Thinking</label>
              <select
                v-model="editingProfile.thinking"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="auto">Auto</option>
                <option value="on">On</option>
                <option value="off">Off</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Temperature</label>
              <select
                v-model="editingProfile.temperature"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="auto">Auto</option>
                <option value="0">0 - Precise</option>
                <option value="0.5">0.5</option>
                <option value="1">1 - Balanced</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">API Key</label>
              <input
                v-model="editingProfile.api_key"
                type="password"
                placeholder="sk-..."
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
          </div>

          <div class="flex gap-3 mt-6">
            <button
              @click="saveProfile"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
            >
              Save
            </button>
            <button
              @click="cancelEditProfile"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
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
</template>
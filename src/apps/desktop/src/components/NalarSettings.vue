<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { getNalarConfig, saveNalarConfig, type SubAgent } from '../api'
import { useProfileDelete } from '../composables/useProfileDelete'
import ConfirmDialog from './ConfirmDialog.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

// Settings state
const apiEndpoint = ref('')
const apiKey = ref('')
const model = ref('')
const urlStyle = ref('openai')
const temperature = ref(0.7)
const maxTokens = ref('')
const systemPrompt = ref('')
const notifyOnComplete = ref(false)

// Profiles state
const profiles = ref<Profile[]>([])
const activeProfile = ref<string | null>(null)
const editingProfile = ref<Profile | null>(null)
const isAddingProfile = ref(false)

// Delete confirmation state — the name of the profile pending delete,
// or null when the dialog is closed.
const confirmingDeleteProfile = ref<string | null>(null)

// Wire the composable. It owns the optimistic update, rollback, and
// API call. We route success/error to the existing `notification`
// emit so the toast appears in the same place as other settings
// notifications.
const { deleteProfile, isDeleting: isDeletingProfile } = useProfileDelete(
  profiles,
  activeProfile,
  (msg) => emit('notification', msg, 'success'),
  (msg) => emit('notification', msg, 'error'),
)

// MCP servers state
const mcpServers = ref<McpServer[]>([])
const editingMcpServer = ref<McpServer | null>(null)
const editingMcpServerOriginalName = ref<string | null>(null)
const isAddingMcpServer = ref(false)

// Sub-agents state (top-level). Each sub-agent has a full LLM
// configuration plus a system_prompt. Referenced by name from the
// `spawn_sub_agent` tool.
const subAgents = ref<SubAgent[]>([])
const editingSubAgent = ref<SubAgent | null>(null)
const isAddingSubAgent = ref(false)

interface Profile {
  name: string
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  /** Per-profile sub-agents. Mirrors the top-level `subAgents` shape. */
  sub_agents: SubAgent[]
}

interface McpHeader {
  key: string
  value: string
}

interface McpServer {
  name: string
  url: string
  headers: McpHeader[]
}

const emptyProfile = (): Profile => ({
  name: '',
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  sub_agents: []
})

const emptyMcpServer = (): McpServer => ({
  name: '',
  url: '',
  headers: []
})

const emptySubAgent = (): SubAgent => ({
  name: '',
  model: '',
  base_url: '',
  thinking: 'auto',
  temperature: 'auto',
  url_style: 'openai',
  api_key: '',
  system_prompt: ''
})

/**
 * Convert a raw sub-agent JSON object (from the backend) into a typed
 * `SubAgent` for the UI. Missing fields fall back to the same defaults
 * the backend applies on parse, so the modal always shows a consistent shape.
 */
const parseSubAgent = (raw: any): SubAgent => ({
  name: raw.name ?? '',
  model: raw.model ?? '',
  base_url: raw.base_url ?? '',
  thinking: raw.thinking ?? 'auto',
  temperature: raw.temperature ?? 'auto',
  url_style: raw.url_style ?? 'openai',
  api_key: raw.api_key ?? '',
  system_prompt: raw.system_prompt ?? ''
})

const parseJsonValue = (val: any): string => {
  if (val === null || val === undefined) return ''
  if (typeof val === 'string') return val
  return String(val)
}

/**
 * Convert the raw `mcp_servers` map returned by the backend into a sorted
 * array of `McpServer` objects for display. Unknown server shapes are skipped.
 */
const parseMcpServers = (
  raw: Record<string, { url: string; headers?: Record<string, string> }> | undefined,
): McpServer[] => {
  if (!raw) return []
  const result: McpServer[] = []
  for (const [name, server] of Object.entries(raw)) {
    if (!server || typeof server.url !== 'string' || server.url.length === 0) continue
    const headers: McpHeader[] = []
    if (server.headers && typeof server.headers === 'object') {
      for (const [key, value] of Object.entries(server.headers)) {
        headers.push({ key, value: String(value ?? '') })
      }
    }
    result.push({ name, url: server.url, headers })
  }
  // Sort by name for stable display order.
  result.sort((a, b) => a.name.localeCompare(b.name))
  return result
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
      urlStyle.value = data.url_style || 'openai'
      temperature.value = data.temperature ?? 0.7
      maxTokens.value = data.max_tokens?.toString() || ''
      systemPrompt.value = data.system_prompt || ''
      notifyOnComplete.value = data.notify_on_complete ?? false

      // Load profiles
      if (data.profiles) {
        const profilesList: Profile[] = []
        for (const [name, profile] of Object.entries(data.profiles)) {
          const perProfileSubAgents = Array.isArray(profile.sub_agents)
            ? profile.sub_agents.map(parseSubAgent)
            : []
          profilesList.push({
            name,
            model: parseJsonValue(profile.model),
            base_url: parseJsonValue(profile.base_url),
            thinking: parseJsonValue(profile.thinking),
            temperature: parseJsonValue(profile.temperature),
            url_style: parseJsonValue(profile.url_style) || 'openai',
            api_key: parseJsonValue(profile.api_key),
            sub_agents: perProfileSubAgents
          })
        }
        profiles.value = profilesList
      }

      activeProfile.value = data.active_profile || null

      // Load MCP servers
      mcpServers.value = parseMcpServers(data.mcp_servers)

      // Load top-level sub-agents
      if (Array.isArray(data.sub_agents)) {
        subAgents.value = data.sub_agents.map(parseSubAgent)
      }
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
    url_style: urlStyle.value,
    temperature: temperature.value,
    max_tokens: maxTokens.value ? parseInt(maxTokens.value) : null,
    system_prompt: systemPrompt.value,
    notify_on_complete: notifyOnComplete.value,
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
      url_style: profile.url_style,
      api_key: profile.api_key,
      sub_agents: profile.sub_agents ?? []
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

  // Send the full MCP server list. The backend replaces the existing list
  // wholesale when `mcp_servers` is present.
  settings.mcp_servers = serializeMcpServers(mcpServers.value)

  // Send the full top-level sub-agents list. The backend replaces the
  // existing list wholesale when `sub_agents` is present.
  if (subAgents.value.length > 0) {
    settings.sub_agents = subAgents.value
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

/**
 * Convert the in-memory `McpServer[]` into the `{name: {url, headers}}` map
 * the backend expects. Empty `url`s are dropped, and entries with empty header
 * keys are filtered out. Returns `null` when no servers are configured so the
 * backend can detect "no change" vs "explicit empty list" if needed.
 */
const serializeMcpServers = (
  servers: McpServer[],
): Record<string, { url: string; headers?: Record<string, string> }> | null => {
  if (servers.length === 0) return null
  const result: Record<string, { url: string; headers?: Record<string, string> }> = {}
  for (const server of servers) {
    if (!server.name || !server.url) continue
    const headers: Record<string, string> = {}
    for (const header of server.headers) {
      if (!header.key) continue
      headers[header.key] = header.value
    }
    result[server.name] = {
      url: server.url,
      ...(Object.keys(headers).length > 0 ? { headers } : {}),
    }
  }
  return Object.keys(result).length > 0 ? result : null
}

const resetSettings = () => {
  apiEndpoint.value = ''
  apiKey.value = ''
  model.value = ''
  urlStyle.value = 'openai'
  temperature.value = 0.7
  maxTokens.value = ''
  systemPrompt.value = ''
  notifyOnComplete.value = false
  profiles.value = []
  activeProfile.value = null
  mcpServers.value = []
  localStorage.removeItem('settings-api-endpoint')
  localStorage.removeItem('settings-api-key')
  localStorage.removeItem('settings-model')
  localStorage.removeItem('settings-url-style')
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

// Click handler for the row's Delete button. Shows the confirmation
// dialog. The actual delete + rollback is in the composable, invoked
// by `confirmDeleteProfile` once the user confirms.
const requestDeleteProfile = (name: string) => {
  confirmingDeleteProfile.value = name
}

const cancelDeleteProfile = () => {
  confirmingDeleteProfile.value = null
}

const confirmDeleteProfile = async () => {
  const name = confirmingDeleteProfile.value
  if (!name) return
  confirmingDeleteProfile.value = null
  try {
    await deleteProfile(name) // composable's function
  } catch {
    // Notification already emitted by the composable. Swallow the
    // throw so the row's click handler doesn't see an unhandled
    // rejection — the composable has already rolled back the local
    // state and surfaced the error.
  }
}

const selectActiveProfile = (name: string) => {
  activeProfile.value = name
}

const startAddMcpServer = () => {
  editingMcpServer.value = emptyMcpServer()
  editingMcpServerOriginalName.value = null
  isAddingMcpServer.value = true
}

const startEditMcpServer = (server: McpServer) => {
  // Deep copy so the modal edits don't mutate the row in the list until saved.
  editingMcpServer.value = {
    name: server.name,
    url: server.url,
    headers: server.headers.map(h => ({ key: h.key, value: h.value })),
  }
  // Track the original name so renames are checked against other rows, not self.
  editingMcpServerOriginalName.value = server.name
  isAddingMcpServer.value = false
}

const cancelEditMcpServer = () => {
  editingMcpServer.value = null
  editingMcpServerOriginalName.value = null
  isAddingMcpServer.value = false
}

const saveMcpServer = () => {
  if (!editingMcpServer.value) return
  const incoming = editingMcpServer.value
  const trimmedName = incoming.name.trim()
  const trimmedUrl = incoming.url.trim()
  if (!trimmedName || !trimmedUrl) {
    emit('notification', 'MCP server requires a name and a URL', 'error')
    return
  }

  // Reject name collisions with other rows. The row being edited (matched by
  // its original name) is excluded so renaming to the same name is fine.
  const original = editingMcpServerOriginalName.value
  const collision = mcpServers.value.some(
    s => s.name === trimmedName && s.name !== original,
  )
  if (collision) {
    emit('notification', `MCP server "${trimmedName}" already exists`, 'error')
    return
  }

  const sanitized: McpServer = {
    name: trimmedName,
    url: trimmedUrl,
    headers: incoming.headers.filter(h => h.key.length > 0),
  }

  if (isAddingMcpServer.value || original == null) {
    mcpServers.value.push(sanitized)
  } else {
    // Find the row by its original name; it should still exist because we
    // haven't mutated the list while editing.
    const index = mcpServers.value.findIndex(s => s.name === original)
    if (index !== -1) {
      mcpServers.value[index] = sanitized
    } else {
      mcpServers.value.push(sanitized)
    }
  }

  // Re-sort by name for stable order in the list.
  mcpServers.value.sort((a, b) => a.name.localeCompare(b.name))

  editingMcpServer.value = null
  editingMcpServerOriginalName.value = null
  isAddingMcpServer.value = false
}

const deleteMcpServer = (name: string) => {
  mcpServers.value = mcpServers.value.filter(s => s.name !== name)
}

const addMcpHeader = () => {
  if (!editingMcpServer.value) return
  editingMcpServer.value.headers.push({ key: '', value: '' })
}

const removeMcpHeader = (index: number) => {
  if (!editingMcpServer.value) return
  editingMcpServer.value.headers.splice(index, 1)
}

const startAddSubAgent = () => {
  editingSubAgent.value = emptySubAgent()
  isAddingSubAgent.value = true
}

const startEditSubAgent = (sa: SubAgent) => {
  // Deep copy so the modal edits don't mutate the row in the list until saved.
  editingSubAgent.value = { ...sa }
  isAddingSubAgent.value = false
}

const cancelEditSubAgent = () => {
  editingSubAgent.value = null
  isAddingSubAgent.value = false
}

const saveSubAgent = () => {
  if (!editingSubAgent.value) return
  const incoming = editingSubAgent.value
  const trimmedName = incoming.name.trim()
  if (!trimmedName) {
    emit('notification', 'Sub-agent requires a name', 'error')
    return
  }
  if (isAddingSubAgent.value) {
    if (subAgents.value.some((s: SubAgent) => s.name === trimmedName)) {
      emit('notification', `Sub-agent "${trimmedName}" already exists`, 'error')
      return
    }
    subAgents.value.push({ ...incoming, name: trimmedName })
  } else {
    const index = subAgents.value.findIndex((s: SubAgent) => s.name === incoming.name)
    if (index !== -1) {
      subAgents.value[index] = { ...incoming, name: trimmedName }
    } else {
      subAgents.value.push({ ...incoming, name: trimmedName })
    }
  }

  // Re-sort by name for stable order in the list.
  subAgents.value.sort((a: SubAgent, b: SubAgent) => a.name.localeCompare(b.name))

  editingSubAgent.value = null
  isAddingSubAgent.value = false
}

const deleteSubAgent = (name: string) => {
  subAgents.value = subAgents.value.filter((s: SubAgent) => s.name !== name)
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

        <!-- URL Style -->
        <div>
          <label
            class="block text-sm font-medium mb-2"
            style="color: var(--semantic-text-muted);"
          >URL Style</label>
          <select
            v-model="urlStyle"
            class="w-full px-4 py-2.5 rounded-lg border text-sm"
            style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
          >
            <option value="openai">OpenAI (e.g. /v1/chat/completions)</option>
            <option value="anthropic">Anthropic (e.g. /v1/messages)</option>
          </select>
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

        <!-- Notify on Complete -->
        <div>
          <label
            class="flex items-center gap-2 cursor-pointer text-sm"
            style="color: var(--semantic-text-muted);"
          >
            <input
              v-model="notifyOnComplete"
              type="checkbox"
              class="w-4 h-4 rounded"
              style="accent-color: var(--color-violet);"
            />
            <span>Notify when LLM response completes</span>
          </label>
          <p
            class="text-xs mt-1 ml-6"
            style="color: var(--semantic-text-dim);"
          >Fires an OS notification when an LLM response finishes with <code>finish_reason === 'stop'</code>. Requires a notification daemon (notify-send on Linux, osascript on macOS, PowerShell on Windows).</p>
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
                @click="requestDeleteProfile(profile.name)"
                :disabled="isDeletingProfile && confirmingDeleteProfile === profile.name"
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
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">URL Style</label>
              <select
                v-model="editingProfile.url_style"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="openai">OpenAI (e.g. /v1/chat/completions)</option>
                <option value="anthropic">Anthropic (e.g. /v1/messages)</option>
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

      <!-- Delete confirmation dialog -->
      <ConfirmDialog
        :show="confirmingDeleteProfile !== null"
        title="Delete profile"
        :message="`Are you sure you want to delete the profile \u201c${confirmingDeleteProfile ?? ''}\u201d? This cannot be undone.`"
        confirm-text="Delete"
        cancel-text="Cancel"
        @confirm="confirmDeleteProfile"
        @close="cancelDeleteProfile"
      />
    </div>

    <!-- Sub-Agents Section -->
    <div
      class="rounded-xl p-6"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    >
      <div class="flex justify-between items-center mb-4">
        <div>
          <h2
            class="text-base font-semibold"
            style="color: var(--semantic-text);"
          >Sub-Agents</h2>
          <p
            class="text-xs mt-1"
            style="color: var(--semantic-text-dim);"
          >Named sub-agent LLM configurations used by <code>spawn_sub_agent</code>.</p>
        </div>
        <button
          @click="startAddSubAgent"
          class="px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
        >
          + Add Sub-Agent
        </button>
      </div>

      <!-- Sub-Agent list -->
      <div class="space-y-3">
        <div
          v-for="sa in subAgents"
          :key="sa.name"
          class="p-4 rounded-lg border"
          style="background-color: var(--semantic-content-bg); border-color: var(--color-border);"
        >
          <div class="flex justify-between items-start">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium" style="color: var(--semantic-text);">{{ sa.name }}</span>
              </div>
              <div
                class="text-sm mt-1 truncate"
                style="color: var(--semantic-text-muted);"
                :title="sa.model"
              >{{ sa.model }} - {{ sa.base_url }}</div>
              <div
                v-if="sa.system_prompt"
                class="text-xs mt-1 line-clamp-2"
                style="color: var(--semantic-text-dim);"
                :title="sa.system_prompt"
              >{{ sa.system_prompt }}</div>
            </div>
            <div class="flex gap-2 ml-3 shrink-0">
              <button
                @click="startEditSubAgent(sa)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
              >Edit</button>
              <button
                @click="deleteSubAgent(sa.name)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: #ef4444; border: 1px solid var(--color-border);"
              >Delete</button>
            </div>
          </div>
        </div>

        <div
          v-if="subAgents.length === 0"
          class="text-center py-8"
          style="color: var(--semantic-text-muted);"
        >
          No sub-agents configured. Click "Add Sub-Agent" to create one.
        </div>
      </div>

      <!-- Sub-Agent Edit Modal -->
      <div
        v-if="editingSubAgent"
        class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
        @click.self="cancelEditSubAgent"
      >
        <div
          class="rounded-xl p-6 w-full max-w-md max-h-[90vh] overflow-y-auto"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <h3 class="text-lg font-semibold mb-4" style="color: var(--semantic-text);">
            {{ isAddingSubAgent ? 'Add Sub-Agent' : 'Edit Sub-Agent' }}
          </h3>

          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Name</label>
              <input
                v-model="editingSubAgent.name"
                type="text"
                :disabled="!isAddingSubAgent"
                placeholder="SubAgent1"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Model</label>
              <input
                v-model="editingSubAgent.model"
                type="text"
                placeholder="MiniMax-M3"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Base URL</label>
              <input
                v-model="editingSubAgent.base_url"
                type="text"
                placeholder="https://api.minimax.io/v1"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Thinking</label>
              <select
                v-model="editingSubAgent.thinking"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="auto">Auto</option>
                <option value="on">On</option>
                <option value="off">Off</option>
                <option value="false">False</option>
                <option value="true">True</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Temperature</label>
              <select
                v-model="editingSubAgent.temperature"
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
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">URL Style</label>
              <select
                v-model="editingSubAgent.url_style"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              >
                <option value="openai">OpenAI (e.g. /v1/chat/completions)</option>
                <option value="anthropic">Anthropic (e.g. /v1/messages)</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">API Key</label>
              <input
                v-model="editingSubAgent.api_key"
                type="password"
                placeholder="sk-..."
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">System Prompt</label>
              <textarea
                v-model="editingSubAgent.system_prompt"
                placeholder="System prompt for this sub-agent..."
                rows="4"
                class="w-full px-4 py-2.5 rounded-lg border text-sm resize-none"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>
          </div>

          <div class="flex gap-3 mt-6">
            <button
              @click="saveSubAgent"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
            >Save</button>
            <button
              @click="cancelEditSubAgent"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
            >Cancel</button>
          </div>
        </div>
      </div>
    </div>

    <!-- MCP Servers Section -->
    <div
      class="rounded-xl p-6"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    >
      <div class="flex justify-between items-center mb-4">
        <div>
          <h2
            class="text-base font-semibold"
            style="color: var(--semantic-text);"
          >MCP Servers</h2>
          <p
            class="text-xs mt-1"
            style="color: var(--semantic-text-dim);"
          >External tool providers the agent can call. Each entry needs a unique name, a URL, and any required HTTP headers.</p>
        </div>
        <button
          @click="startAddMcpServer"
          class="px-4 py-2 rounded-lg text-sm font-medium transition-colors duration-200"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
        >
          + Add Server
        </button>
      </div>

      <!-- Server list -->
      <div class="space-y-3">
        <div
          v-for="server in mcpServers"
          :key="server.name"
          class="p-4 rounded-lg border"
          style="background-color: var(--semantic-content-bg); border-color: var(--color-border);"
        >
          <div class="flex justify-between items-start">
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium" style="color: var(--semantic-text);">{{ server.name }}</span>
              </div>
              <div
                class="text-sm mt-1 truncate"
                style="color: var(--semantic-text-muted);"
                :title="server.url"
              >{{ server.url }}</div>
              <div
                v-if="server.headers.length > 0"
                class="text-xs mt-1"
                style="color: var(--semantic-text-dim);"
              >
                {{ server.headers.length }} header{{ server.headers.length === 1 ? '' : 's' }}
              </div>
            </div>
            <div class="flex gap-2 ml-3 shrink-0">
              <button
                @click="startEditMcpServer(server)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
              >
                Edit
              </button>
              <button
                @click="deleteMcpServer(server.name)"
                class="px-3 py-1 text-xs rounded"
                style="background-color: var(--semantic-card-bg); color: #ef4444; border: 1px solid var(--color-border);"
              >
                Delete
              </button>
            </div>
          </div>
        </div>

        <div
          v-if="mcpServers.length === 0"
          class="text-center py-8"
          style="color: var(--semantic-text-muted);"
        >
          No MCP servers configured. Click "Add Server" to connect one (e.g. context7, github, ...).
        </div>
      </div>

      <!-- MCP Server Edit Modal -->
      <div
        v-if="editingMcpServer"
        class="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
        @click.self="cancelEditMcpServer"
      >
        <div
          class="rounded-xl p-6 w-full max-w-md max-h-[90vh] overflow-y-auto"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
        >
          <h3 class="text-lg font-semibold mb-4" style="color: var(--semantic-text);">
            {{ isAddingMcpServer ? 'Add MCP Server' : 'Edit MCP Server' }}
          </h3>

          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">Server Name</label>
              <input
                v-model="editingMcpServer.name"
                type="text"
                :disabled="!isAddingMcpServer"
                placeholder="context7"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
              <p
                class="text-xs mt-1"
                style="color: var(--semantic-text-dim);"
              >Unique identifier (lowercase recommended). The agent exposes its tools as <code>mcp_{name}_*</code>.</p>
            </div>
            <div>
              <label class="block text-sm font-medium mb-2" style="color: var(--semantic-text-muted);">URL</label>
              <input
                v-model="editingMcpServer.url"
                type="text"
                placeholder="https://mcp.example.com/mcp"
                class="w-full px-4 py-2.5 rounded-lg border text-sm"
                style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
              />
            </div>

            <div>
              <div class="flex justify-between items-center mb-2">
                <label class="block text-sm font-medium" style="color: var(--semantic-text-muted);">Headers</label>
                <button
                  @click="addMcpHeader"
                  class="text-xs px-2 py-1 rounded"
                  style="background-color: var(--semantic-content-bg); color: var(--semantic-text-muted); border: 1px solid var(--color-border);"
                >
                  + Add Header
                </button>
              </div>

              <div v-if="editingMcpServer.headers.length === 0" class="text-xs italic" style="color: var(--semantic-text-dim);">
                No headers. Click "Add Header" for API keys.
              </div>

              <div class="space-y-2">
                <div
                  v-for="(header, hIdx) in editingMcpServer.headers"
                  :key="hIdx"
                  class="flex gap-2 items-center"
                >
                  <input
                    v-model="header.key"
                    type="text"
                    placeholder="Header-Name"
                    class="flex-1 px-3 py-2 rounded border text-sm"
                    style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
                  />
                  <input
                    v-model="header.value"
                    type="text"
                    placeholder="value"
                    class="flex-1 px-3 py-2 rounded border text-sm"
                    style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border);"
                  />
                  <button
                    @click="removeMcpHeader(hIdx)"
                    class="px-2 py-1 text-xs rounded"
                    style="background-color: var(--semantic-card-bg); color: #ef4444; border: 1px solid var(--color-border);"
                    aria-label="Remove header"
                  >
                    ✕
                  </button>
                </div>
              </div>
            </div>
          </div>

          <div class="flex gap-3 mt-6">
            <button
              @click="saveMcpServer"
              class="px-6 py-2.5 rounded-lg font-medium text-sm"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: white;"
            >
              Save
            </button>
            <button
              @click="cancelEditMcpServer"
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
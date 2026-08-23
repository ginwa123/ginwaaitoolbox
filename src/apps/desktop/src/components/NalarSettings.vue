<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'

import {
  deleteProfile as apiDeleteProfile,
  getNalarConfig,
  saveNalarConfig,
  type McpServer,
  type NalarConfig,
  type NalarProfile,
  type SubAgent,
} from '../api'
import { useNalarConfig } from '../composables/useNalarConfig'

import NalarTabStrip from './nalar/NalarTabStrip.vue'
import NalarSaveBar from './nalar/NalarSaveBar.vue'
import DefaultsSection, { type DefaultsConfig } from './nalar/DefaultsSection.vue'
import ProfilesSection, { type ProfileRow } from './nalar/ProfilesSection.vue'
import SubAgentsSection from './nalar/SubAgentsSection.vue'
import McpServersSection from './nalar/McpServersSection.vue'
// plan 2026-07-07-compaction-inline: CompactionSection.vue is removed
// (compaction settings live in the Defaults tab + Edit-profile modal now).
// No import here.
import ProfileModal from './nalar/ProfileModal.vue'
import { type LlmConfigModalValue } from './nalar/LlmConfigModal.vue'
import SubAgentModal, { type SubAgentModalValue } from './nalar/SubAgentModal.vue'
import McpServerModal, { type McpServerModalValue } from './nalar/McpServerModal.vue'
import ConfirmDialog from './dialogs/ConfirmDialog.vue'

const emit = defineEmits<{
  notification: [message: string, type: 'success' | 'error']
}>()

// Expose saveSettings / resetSettings so the parent can trigger them
// (preserves the previous defineExpose surface).
defineExpose({
  saveSettings: () => handleSave(),
  resetSettings: () => handleReset(),
})

// ─── Tab state ────────────────────────────────────────────────────────────
type Tab = 'defaults' | 'profiles' | 'sub-agents' | 'mcp'
const activeTab = ref<Tab>('defaults')

// ─── Central config (useNalarConfig composable) ──────────────────────────
const { config, loaded, dirty, unsavedCount, saving, setConfig, save, reset } = useNalarConfig()

// ─── Legacy localStorage fallback keys (preserved from original) ───────
const LEGACY_LS_KEYS = {
  api_endpoint: 'settings-api-endpoint',
  api_key: 'settings-api-key',
  model: 'settings-model',
  temperature: 'settings-temperature',
  max_tokens: 'settings-max-tokens',
  system_prompt: 'settings-system-prompt',
} as const

function loadLegacyLocalStorageFallback(): Partial<NalarConfig> {
  const out: Partial<NalarConfig> = {}
  const ep = localStorage.getItem(LEGACY_LS_KEYS.api_endpoint)
  if (ep) out.api_endpoint = ep
  const ak = localStorage.getItem(LEGACY_LS_KEYS.api_key)
  if (ak) out.api_key = ak
  const m = localStorage.getItem(LEGACY_LS_KEYS.model)
  if (m) out.model = m
  const t = localStorage.getItem(LEGACY_LS_KEYS.temperature)
  if (t) {
    const parsed = parseFloat(t)
    if (!Number.isNaN(parsed)) out.temperature = parsed
  }
  const mt = localStorage.getItem(LEGACY_LS_KEYS.max_tokens)
  if (mt) out.max_tokens = mt
  const sp = localStorage.getItem(LEGACY_LS_KEYS.system_prompt)
  if (sp) out.system_prompt = sp
  return out
}

onMounted(async () => {
  // Step 1: seed from localStorage (legacy fallback).
  const legacy = loadLegacyLocalStorageFallback()
  // Step 2: try the API; on success, layer the API response on top of
  // the legacy fallback. The API wins because it's authoritative.
  let apiData: NalarConfig | null = null
  try {
    apiData = await getNalarConfig()
  } catch {
    // Network/API failure — keep legacy.
  }
  const merged: NalarConfig = { ...legacy, ...apiData }
  setConfig(merged)
})

// ─── Per-section view state ──────────────────────────────────────────────
const defaultsConfig = ref<DefaultsConfig | null>(null)
const profilesList = ref<ProfileRow[]>([])
const activeProfile = ref<string | null>(null)
const subAgentsList = ref<SubAgent[]>([])
const mcpServersList = ref<McpServer[]>([])

// Plan 2026-07-07-compaction-inline: CompactionSection.vue is removed;
// its per-profile overrides live on each `LlmProfile.max_capacity_tokens`
// and `LlmProfile.compaction_threshold_percent` (edited via the Edit-profile
// modal). Top-level defaults live on the Defaults tab and are carried by
// `defaultsConfig.max_capacity_token_model` + `compaction_threshold_percent`.

function syncFromConfig() {
  if (!config.value) return
  const c = config.value
  defaultsConfig.value = {
    api_endpoint: c.api_endpoint ?? '',
    api_key: c.api_key ?? '',
    model: c.model ?? '',
    url_style: c.url_style ?? 'openai',
    temperature: typeof c.temperature === 'number' ? c.temperature : 0.7,
    max_tokens: c.max_tokens ?? '',
    system_prompt: c.system_prompt ?? '',
    notify_on_complete: c.notify_on_complete ?? false,
    // Top-level compaction defaults — plan 2026-07-07-compaction-inline.
    // Null = no top-level override (fall through to per-profile → built-in).
    max_capacity_token_model: c.max_capacity_token_model ?? null,
    compaction_threshold_percent: c.compaction_threshold_percent ?? null,
    // Workflow retry delay — plan 2026-07-15-retry-delay.
    retry_delay_ms: c.retry_delay_ms ?? 0,
  }
  profilesList.value = Object.entries(c.profiles ?? {}).map(([name, p]) => ({
    name,
    model: p.model ?? '',
    base_url: p.base_url ?? '',
    thinking: p.thinking ?? 'auto',
    temperature: p.temperature ?? 'auto',
    url_style: p.url_style ?? 'openai',
    api_key: p.api_key ?? '',
    sub_agents: p.sub_agents ?? [],
    // Compaction overrides — both top-level (in defaultsConfig above)
    // AND per-profile (here) coexist. Each layer cascades over the
    // next; per-profile wins over top-level.
    max_capacity_tokens: p.max_capacity_tokens ?? null,
    compaction_threshold_percent: p.compaction_threshold_percent ?? null,
    // Model-thinking knobs (plan 2026-08-23-model-thinking).
    // Anthropic budget + OpenAI effort. Both default to null when
    // missing from the persisted profile, so the form can decide
    // whether to render the row (it does for thinking !== "off").
    thinking_budget_tokens: p.thinking_budget_tokens ?? null,
    reasoning_effort: p.reasoning_effort ?? null,
  }))
  activeProfile.value = c.active_profile ?? null
  subAgentsList.value = c.sub_agents ?? []
  mcpServersList.value = parseMcpServers(c.mcp_servers)
}

function syncToConfig() {
  if (!config.value || !defaultsConfig.value) return
  const c = config.value
  const d = defaultsConfig.value
  // Only write list fields when non-empty, so the structural shape
  // of the config stays close to the original (loaded) snapshot. The
  // composable's diff treats `undefined` and missing keys as
  // equivalent, but it can't tell the difference between "user
  // deleted everything" and "user never had anything here" if we
  // always materialize empty objects/arrays.
  const profiles = profilesToRecord(profilesList.value)
  const subAgents = subAgentsList.value
  const mcpServers = serializeMcpServers(mcpServersList.value)
  config.value = {
    ...c,
    api_endpoint: d.api_endpoint,
    api_key: d.api_key,
    model: d.model,
    url_style: d.url_style,
    temperature: d.temperature,
    max_tokens: d.max_tokens,
    system_prompt: d.system_prompt,
    notify_on_complete: d.notify_on_complete,
    // Top-level compaction defaults — plan 2026-07-07-compaction-inline.
    // Unconditional spread so `null` is preserved (cascade wildcard).
    max_capacity_token_model: d.max_capacity_token_model,
    compaction_threshold_percent: d.compaction_threshold_percent,
    // Workflow retry delay — plan 2026-07-15-retry-delay.
    retry_delay_ms: d.retry_delay_ms,
    // Per-profile compaction overrides still live on `profiles` below.
    ...(Object.keys(profiles).length > 0 ? { profiles } : {}),
    ...(activeProfile.value ? { active_profile: activeProfile.value } : {}),
    ...(subAgents.length > 0 ? { sub_agents: subAgents } : {}),
    ...(mcpServers ? { mcp_servers: mcpServers } : {}),
  }
}

function profilesToRecord(list: ProfileRow[]): Record<string, NalarProfile> {
  const out: Record<string, NalarProfile> = {}
  for (const p of list) {
    const { name, ...rest } = p
    out[name] = rest
  }
  return out
}

function parseMcpServers(
  raw: Record<string, { url: string; headers?: Record<string, string> }> | undefined,
): McpServer[] {
  if (!raw) return []
  const out: McpServer[] = []
  for (const [name, server] of Object.entries(raw)) {
    if (!server || typeof server.url !== 'string' || !server.url) continue
    const headers = server.headers
      ? Object.entries(server.headers).map(([key, value]) => ({ key, value: String(value ?? '') }))
      : []
    out.push({ name, url: server.url, headers })
  }
  out.sort((a, b) => a.name.localeCompare(b.name))
  return out
}

function serializeMcpServers(
  list: McpServer[],
): Record<string, { url: string; headers?: Record<string, string> }> | undefined {
  if (list.length === 0) return undefined
  const out: Record<string, { url: string; headers?: Record<string, string> }> = {}
  for (const server of list) {
    if (!server.name || !server.url) continue
    const headers: Record<string, string> = {}
    for (const h of (server.headers ?? [])) if (h.key) headers[h.key] = h.value
    out[server.name] = { url: server.url, ...(Object.keys(headers).length ? { headers } : {}) }
  }
  return Object.keys(out).length ? out : undefined
}

// Populate section refs when the central config first loads.
watch(
  loaded,
  (isLoaded) => { if (isLoaded) syncFromConfig() },
  { immediate: true },
)

// Whenever any section ref mutates, push back to the central config
// (which keeps the composable's dirty counter in sync).
watch(
  [defaultsConfig, profilesList, activeProfile, subAgentsList, mcpServersList],
  () => { if (loaded.value) syncToConfig() },
  { deep: true },
)

// ─── Modal state ──────────────────────────────────────────────────────────
type ProfileModalState = { mode: 'add' | 'edit'; value: LlmConfigModalValue } | null
/**
 * Where a sub-agent is being added/edited. The same `SubAgentModal`
 * component is used for both the top-level Sub-agents tab and the
 * per-profile override; the `scope` field tells the save handler
 * which list to push the result into.
 */
type SubAgentScope = { kind: 'top' } | { kind: 'profile'; profileName: string }
type SubAgentModalState = {
  mode: 'add' | 'edit'
  scope: SubAgentScope
  value: SubAgentModalValue
} | null
type McpServerModalState = { mode: 'add' | 'edit'; value: McpServerModalValue } | null

const profileModal = ref<ProfileModalState>(null)
const subAgentModal = ref<SubAgentModalState>(null)
const mcpServerModal = ref<McpServerModalState>(null)

const profileErrors = ref<{ name?: string; model?: string; base_url?: string; api_key?: string }>({})
const subAgentErrors = ref<{ name?: string; model?: string; base_url?: string; api_key?: string }>({})
const mcpServerErrors = ref<{ name?: string; url?: string }>({})

// ─── Section event handlers ──────────────────────────────────────────────
function startAddProfile() {
  profileModal.value = {
    mode: 'add',
    value: { name: '', config: { model: '', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '', max_capacity_tokens: null, compaction_threshold_percent: null, thinking_budget_tokens: null, reasoning_effort: null } },
  }
}
function startEditProfile(p: ProfileRow) {
  profileModal.value = {
    mode: 'edit',
    value: {
      name: p.name,
      config: {
        model: p.model ?? '', base_url: p.base_url ?? '', thinking: p.thinking ?? 'auto',
        temperature: p.temperature ?? 'auto', url_style: p.url_style ?? 'openai',
        api_key: p.api_key ?? '',
        // Compaction overrides — plan 2026-07-07-compaction-inline.
        max_capacity_tokens: p.max_capacity_tokens ?? null,
        compaction_threshold_percent: p.compaction_threshold_percent ?? null,
        // Model-thinking knobs (plan 2026-08-23-model-thinking).
        // Hydrate from the loaded profile so the form re-opens
        // with the previously-saved budget / effort.
        thinking_budget_tokens: p.thinking_budget_tokens ?? null,
        reasoning_effort: p.reasoning_effort ?? null,
      },
    },
  }
}
function closeProfileModal() { profileModal.value = null; profileErrors.value = {} }
function saveProfile() {
  if (!profileModal.value) return
  const v = profileModal.value.value
  const name = v.name.trim()
  if (!name) { profileErrors.value = { name: 'Name is required' }; return }
  if (!v.config.model.trim()) { profileErrors.value = { model: 'Model is required' }; return }
  if (profileModal.value.mode === 'add') {
    profilesList.value = [...profilesList.value, { name, ...v.config, sub_agents: [] }]
  } else {
    profilesList.value = profilesList.value.map(p => p.name === name ? { ...p, ...v.config, sub_agents: p.sub_agents } : p)
  }
  closeProfileModal()
}
function deleteProfile(name: string) {
  // Optimistic local removal; the API call is best-effort.
  const previous = profilesList.value
  const previousActive = activeProfile.value
  profilesList.value = profilesList.value.filter(p => p.name !== name)
  if (activeProfile.value === name) activeProfile.value = null
  apiDeleteProfile(name).catch(err => {
    profilesList.value = previous
    activeProfile.value = previousActive
    emit('notification', `Failed to delete profile "${name}": ${err instanceof Error ? err.message : String(err)}`, 'error')
  })
}

function startAddSubAgent() {
  subAgentModal.value = {
    mode: 'add',
    scope: { kind: 'top' },
    value: { name: '', system_prompt: '', config: { model: '', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '', max_capacity_tokens: null, compaction_threshold_percent: null, thinking_budget_tokens: null, reasoning_effort: null } },
  }
}
function startEditSubAgent(sa: SubAgent) {
  subAgentModal.value = {
    mode: 'edit',
    scope: { kind: 'top' },
    value: {
      name: sa.name,
      system_prompt: sa.system_prompt ?? '',
      config: {
        model: sa.model ?? '', base_url: sa.base_url ?? '', thinking: sa.thinking ?? 'auto',
        temperature: sa.temperature ?? 'auto', url_style: sa.url_style ?? 'openai',
        api_key: sa.api_key ?? '',
        // Compaction overrides (plan 2026-07-07-compaction-inline) — not
        // currently editable in the sub-agent modal but required by
        // LlmConfig type.
        max_capacity_tokens: null,
        compaction_threshold_percent: null,
        // Model-thinking knobs (plan 2026-08-23-model-thinking).
        // These ARE editable in the LlmConfigForm when the user
        // opens the sub-agent modal and switches Thinking on — the
        // modal forwards them through the LlmConfigForm embedded
        // here. We hydrate from the loaded SubAgent so an edit
        // returns to the previously-saved values.
        thinking_budget_tokens: sa.thinking_budget_tokens ?? null,
        reasoning_effort: sa.reasoning_effort ?? null,
      },
    },
  }
}
function startAddSubAgentInProfile(profileName: string) {
  subAgentModal.value = {
    mode: 'add',
    scope: { kind: 'profile', profileName },
    value: { name: '', system_prompt: '', config: { model: '', base_url: '', thinking: 'auto', temperature: 'auto', url_style: 'openai', api_key: '', max_capacity_tokens: null, compaction_threshold_percent: null, thinking_budget_tokens: null, reasoning_effort: null } },
  }
}
function startEditSubAgentInProfile(profileName: string, sa: SubAgent) {
  subAgentModal.value = {
    mode: 'edit',
    scope: { kind: 'profile', profileName },
    value: {
      name: sa.name,
      system_prompt: sa.system_prompt ?? '',
      config: {
        model: sa.model ?? '', base_url: sa.base_url ?? '', thinking: sa.thinking ?? 'auto',
        temperature: sa.temperature ?? 'auto', url_style: sa.url_style ?? 'openai',
        api_key: sa.api_key ?? '',
        // Compaction overrides (plan 2026-07-07-compaction-inline) —
        // required by LlmConfig type. Sub-agent-level overrides
        // currently cascade from the parent profile (Chunk 7).
        max_capacity_tokens: null,
        compaction_threshold_percent: null,
        // Model-thinking knobs (plan 2026-08-23-model-thinking).
        // Mirrors the top-level edit mapper above — hydrate from
        // the loaded SubAgent's values.
        thinking_budget_tokens: sa.thinking_budget_tokens ?? null,
        reasoning_effort: sa.reasoning_effort ?? null,
      },
    },
  }
}
function closeSubAgentModal() { subAgentModal.value = null; subAgentErrors.value = {} }
function saveSubAgent() {
  if (!subAgentModal.value) return
  const v = subAgentModal.value.value
  const name = v.name.trim()
  if (!name) { subAgentErrors.value = { name: 'Name is required' }; return }
  const next: SubAgent = { name, ...v.config, system_prompt: v.system_prompt }
  const scope = subAgentModal.value.scope
  if (scope.kind === 'top') {
    if (subAgentModal.value.mode === 'add') {
      subAgentsList.value = [...subAgentsList.value, next]
    } else {
      subAgentsList.value = subAgentsList.value.map(s => s.name === name ? next : s)
    }
  } else {
    const profileName = scope.profileName
    const mode = subAgentModal.value.mode
    profilesList.value = profilesList.value.map(p => {
      if (p.name !== profileName) return p
      const subs = p.sub_agents ?? []
      const exists = subs.some(s => s.name === name)
      const nextSubs = mode === 'add'
        ? (exists ? subs : [...subs, next])
        : subs.map(s => s.name === name ? next : s)
      return { ...p, sub_agents: nextSubs }
    })
  }
  closeSubAgentModal()
}
function deleteSubAgent(name: string) {
  subAgentsList.value = subAgentsList.value.filter(s => s.name !== name)
}
function deleteSubAgentInProfile(profileName: string, subAgentName: string) {
  profilesList.value = profilesList.value.map(p => {
    if (p.name !== profileName) return p
    return { ...p, sub_agents: (p.sub_agents ?? []).filter(s => s.name !== subAgentName) }
  })
}

function startAddMcpServer() {
  mcpServerModal.value = {
    mode: 'add',
    value: { name: '', url: '', headers: [] },
  }
}
function startEditMcpServer(server: McpServer) {
  mcpServerModal.value = {
    mode: 'edit',
    value: { name: server.name, url: server.url, headers: (server.headers ?? []).map(h => ({ ...h })) },
  }
}
function closeMcpServerModal() { mcpServerModal.value = null; mcpServerErrors.value = {} }
function saveMcpServer() {
  if (!mcpServerModal.value) return
  const v = mcpServerModal.value.value
  const name = v.name.trim()
  const url = v.url.trim()
  if (!name) { mcpServerErrors.value = { name: 'Name is required' }; return }
  if (!url) { mcpServerErrors.value = { url: 'URL is required' }; return }
  const next: McpServer = { name, url, headers: v.headers.filter(h => h.key.length > 0) }
  if (mcpServerModal.value.mode === 'add') {
    mcpServersList.value = [...mcpServersList.value, next]
  } else {
    mcpServersList.value = mcpServersList.value.map(s => s.name === name ? next : s)
  }
  closeMcpServerModal()
}
function deleteMcpServer(name: string) {
  mcpServersList.value = mcpServersList.value.filter(s => s.name !== name)
}

// ─── Set active (instant — no dirty pill, immediate save) ───────────────
const isSettingActive = ref(false)
async function setActiveProfile(name: string) {
  activeProfile.value = name
  isSettingActive.value = true
  try {
    await saveNalarConfig({ ...config.value, active_profile: name } as NalarConfig)
    emit('notification', `Active profile set to "${name}"`, 'success')
  } catch (err) {
    emit('notification', `Failed to set active: ${err instanceof Error ? err.message : String(err)}`, 'error')
  } finally {
    isSettingActive.value = false
  }
}

// Clear the active profile — same instant-save path as setActiveProfile,
// but writes `active_profile: ""` (empty string) to config.json. The
// `nalar_config_put.zig:246-252` handler treats an empty `active_profile`
// value as "clear" (sets `config_json.active_profile = null` on disk).
//
// Why empty string and not `undefined` / JSON null?
// Pre-fix the frontend sent `active_profile: undefined`, which JSON.stringify
// strips to no key in the PUT body. The backend's `?[]const u8` type
// couldn't distinguish "key absent" from "key: null" — both yielded
// `None` and the handler skipped the field. Using `undefined` left the
// user's "Set active" default in place (the Reset button silently
// failed). The empty-string sentinel works within the existing wire
// contract — the handler at nalar_config_put.zig:250 already maps
// `ap.len == 0` to "clear" exactly for this purpose.
//
// Mirrors the existing `setActiveProfile` flow so the UI feedback
// (success / error notification) is consistent.
async function clearActiveProfile() {
  const previous = activeProfile.value
  activeProfile.value = null
  isSettingActive.value = true
  try {
    await saveNalarConfig({ ...config.value, active_profile: '' } as NalarConfig)
    emit('notification', `Active profile cleared — using top-level config`, 'success')
  } catch (err) {
    activeProfile.value = previous // optimistic-rollback on failure
    emit('notification', `Failed to clear active: ${err instanceof Error ? err.message : String(err)}`, 'error')
  } finally {
    isSettingActive.value = false
  }
}

// ─── Save / Reset ────────────────────────────────────────────────────────
async function handleSave() {
  try {
    await save()
    emit('notification', 'Settings saved', 'success')
  } catch (err) {
    emit('notification', `Save failed: ${err instanceof Error ? err.message : String(err)}`, 'error')
  }
}

function handleReset() {
  reset()
  syncFromConfig()
}

// ─── Confirm dialog for profile delete ───────────────────────────────────
const confirmingDeleteProfile = ref<string | null>(null)
function requestDeleteProfile(name: string) { confirmingDeleteProfile.value = name }
function cancelDeleteProfile() { confirmingDeleteProfile.value = null }
function confirmDeleteProfile() {
  const name = confirmingDeleteProfile.value
  if (!name) return
  confirmingDeleteProfile.value = null
  deleteProfile(name)
}

// ─── Computed ────────────────────────────────────────────────────────────
const isLoading = computed(() => !loaded.value)
</script>

<template>
  <div class="flex flex-col h-full" data-testid="nalar-settings">
    <!-- Loading state -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center text-sm" style="color: var(--semantic-text-muted);">
      Loading settings…
    </div>

    <template v-else>
      <!-- Tab strip -->
      <div class="shrink-0 px-1 pt-1">
        <NalarTabStrip v-model="activeTab" />
      </div>

      <!-- Scrollable tab content -->
      <div class="flex-1 overflow-y-auto p-6 space-y-6">
        <DefaultsSection
          v-if="activeTab === 'defaults'"
          v-model="defaultsConfig!"
        />

        <ProfilesSection
          v-else-if="activeTab === 'profiles'"
          v-model="profilesList"
          :active-profile="activeProfile"
          @set-active="setActiveProfile"
          @clear-active="clearActiveProfile"
          @edit="startEditProfile"
          @delete="requestDeleteProfile"
          @add="startAddProfile"
          @add-sub-agent="startAddSubAgentInProfile"
          @edit-sub-agent="startEditSubAgentInProfile"
          @delete-sub-agent="deleteSubAgentInProfile"
        />

        <SubAgentsSection
          v-else-if="activeTab === 'sub-agents'"
          v-model="subAgentsList"
          @edit="startEditSubAgent"
          @delete="deleteSubAgent"
          @add="startAddSubAgent"
        />

        <McpServersSection
          v-else-if="activeTab === 'mcp'"
          v-model="mcpServersList"
          @edit="startEditMcpServer"
          @delete="deleteMcpServer"
          @add="startAddMcpServer"
        />
        <!-- Plan 2026-07-07-compaction-inline: the dedicated Compaction
             tab is REMOVED. Compaction settings now live in the Defaults
             tab (top-level defaults) + the Edit-profile modal
             (per-profile overrides). The tab id 'compaction' was removed
             from NalarTabStrip.vue. -->
      </div>

      <!-- Sticky save bar (only when dirty) -->
      <div class="shrink-0">
        <NalarSaveBar
          :dirty="dirty"
          :unsaved-count="unsavedCount"
          :saving="saving"
          @reset="handleReset"
          @save="handleSave"
        />
      </div>
    </template>

    <!-- Modals -->
    <ProfileModal
      v-if="profileModal"
      v-model="profileModal.value"
      :errors="profileErrors"
      :mode="profileModal.mode"
      @cancel="closeProfileModal"
      @save="saveProfile"
    />

    <SubAgentModal
      v-if="subAgentModal"
      v-model="subAgentModal.value"
      :errors="subAgentErrors"
      :mode="subAgentModal.mode"
      @cancel="closeSubAgentModal"
      @save="saveSubAgent"
    />

    <McpServerModal
      v-if="mcpServerModal"
      v-model="mcpServerModal.value"
      :errors="mcpServerErrors"
      :mode="mcpServerModal.mode"
      @cancel="closeMcpServerModal"
      @save="saveMcpServer"
    />

    <!-- Confirm delete dialog -->
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
</template>

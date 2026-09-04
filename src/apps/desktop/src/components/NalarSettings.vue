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
import NalarGeneralSection, { type NalarGeneralSettings } from './nalar/NalarGeneralSection.vue'
import ProfilesSection, { type ProfileRow } from './nalar/ProfilesSection.vue'
// Plan 2026-09-04-subagents-per-profile: SubAgentsSection.vue is no longer
// mounted here (no global list). The file is kept for now — see note below.
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
// Plan 2026-08-24-config-simplify-remove-defaults: 'defaults' tab removed.
// Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: 'general' tab
// added as the FIRST tab — operational settings (notification toggles +
// retry delay) are the broadest, most-frequently-touched UI surface.
// Plan 2026-09-04-subagents-per-profile: 'sub-agents' tab removed —
// sub-agents live inside each profile row (Profiles tab expand chevron).
type Tab = 'general' | 'profiles' | 'mcp'
const activeTab = ref<Tab>('general')

// ─── Central config (useNalarConfig composable) ──────────────────────────
const { config, loaded, dirty, unsavedCount, saving, setConfig, save, reset } = useNalarConfig()

onMounted(async () => {
  // Plan 2026-08-24-config-simplify-remove-defaults: the legacy
  // localStorage fallback (which existed solely to seed the removed
  // Defaults form) is gone. The API response is the only source.
  let apiData: NalarConfig | null = null
  try {
    apiData = await getNalarConfig()
  } catch {
    // Network/API failure — start with an empty config.
    apiData = {}
  }
  setConfig(apiData)
})

// ─── Per-section view state ──────────────────────────────────────────────
const profilesList = ref<ProfileRow[]>([])
const activeProfile = ref<string | null>(null)
// Plan 2026-09-04-subagents-per-profile: no global list — per-profile
// `profilesList[].sub_agents` is the only editor.
const mcpServersList = ref<McpServer[]>([])

// Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the General
// tab uses a single `defineModel<NalarGeneralSettings>` v-model surface
// in NalarGeneralSection.vue. The orchestrator hydrates from the loaded
// config on first load, and writes back through `syncToConfig` when the
// user mutates a control. Each of the three keys is a top-level
// `NalarConfig` field — `notify_on_complete`, `notify_on_error`,
// `retry_delay_ms` — so the diff in `useNalarConfig` tracks them as
// primitives.
const generalSettings = ref<NalarGeneralSettings>({
  notify_on_complete: false,
  notify_on_error: false,
  retry_delay_ms: 0,
})

function syncFromConfig() {
  if (!config.value) return
  const c = config.value
  profilesList.value = Object.entries(c.profiles ?? {}).map(([name, p]) => ({
    name,
    model: p.model ?? '',
    base_url: p.base_url ?? '',
    thinking: p.thinking ?? 'auto',
    temperature: p.temperature ?? 'auto',
    url_style: p.url_style ?? 'openai',
    api_key: p.api_key ?? '',
    sub_agents: p.sub_agents ?? [],
    // Compaction overrides — both top-level and per-profile coexist. Each layer cascades over the
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
  // Plan 2026-09-04-subagents-per-profile: top-level `sub_agents` is
  // always null from the backend — intentionally NOT hydrated anywhere.
  mcpServersList.value = parseMcpServers(c.mcp_servers)

  // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: hydrate
  // the General tab from the loaded config. Three top-level fields,
  // each defaulted to a safe zero so a missing-on-disk config still
  // renders without crashing (the orchestrator's diff treats missing
  // and explicit zero as different — see useNalarConfig.spec.ts).
  generalSettings.value = {
    notify_on_complete: c.notify_on_complete ?? false,
    notify_on_error: c.notify_on_error ?? false,
    // Treat `undefined` (missing key) and explicit 0 the same way so
    // the dirty pill doesn't flash on first load when the field is
    // absent from config.json.
    retry_delay_ms: c.retry_delay_ms ?? 0,
  }
}

function syncToConfig() {
  if (!config.value) return
  const c = config.value
  // Only write list fields when non-empty, so the structural shape
  // of the config stays close to the original (loaded) snapshot. The
  // composable's diff treats `undefined` and missing keys as
  // equivalent, but it can't tell the difference between "user
  // deleted everything" and "user never had anything here" if we
  // always materialize empty objects/arrays.
  //
  // Plan 2026-08-24-config-simplify-remove-defaults: the top-level LLM
  // defaults are no longer sent — profiles + operational settings only.
  const profiles = profilesToRecord(profilesList.value)
  const mcpServers = serializeMcpServers(mcpServersList.value)
  config.value = {
    ...c,
    // Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
    // three operational settings are driven by the General tab
    // (`generalSettings`). Always write them through so toggling
    // surfaces in the dirty pill + save bar.
    notify_on_complete: generalSettings.value.notify_on_complete,
    notify_on_error: generalSettings.value.notify_on_error,
    retry_delay_ms: generalSettings.value.retry_delay_ms,
    // Top-level compaction defaults — plan 2026-07-07-compaction-inline.
    // Unconditional spread so `null` is preserved (cascade wildcard).
    max_capacity_token_model: c.max_capacity_token_model,
    compaction_threshold_percent: c.compaction_threshold_percent,
    // Per-profile compaction overrides still live on `profiles` below.
    ...(Object.keys(profiles).length > 0 ? { profiles } : {}),
    ...(activeProfile.value ? { active_profile: activeProfile.value } : {}),
    // Plan 2026-09-04-subagents-per-profile: never send top-level
    // `sub_agents` — per-profile lists ride inside `profiles` above.
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

/**
 * Raw wire shape of a single MCP server entry as it appears in
 * config.json's `mcp_servers` map. Discriminated union matching the
 * type on `NalarConfig.mcp_servers` (api/index.ts):
 * - presence of `command` ⇒ stdio
 * - presence of `url` ⇒ http
 * We use the union form (not a struct with all-optional fields) so
 * TypeScript can discriminate `command: string` from `command: undefined`
 * when we type-narrow on `typeof server.command === 'string'`.
 */
type RawMcpServerEntry =
  | { url: string; headers?: Record<string, string> }
  | { command: string; args?: string[]; env?: string[]; cwd?: string }

function parseMcpServers(
  raw: Record<string, RawMcpServerEntry> | undefined,
): McpServer[] {
  if (!raw) return []
  const out: McpServer[] = []
  for (const [name, server] of Object.entries(raw)) {
    if (!server) continue
    // Transport discriminator: presence of `command` ⇒ stdio,
    // presence of `url` ⇒ http. Legacy entries (url-only) hydrate as
    // http. Entries with neither are silently dropped.
    if ('command' in server && typeof server.command === 'string' && server.command.length > 0) {
      out.push({
        name,
        transport: 'stdio',
        command: server.command,
        args: Array.isArray(server.args) ? server.args.map((a: string) => a) : [],
        env: Array.isArray(server.env) ? server.env.map((e: string) => e) : [],
        cwd: typeof server.cwd === 'string' ? server.cwd : '',
        url: '',
        headers: [],
      })
    } else if ('url' in server && typeof server.url === 'string' && server.url.length > 0) {
      const headers = server.headers
        ? Object.entries(server.headers).map(([key, value]) => ({ key, value: String(value ?? '') }))
        : []
      out.push({
        name,
        transport: 'http',
        url: server.url,
        headers,
        command: '',
        args: [],
        env: [],
        cwd: '',
      })
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name))
  return out
}

function serializeMcpServers(
  list: McpServer[],
): Record<string, RawMcpServerEntry> | undefined {
  if (list.length === 0) return undefined
  const out: Record<string, RawMcpServerEntry> = {}
  for (const server of list) {
    if (!server.name) continue
    if (server.transport === 'stdio') {
      if (!server.command) continue
      const entry: RawMcpServerEntry = { command: server.command }
      if (server.args && server.args.length) entry.args = server.args
      if (server.env && server.env.length) entry.env = server.env
      if (server.cwd && server.cwd.length) entry.cwd = server.cwd
      out[server.name] = entry
    } else {
      // Default to http for legacy entries that lack an explicit
      // transport field.
      const url = server.url ?? ''
      if (!url) continue
      const headers: Record<string, string> = {}
      for (const h of (server.headers ?? [])) if (h.key) headers[h.key] = h.value
      out[server.name] = { url, ...(Object.keys(headers).length ? { headers } : {}) }
    }
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
  [profilesList, activeProfile, mcpServersList, generalSettings],
  () => { if (loaded.value) syncToConfig() },
  { deep: true },
)

// ─── Modal state ──────────────────────────────────────────────────────────
type ProfileModalState = { mode: 'add' | 'edit'; value: LlmConfigModalValue } | null
/**
 * Where a sub-agent is being added/edited. Plan
 * 2026-09-04-subagents-per-profile: per-profile only — the `scope`
 * always carries the owning profile name (the old `{ kind: 'top' }`
 * global scope is gone with the Sub-agents tab).
 */
type SubAgentScope = { kind: 'profile'; profileName: string }
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
const mcpServerErrors = ref<{ name?: string; url?: string; command?: string }>({})

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
  // Plan 2026-09-04-subagents-per-profile: profile scope only — the
  // top-level branch is gone with the Sub-agents tab.
  const profileName = subAgentModal.value.scope.profileName
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
  closeSubAgentModal()
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
    value: {
      name: '',
      transport: 'stdio', // default for new entries — stdio is the
      // canonical MCP transport and the user added it specifically for
      // that. Legacy callers can pass `initialTransport='http'` if
      // they need the old behaviour.
      url: '',
      headers: [],
      command: '',
      args: [],
      env: [],
      cwd: '',
    },
  }
}
function startEditMcpServer(server: McpServer) {
  mcpServerModal.value = {
    mode: 'edit',
    value: {
      name: server.name,
      transport: server.transport ?? 'http',
      url: server.url ?? '',
      headers: (server.headers ?? []).map(h => ({ ...h })),
      command: server.command ?? '',
      args: (server.args ?? []).slice(),
      env: (server.env ?? []).slice(),
      cwd: server.cwd ?? '',
    },
  }
}
function closeMcpServerModal() { mcpServerModal.value = null; mcpServerErrors.value = {} }
function saveMcpServer() {
  if (!mcpServerModal.value) return
  const v = mcpServerModal.value.value
  const name = v.name.trim()
  if (!name) { mcpServerErrors.value = { name: 'Name is required' }; return }
  const isStdio = v.transport === 'stdio'
  if (isStdio) {
    if (!v.command.trim()) {
      mcpServerErrors.value = { command: 'Command is required' }
      return
    }
    const next: McpServer = {
      name,
      transport: 'stdio',
      command: v.command.trim(),
      args: v.args,
      env: v.env,
      cwd: v.cwd.trim(),
      headers: [],
    }
    if (mcpServerModal.value.mode === 'add') {
      mcpServersList.value = [...mcpServersList.value, next]
    } else {
      mcpServersList.value = mcpServersList.value.map(s => s.name === name ? next : s)
    }
  } else {
    const url = v.url.trim()
    if (!url) { mcpServerErrors.value = { url: 'URL is required' }; return }
    const next: McpServer = {
      name,
      transport: 'http',
      url,
      headers: v.headers.filter(h => h.key.length > 0),
    }
    if (mcpServerModal.value.mode === 'add') {
      mcpServersList.value = [...mcpServersList.value, next]
    } else {
      mcpServersList.value = mcpServersList.value.map(s => s.name === name ? next : s)
    }
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
        <NalarGeneralSection
          v-if="activeTab === 'general'"
          v-model="generalSettings"
        />

        <ProfilesSection
          v-if="activeTab === 'profiles'"
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

        <!-- Plan 2026-09-04-subagents-per-profile: the global Sub-agents
             tab is removed. Sub-agents are edited inline inside each
             profile row (Profiles tab → expand chevron → + Add sub-agent).
             SubAgentsSection.vue is kept on disk but no longer mounted. -->
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

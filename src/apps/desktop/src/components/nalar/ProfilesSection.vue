<script setup lang="ts">
import { ref } from 'vue'

import EmptyState from './EmptyState.vue'
import type { NalarProfile, SubAgent } from '../../api'

/**
 * One row in the Profiles tab. The backend stores profiles as
 * `Record<name, NalarProfile>` (name is the map key, not a field on
 * the profile object). The orchestrator flattens this into an array
 * of `ProfileRow` with the name attached so the UI can iterate
 * cleanly.
 *
 * `sub_agents` is the profile's OWN sub-agent list (plan
 * 2026-09-04-subagents-per-profile: per-profile only, no global list,
 * no inheritance). Each profile owns its sub-agents; sessions that use
 * this profile resolve `spawn_sub_agent` names against this list only.
 */
export interface ProfileRow extends NalarProfile {
  name: string
  sub_agents: SubAgent[]
}

defineProps<{
  modelValue: ProfileRow[]
  activeProfile: string | null
}>()

const emit = defineEmits<{
  setActive: [name: string]
  /// Reset the active profile to "no active" — emitted when the user
  /// clicks the Reset button next to the active pill. Parent saves
  /// `active_profile: null` to config.json; the backend cascade then
  /// falls through to top-level config for every new chat / task.
  clearActive: []
  edit: [profile: ProfileRow]
  delete: [name: string]
  add: []
  addSubAgent: [profileName: string]
  editSubAgent: [profileName: string, subAgent: SubAgent]
  deleteSubAgent: [profileName: string, subAgentName: string]
}>()

// Map of profile name -> expanded state. Local to this component;
// the orchestrator does not need to know which profile is expanded.
const expanded = ref<Record<string, boolean>>({})

function toggleExpand(name: string) {
  expanded.value = { ...expanded.value, [name]: !expanded.value[name] }
}
function isExpanded(name: string): boolean {
  return expanded.value[name] === true
}

/**
 * Compact compaction summary for the profile row.
 * Format: "threshold% @ capacity tokens" when overrides are set,
 * "default" when both fields are null. The exact wording is a UX
 * choice — picked to fit the existing summary line style.
 */
function compactionSummary(profile: ProfileRow): string {
  const cap = profile.max_capacity_tokens
  const thr = profile.compaction_threshold_percent
  const capStr =
    cap === null || cap === undefined
      ? 'default'
      : `${(cap / 1000).toFixed(0)}k tokens`
  const thrStr = thr === null || thr === undefined ? 'default (80%)' : `${thr}%`
  // Compact format: "80% @ 500k" or "default (80%) @ default" or similar.
  return `${thrStr} @ ${capStr}`
}
</script>

<template>
  <div class="space-y-4">
    <!-- Header with active pill + reset button + add button -->
    <div class="flex items-center justify-between">
      <div class="flex items-center gap-2">
        <span class="text-xs font-mono" style="color: var(--semantic-text-dim);">Active</span>
        <span
          v-if="activeProfile"
          data-testid="active-pill"
          class="text-xs px-2 h-6 inline-flex items-center rounded-md font-mono"
          style="background-color: var(--color-violet); color: #181616;"
        >{{ activeProfile }}</span>
        <span
          v-else
          class="text-xs italic"
          style="color: var(--semantic-text-dim);"
        >(none — pick one below)</span>
        <!-- Reset: only when a profile is currently active. Clears
             active_profile in config.json so the backend cascade falls
             through to top-level config. -->
        <button
          v-if="activeProfile"
          type="button"
          data-testid="reset-active-btn"
          :title="`Clear active profile — every chat will use the top-level config`"
          @click="emit('clearActive')"
          class="px-2 h-6 rounded-md text-[10px] font-mono border transition-colors duration-150 hover:opacity-80"
          style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
        >Reset</button>
      </div>
      <button
        type="button"
        data-testid="add-btn"
        @click="emit('add')"
        class="px-3 h-8 rounded-md text-xs font-medium border transition-colors duration-150"
        style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
      >+ Add profile</button>
    </div>

    <!-- Empty state -->
    <EmptyState
      v-if="modelValue.length === 0"
      data-testid="empty-state"
      glyph="⌗"
      title="No profiles yet"
      description="Profiles are saved LLM configurations you can switch between with one click. Useful for separate API keys, models, or thinking settings."
      cta-label="+ Add profile"
      :cta-action="() => emit('add')"
    />

    <!-- List -->
    <ul v-else class="space-y-2" data-testid="profile-list">
      <li
        v-for="profile in modelValue"
        :key="profile.name"
        class="rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <!-- Row: chevron + name + active + model + buttons -->
        <div class="flex items-center justify-between gap-3 px-4 py-3">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <button
                type="button"
                :aria-label="isExpanded(profile.name) ? `Collapse sub-agents for ${profile.name}` : `Expand sub-agents for ${profile.name}`"
                :aria-expanded="isExpanded(profile.name)"
                :data-testid="`expand-btn-${profile.name}`"
                @click="toggleExpand(profile.name)"
                class="w-4 h-4 flex items-center justify-center text-xs font-mono hover:opacity-80"
                style="color: var(--semantic-text-muted);"
              >{{ isExpanded(profile.name) ? '▼' : '▶' }}</button>
              <span
                v-if="activeProfile === profile.name"
                class="w-1.5 h-1.5 rounded-full"
                style="background-color: var(--color-violet);"
                aria-label="Active"
              />
              <span class="text-sm font-medium" style="color: var(--semantic-text);">{{ profile.name }}</span>
              <span
                v-if="activeProfile === profile.name"
                class="text-[10px] px-1.5 h-5 inline-flex items-center rounded font-mono"
                style="background-color: var(--color-violet); color: #181616;"
              >active</span>
            </div>
            <div class="text-xs font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
              {{ profile.model }} · {{ profile.base_url || '—' }}
            </div>
            <div class="text-xs font-mono mt-1" style="color: var(--semantic-text-dim);">
              <template v-if="profile.sub_agents && profile.sub_agents.length > 0">
                <span style="color: var(--color-violet);">▾ {{ profile.sub_agents.length }} sub-agent{{ profile.sub_agents.length === 1 ? '' : 's' }}</span>
              </template>
              <template v-else>
                <span>· no sub-agents</span>
              </template>
            </div>
            <!-- Compaction summary (plan 2026-07-07-compaction-inline):
                 show the effective compaction for this profile (with
                 explicit overrides) or "default" when no override is
                 set. Clicking Edit still opens the full modal where
                 the override can be toggled. -->
            <div
              class="text-xs font-mono mt-0.5 truncate"
              style="color: var(--semantic-text-dim);"
              data-testid="compaction-summary"
            >
              Compaction: {{ compactionSummary(profile) }}
            </div>
          </div>
          <div class="flex items-center gap-1.5 shrink-0">
            <button
              v-if="activeProfile !== profile.name"
              type="button"
              data-testid="set-active-btn"
              @click="emit('setActive', profile.name)"
              class="px-2.5 h-7 rounded-md text-xs border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Set active</button>
            <button
              type="button"
              data-testid="edit-btn"
              @click="emit('edit', profile)"
              class="px-2.5 h-7 rounded-md text-xs border transition-colors duration-150"
              style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
            >Edit</button>
            <button
              type="button"
              data-testid="delete-btn"
              @click="emit('delete', profile.name)"
              class="px-2.5 h-7 rounded-md text-xs transition-colors duration-150"
              style="color: var(--color-red);"
              aria-label="Delete profile"
            >⌫</button>
          </div>
        </div>

        <!-- Expanded: per-profile sub-agents list -->
        <div
          v-if="isExpanded(profile.name)"
          :data-testid="`sub-agents-list-${profile.name}`"
          class="border-t px-4 py-3 space-y-2"
          style="border-color: var(--color-border);"
        >
          <div
            v-if="!profile.sub_agents || profile.sub_agents.length === 0"
            class="text-xs italic py-1"
            style="color: var(--semantic-text-dim);"
          >
            No sub-agents yet. Add one below — each profile owns its sub-agents.
          </div>
          <ul v-else class="space-y-2">
            <li
              v-for="sa in profile.sub_agents"
              :key="sa.name"
              class="px-3 py-2 rounded"
              style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border-light);"
              :data-testid="`profile-sub-agent-${profile.name}-${sa.name}`"
            >
              <div class="flex items-center justify-between gap-2">
                <div class="flex-1 min-w-0">
                  <div class="text-xs font-medium" style="color: var(--semantic-text);">{{ sa.name }}</div>
                  <div class="text-xs font-mono mt-0.5 truncate" style="color: var(--semantic-text-dim);">
                    {{ sa.model }} · {{ sa.base_url || '—' }}
                  </div>
                  <div
                    v-if="sa.system_prompt"
                    class="text-xs mt-1 line-clamp-2"
                    style="color: var(--semantic-text-muted); white-space: pre-wrap;"
                  >{{ sa.system_prompt }}</div>
                </div>
                <div class="flex items-center gap-1 shrink-0">
                  <button
                    type="button"
                    :data-testid="`edit-sub-agent-btn-${profile.name}-${sa.name}`"
                    @click="emit('editSubAgent', profile.name, sa)"
                    class="px-2 h-6 rounded text-xs border transition-colors duration-150"
                    style="border-color: var(--color-border); color: var(--semantic-text-muted); background-color: transparent;"
                  >Edit</button>
                  <button
                    type="button"
                    :data-testid="`delete-sub-agent-btn-${profile.name}-${sa.name}`"
                    @click="emit('deleteSubAgent', profile.name, sa.name)"
                    class="px-2 h-6 rounded text-xs transition-colors duration-150"
                    style="color: var(--color-red);"
                    :aria-label="`Delete sub-agent ${sa.name}`"
                  >⌫</button>
                </div>
              </div>
            </li>
          </ul>
          <button
            type="button"
            :data-testid="`add-sub-agent-btn-${profile.name}`"
            @click="emit('addSubAgent', profile.name)"
            class="px-2.5 h-7 rounded text-xs font-medium border transition-colors duration-150"
            style="border-color: var(--color-violet); color: var(--color-violet); background-color: transparent;"
          >+ Add sub-agent</button>
        </div>
      </li>
    </ul>
  </div>
</template>

<script setup lang="ts">
import EmptyState from './EmptyState.vue'
import type { NalarProfile } from '../../api'

/**
 * One row in the Profiles tab. The backend stores profiles as
 * `Record<name, NalarProfile>` (name is the map key, not a field on
 * the profile object). The orchestrator flattens this into an array
 * of `ProfileRow` with the name attached so the UI can iterate
 * cleanly.
 */
export interface ProfileRow extends NalarProfile {
  name: string
}

defineProps<{
  modelValue: ProfileRow[]
  activeProfile: string | null
}>()

const emit = defineEmits<{
  setActive: [name: string]
  edit: [profile: ProfileRow]
  delete: [name: string]
  add: []
}>()
</script>

<template>
  <div class="space-y-4">
    <!-- Header with active pill + add button -->
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
        class="flex items-center justify-between gap-3 px-4 py-3 rounded-md"
        style="background-color: var(--semantic-content-bg); border: 1px solid var(--color-border);"
      >
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
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
      </li>
    </ul>
  </div>
</template>

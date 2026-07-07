<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { NalarProfile } from '../../api'

/**
 * CompactionSection — per-profile compaction settings UI.
 *
 * Renders one row per entry in `props.profiles`. Each row exposes two
 * overrides:
 *   - `max_capacity_tokens`: optional override for this profile's
 *     context window (in tokens). null = use built-in default.
 *   - `compaction_threshold_percent`: compaction trigger threshold as
 *     a percentage (0-100). null = use built-in 80.
 *
 * The v-model contract is `{ profiles: Record<string, NalarProfile> }`.
 * We deep-copy on entry so mutating the props (a Vue anti-pattern)
 * can't leak into the parent's source object. We emit the changed
 * profile map as a whole on every change; the parent's `useNalarConfig`
 * composable handles diffing + PUT.
 *
 * Sub-agents inherit from the parent profile unless they override
 * (handled on the backend via the cascade resolver; the frontend
 * only edits per-profile values, not sub-agent overrides).
 */
interface Props {
  profiles: Record<string, NalarProfile>
}
interface Emits {
  /** Emitted on every field change with the new full profiles map. */
  (e: 'update:profiles', profiles: Record<string, NalarProfile>): void
}

const props = defineProps<Props>()
const emit = defineEmits<Emits>()

// Deep-copy the props on mount so we don't mutate the parent's source.
// This is a JSON-roundtrip; LlmProfile only has primitives + nested
// arrays of primitives, so it's safe.
function deepClone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T
}

// Local working copy. Re-sync from props when the parent's `profiles`
// reference changes (e.g., after a save round-trip or a "Reset" click).
const local = ref<Record<string, NalarProfile>>({})
const lastSyncedFromProps = ref<Record<string, NalarProfile>>({})

function syncFromProps() {
  local.value = deepClone(props.profiles ?? {})
  lastSyncedFromProps.value = deepClone(props.profiles ?? {})
}
syncFromProps()
watch(
  () => props.profiles,
  () => syncFromProps(),
)

const dirty = computed<boolean>(
  () => JSON.stringify(local.value) !== JSON.stringify(lastSyncedFromProps.value),
)

const inputBase = 'w-full px-3 h-8 rounded-md border text-sm transition-colors duration-150'
const inputStyle: Record<string, string> = {
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: 'var(--color-border)',
}
const sectionHeader = 'font-mono text-xs uppercase tracking-wider mb-3'
const sectionHeaderStyle: Record<string, string> = { color: 'var(--semantic-text-dim)' }
const labelBase = 'block text-xs font-medium mb-1.5'
const labelStyle: Record<string, string> = { color: 'var(--semantic-text-muted)' }
const helperStyle: Record<string, string> = { color: 'var(--semantic-text-dim)' }
const profileCardStyle: Record<string, string> = {
  backgroundColor: 'var(--semantic-content-bg)',
  borderColor: 'var(--color-border)',
}

// Emit the working copy upward whenever it changes. Parent handles
// dirty tracking + diff + save.
function commit() {
  emit('update:profiles', deepClone(local.value))
}

// ─── Override checkboxes (per profile) ───────────────────────────────────
function isCapacityOverride(profileName: string): boolean {
  return local.value[profileName]?.max_capacity_tokens != null
}
function setCapacityOverride(profileName: string, on: boolean) {
  const profile = local.value[profileName] ?? {}
  profile.max_capacity_tokens = on
    ? (profile.max_capacity_tokens ?? 500000)
    : null;
  local.value[profileName] = profile;
  commit();
}

function isThresholdOverride(profileName: string): boolean {
  return local.value[profileName]?.compaction_threshold_percent != null
}
function setThresholdOverride(profileName: string, on: boolean) {
  const profile = local.value[profileName] ?? {}
  profile.compaction_threshold_percent = on
    ? (profile.compaction_threshold_percent ?? 80)
    : null;
  local.value[profileName] = profile;
  commit();
}

// ─── Capacity input (per profile) ────────────────────────────────────────
function setCapacity(profileName: string, raw: string) {
  const trimmed = raw.trim();
  if (trimmed === '') {
    // Empty input — leave the field as-is. The user is typing and we
    // don't want to commit a transient 0 into the model.
    return;
  }
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed) || parsed < 0) return;
  const profile = local.value[profileName] ?? {};
  profile.max_capacity_tokens = Math.floor(parsed);
  local.value[profileName] = profile;
  commit();
}

// ─── Threshold input (per profile) ───────────────────────────────────────
function setThreshold(profileName: string, v: number) {
  if (!Number.isFinite(v)) return;
  const clamped = Math.max(0, Math.min(100, Math.floor(v)));
  const profile = local.value[profileName] ?? {};
  profile.compaction_threshold_percent = clamped;
  local.value[profileName] = profile;
  commit();
}

// Display helpers — when null, show empty string (so placeholder shows).
function capacityDisplay(profileName: string): string {
  const v = local.value[profileName]?.max_capacity_tokens;
  return v == null ? '' : String(v);
}
function thresholdDisplay(profileName: string): number {
  return local.value[profileName]?.compaction_threshold_percent ?? 80;
}
function modelDisplay(profile: NalarProfile): string {
  return profile.model && profile.model.length > 0 ? profile.model : '(no model)';
}
</script>

<template>
  <div class="space-y-6" data-testid="compaction-section">
    <p class="text-xs" :style="helperStyle">
      Compaction settings are configured <strong>per profile</strong>. When a profile's checkbox
      is unchecked, the backend uses its built-in defaults (200,000 / 500,000 / 200,000-fallback
      tokens for the model context window, 80% for the compaction threshold).
    </p>

    <p v-if="!profiles || Object.keys(profiles).length === 0" class="text-xs italic" :style="helperStyle" data-testid="compaction-empty-state">
      No profiles defined yet. Add one in the Profiles tab to configure per-profile compaction.
    </p>

    <div v-for="(profile, name) in profiles" :key="name" class="space-y-4 rounded-lg border p-4" :style="profileCardStyle" :data-testid="`profile-row-${name}`">
      <div class="flex items-baseline justify-between">
        <h4 class="text-sm font-semibold" :style="{ color: 'var(--semantic-text)' }">
          {{ name }}
        </h4>
        <span class="font-mono text-xs" :style="helperStyle">{{ modelDisplay(profile) }}</span>
      </div>

      <!-- Context window override -->
      <section>
        <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Context window ──</h3>
        <div class="space-y-3">
          <div>
            <label class="flex items-start gap-2 cursor-pointer text-sm">
              <input
                type="checkbox"
                class="w-4 h-4 mt-0.5"
                style="accent-color: var(--color-violet);"
                :checked="isCapacityOverride(name)"
                @change="setCapacityOverride(name, ($event.target as HTMLInputElement).checked)"
                :data-testid="`capacity-override-checkbox-${name}`"
              />
              <span>
                <span :style="labelStyle">Override the model's context window</span>
                <span class="block text-xs mt-0.5" :style="helperStyle">
                  Sets <code class="font-mono">max_capacity_tokens</code> on this profile.
                </span>
              </span>
            </label>
          </div>

          <div :class="{ 'opacity-50 pointer-events-none': !isCapacityOverride(name) }">
            <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
            <input
              :value="capacityDisplay(name)"
              @input="setCapacity(name, ($event.target as HTMLInputElement).value)"
              type="number"
              min="0"
              step="1000"
              placeholder="500000"
              :class="inputBase"
              :style="inputStyle"
              :disabled="!isCapacityOverride(name)"
              :data-testid="`capacity-input-${name}`"
            />
          </div>
        </div>
      </section>

      <!-- Compaction threshold override -->
      <section>
        <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Compaction threshold ──</h3>
        <div class="space-y-3">
          <div>
            <label class="flex items-start gap-2 cursor-pointer text-sm">
              <input
                type="checkbox"
                class="w-4 h-4 mt-0.5"
                style="accent-color: var(--color-violet);"
                :checked="isThresholdOverride(name)"
                @change="setThresholdOverride(name, ($event.target as HTMLInputElement).checked)"
                :data-testid="`threshold-override-checkbox-${name}`"
              />
              <span>
                <span :style="labelStyle">Override the compaction threshold</span>
                <span class="block text-xs mt-0.5" :style="helperStyle">
                  Sets <code class="font-mono">compaction_threshold_percent</code> on this profile.
                  Compact when total tokens ≥ capacity × threshold ÷ 100.
                </span>
              </span>
            </label>
          </div>

          <div :class="{ 'opacity-50 pointer-events-none': !isThresholdOverride(name) }">
            <div class="flex items-center justify-between mb-1.5">
              <label :class="labelBase" :style="labelStyle" class="!mb-0">Threshold (%)</label>
              <span class="font-mono text-xs" :style="labelStyle">{{ thresholdDisplay(name) }}</span>
            </div>
            <input
              :value="thresholdDisplay(name)"
              @input="setThreshold(name, parseFloat(($event.target as HTMLInputElement).value))"
              type="range"
              min="0"
              max="100"
              step="1"
              class="w-full"
              :disabled="!isThresholdOverride(name)"
              :data-testid="`threshold-slider-${name}`"
            />
            <div class="flex justify-between text-xs mt-1 font-mono" :style="helperStyle">
              <span>Never</span>
              <span>80% (default)</span>
              <span>Always</span>
            </div>
          </div>
        </div>
      </section>
    </div>

    <p v-if="dirty" class="text-xs italic" :style="helperStyle">
      Changes are pending — click "Save changes" in the bottom bar to apply.
    </p>
  </div>
</template>
<script setup lang="ts">
import { computed } from 'vue'

/**
 * CompactionConfig — the in-memory shape used by the UI for the
 * compaction settings tab. Both fields are `number | null`:
 * - `null` means "no override — use the backend's built-in default".
 * - A number sets the override (capacity is in tokens, threshold is 0-100).
 *
 * Mirrors the wire-side `NalarConfig.max_capacity_token_model` /
 * `NalarConfig.compaction_threshold_percent` shape from `api/index.ts`,
 * but with `null` for the override-absence case so the user can
 * explicitly choose "use built-in" via the checkbox.
 */
export interface CompactionConfig {
  max_capacity_token_model: number | null
  compaction_threshold_percent: number | null
}

const props = defineProps<{ modelValue: CompactionConfig }>()
const emit = defineEmits<{ 'update:modelValue': [value: CompactionConfig] }>()

function update<K extends keyof CompactionConfig>(key: K, val: CompactionConfig[K]) {
  emit('update:modelValue', { ...props.modelValue, [key]: val })
}

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

// ─── Override checkboxes (two-way) ───────────────────────────────────────
// When the override checkbox is OFF, the field is `null` ("use the
// backend default"). When ON, the field holds the user's typed value.
// The text input is disabled while the override is OFF so the user
// can't accidentally type a value into a disabled field.
const isCapacityOverride = computed<boolean>({
  get: () => props.modelValue.max_capacity_token_model !== null,
  set: (v) => {
    if (v) {
      // Turning ON: seed with the backend's MiniMax-M3 default if the
      // user hasn't picked anything yet. Otherwise restore the last
      // explicit value (which we keep in props.modelValue).
      const next = props.modelValue.max_capacity_token_model ?? 500000
      update('max_capacity_token_model', next)
    } else {
      update('max_capacity_token_model', null)
    }
  },
})

const isThresholdOverride = computed<boolean>({
  get: () => props.modelValue.compaction_threshold_percent !== null,
  set: (v) => {
    if (v) {
      const next = props.modelValue.compaction_threshold_percent ?? 80
      update('compaction_threshold_percent', next)
    } else {
      update('compaction_threshold_percent', null)
    }
  },
})

// ─── Capacity input ──────────────────────────────────────────────────────
// The number input's displayed value uses an empty string when the
// override is OFF (so the placeholder shows). When the user types a
// value, we clamp it to the u32 range to match the wire format.
const capacityDisplay = computed<string>({
  get: () => {
    const v = props.modelValue.max_capacity_token_model
    return v === null ? '' : String(v)
  },
  set: (raw) => {
    const trimmed = raw.trim()
    if (trimmed === '') {
      // Empty input while override is ON — treat as 0 so the user can
      // type without immediately going out of range. The backend
      // validates the wire value separately.
      update('max_capacity_token_model', 0)
      return
    }
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_token_model', Math.floor(parsed))
  },
})

// ─── Threshold input ─────────────────────────────────────────────────────
// Stored as `number` (0-100). The wire format on the backend is u8 so
// we clamp here as a defense-in-depth check; the backend rejects
// values > 100 with HTTP 400.
const thresholdDisplay = computed<number>({
  get: () => props.modelValue.compaction_threshold_percent ?? 80,
  set: (v) => {
    if (!Number.isFinite(v)) return
    const clamped = Math.max(0, Math.min(100, Math.floor(v)))
    update('compaction_threshold_percent', clamped)
  },
})
</script>

<template>
  <div class="space-y-8" data-testid="compaction-section">
    <p class="text-xs" :style="helperStyle">
      Both fields below are optional. When a field's checkbox is unchecked, the backend
      uses its built-in defaults (200,000 / 500,000 / 200,000-fallback tokens for the
      model context window, 80% for the compaction threshold).
    </p>

    <!-- Context window override -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Context window ──</h3>
      <div class="space-y-4">
        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              v-model="isCapacityOverride"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="capacity-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the model's context window</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Sets <code class="font-mono">max_capacity_token_model</code> in config.json.
                Useful for self-hosted models with a larger (or smaller) context window than the backend&apos;s default.
              </span>
            </span>
          </label>
        </div>

        <div :class="{ 'opacity-50 pointer-events-none': !isCapacityOverride }">
          <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
          <input
            :value="capacityDisplay"
            @input="capacityDisplay = ($event.target as HTMLInputElement).value"
            type="number"
            min="0"
            step="1000"
            placeholder="500000"
            :class="inputBase"
            :style="inputStyle"
            :disabled="!isCapacityOverride"
            data-testid="capacity-input"
          />
          <p class="text-xs mt-1" :style="helperStyle">
            Built-in defaults: MiniMax-M2.7 → 200,000 · MiniMax-M3 → 500,000 · unknown → 200,000.
          </p>
        </div>
      </div>
    </section>

    <!-- Compaction threshold override -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Compaction threshold ──</h3>
      <div class="space-y-4">
        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              v-model="isThresholdOverride"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="threshold-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the compaction threshold</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Sets <code class="font-mono">compaction_threshold_percent</code> in config.json.
                The conversation is compacted when total tokens ≥ capacity × threshold ÷ 100.
              </span>
            </span>
          </label>
        </div>

        <div :class="{ 'opacity-50 pointer-events-none': !isThresholdOverride }">
          <div class="flex items-center justify-between mb-1.5">
            <label :class="labelBase" :style="labelStyle" class="!mb-0">Threshold (%)</label>
            <span class="font-mono text-xs" :style="labelStyle">{{ thresholdDisplay }}</span>
          </div>
          <input
            :value="thresholdDisplay"
            @input="thresholdDisplay = parseFloat(($event.target as HTMLInputElement).value)"
            type="range"
            min="0"
            max="100"
            step="1"
            class="w-full"
            :disabled="!isThresholdOverride"
            data-testid="threshold-slider"
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
</template>
<script setup lang="ts">
import { computed, ref } from 'vue'

export interface LlmConfig {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
  /** Optional per-profile override for the context window (in tokens).
   * `null` = no per-profile override (fall through to top-level defaults
   * → built-in). Added in plan 2026-07-07-compaction-inline. */
  max_capacity_tokens: number | null
  /** Optional per-profile compaction threshold as a percentage (0-100).
   * `null` = no per-profile override (fall through to top-level defaults
   * → built-in 80). Added in plan 2026-07-07-compaction-inline. */
  compaction_threshold_percent: number | null
  /** Anthropic-only override for `thinking.budget_tokens`. Range
   * (0, 2_000_000]. `null` = use the 50%-of-max_tokens heuristic
   * (or Anthropic `type: "adaptive"` when `thinking === "auto"`).
   * Hidden when `thinking === "off"`. Plan 2026-08-23-model-thinking. */
  thinking_budget_tokens: number | null
  /** OpenAI-style reasoning effort (o1 / o3 / GPT-5 / DeepSeek-R1).
   * `"low" | "medium" | "high" | "auto" | null`. `null` = omit from
   * the request body (model-default reasoning). Anthropic-style
   * URLs ignore this field. Plan 2026-08-23-model-thinking. */
  reasoning_effort: 'low' | 'medium' | 'high' | 'auto' | null
}

const props = defineProps<{
  modelValue: LlmConfig
  errors?: Partial<Record<keyof LlmConfig, string>>
}>()

const emit = defineEmits<{
  'update:modelValue': [value: LlmConfig]
}>()

const showKey = ref(false)

function update<K extends keyof LlmConfig>(key: K, value: LlmConfig[K]) {
  emit('update:modelValue', { ...props.modelValue, [key]: value })
}

const inputBase = 'w-full px-3 h-8 rounded-md border text-sm font-sans transition-colors duration-150'
const inputStyle = (hasError?: boolean): Record<string, string> => ({
  backgroundColor: 'var(--semantic-content-bg)',
  color: 'var(--semantic-text)',
  borderColor: hasError ? 'var(--color-red)' : 'var(--color-border)',
})

const labelBase = 'block text-xs font-medium mb-1.5'
const labelStyle = { color: 'var(--semantic-text-muted)' }
const helperStyle = { color: 'var(--semantic-text-dim)' }
const errorStyle = { color: 'var(--color-red)' }

// === Compaction overrides (per-profile) — plan 2026-07-07-compaction-inline ===

const capacityDisplay = computed<string>({
  get: () =>
    props.modelValue.max_capacity_tokens === null
      ? ''
      : String(props.modelValue.max_capacity_tokens),
  set: (raw: string) => {
    const trimmed = raw.trim()
    if (trimmed === '') return
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_tokens', Math.floor(parsed))
  },
})

const thresholdDisplay = computed<number>({
  get: () => props.modelValue.compaction_threshold_percent ?? 80,
  set: (v: number) => {
    if (!Number.isFinite(v)) return
    update(
      'compaction_threshold_percent',
      Math.max(0, Math.min(100, Math.floor(v))),
    )
  },
})

function setCapacityOverride(on: boolean) {
  update(
    'max_capacity_tokens',
    on ? (props.modelValue.max_capacity_tokens ?? 500000) : null,
  )
}

function setThresholdOverride(on: boolean) {
  update(
    'compaction_threshold_percent',
    on ? (props.modelValue.compaction_threshold_percent ?? 80) : null,
  )
}
</script>

<template>
  <div class="space-y-4">
    <!-- Model -->
    <div>
      <label :class="labelBase" :style="labelStyle">
        Model <span style="color: var(--color-red);">*</span>
      </label>
      <input
        :value="modelValue.model"
        @input="update('model', ($event.target as HTMLInputElement).value)"
        type="text"
        placeholder="MiniMax-M2.7"
        :class="inputBase"
        :style="inputStyle(!!errors?.model)"
        data-testid="model-input"
      />
      <p v-if="errors?.model" class="text-xs mt-1" :style="errorStyle">{{ errors.model }}</p>
    </div>

    <!-- Base URL -->
    <div>
      <label :class="labelBase" :style="labelStyle">Base URL</label>
      <input
        :value="modelValue.base_url"
        @input="update('base_url', ($event.target as HTMLInputElement).value)"
        type="text"
        placeholder="https://api.minimax.io/v1"
        :class="inputBase"
        :style="inputStyle(!!errors?.base_url)"
        data-testid="base-url-input"
      />
      <p v-if="errors?.base_url" class="text-xs mt-1" :style="errorStyle">{{ errors.base_url }}</p>
    </div>

    <!-- Thinking / Temperature / URL style — 3 columns -->
    <div class="grid grid-cols-3 gap-3">
      <div>
        <label :class="labelBase" :style="labelStyle">Thinking</label>
        <select
          :value="modelValue.thinking"
          @change="update('thinking', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="auto">Auto</option>
          <option value="on">On</option>
          <option value="off">Off</option>
        </select>
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">Temperature</label>
        <select
          :value="modelValue.temperature"
          @change="update('temperature', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="auto">Auto</option>
          <option value="0">0 — Precise</option>
          <option value="0.5">0.5</option>
          <option value="1">1 — Balanced</option>
        </select>
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">URL style</label>
        <select
          :value="modelValue.url_style"
          @change="update('url_style', ($event.target as HTMLSelectElement).value)"
          :class="inputBase"
          :style="inputStyle()"
        >
          <option value="openai">OpenAI</option>
          <option value="openai-response">OpenAI Response</option>
          <option value="anthropic">Anthropic</option>
        </select>
      </div>
    </div>

    <!-- Thinking budget + Reasoning effort — plan 2026-08-23-model-thinking.
         Hidden when thinking === "off" because the budget is irrelevant
         and the effort dropdown is meaningless when extended reasoning
         is disabled. -->
    <div
      v-if="modelValue.thinking !== 'off'"
      class="grid grid-cols-2 gap-3"
    >
      <div>
        <label :class="labelBase" :style="labelStyle">
          Thinking budget tokens
          <span class="block text-xs mt-0.5" :style="helperStyle">
            Anthropic only. Min 1024. Null = heuristic / adaptive.
          </span>
        </label>
        <input
          :value="modelValue.thinking_budget_tokens ?? ''"
          @input="(e) => {
            const raw = (e.target as HTMLInputElement).value
            if (raw === '') {
              update('thinking_budget_tokens', null)
            } else {
              const parsed = parseInt(raw, 10)
              update('thinking_budget_tokens', Number.isFinite(parsed) ? Math.max(1024, parsed) : null)
            }
          }"
          type="number"
          min="1024"
          step="512"
          placeholder="auto"
          :class="inputBase"
          :style="inputStyle()"
          data-testid="thinking-budget-input"
        />
      </div>
      <div>
        <label :class="labelBase" :style="labelStyle">
          Reasoning effort
          <span class="block text-xs mt-0.5" :style="helperStyle">
            OpenAI only (o1/o3/GPT-5/DeepSeek-R1).
          </span>
        </label>
        <select
          :value="modelValue.reasoning_effort ?? ''"
          @change="(e) => {
            const raw = (e.target as HTMLSelectElement).value
            update('reasoning_effort', raw === '' ? null : raw as 'low' | 'medium' | 'high' | 'auto')
          }"
          :class="inputBase"
          :style="inputStyle()"
          data-testid="reasoning-effort-select"
        >
          <option value="">Auto</option>
          <option value="low">Low</option>
          <option value="medium">Medium</option>
          <option value="high">High</option>
        </select>
      </div>
    </div>

    <!-- API key with show/hide -->
    <div>
      <label :class="labelBase" :style="labelStyle">
        API key
        <span v-if="!modelValue.api_key" style="color: var(--color-red);">*</span>
      </label>
      <div class="relative">
        <input
          :value="modelValue.api_key"
          @input="update('api_key', ($event.target as HTMLInputElement).value)"
          :type="showKey ? 'text' : 'password'"
          placeholder="sk-..."
          :class="inputBase + ' pr-9'"
          :style="inputStyle(!!errors?.api_key)"
          data-testid="api-key-input"
        />
        <button
          type="button"
          @click="showKey = !showKey"
          :aria-label="showKey ? 'Hide API key' : 'Show API key'"
          :title="showKey ? 'Hide' : 'Show'"
          data-testid="api-key-toggle"
          class="absolute right-2 top-1/2 -translate-y-1/2 w-6 h-6 flex items-center justify-center text-xs"
          style="color: var(--semantic-text-dim);"
        >{{ showKey ? '◉' : '○' }}</button>
      </div>
      <p v-if="errors?.api_key" class="text-xs mt-1" :style="errorStyle">{{ errors.api_key }}</p>
    </div>

    <!-- Compaction overrides (per-profile) — plan 2026-07-07-compaction-inline -->
    <div class="border-t pt-4 mt-2" style="border-color: var(--color-border);">
      <h3 class="font-mono text-xs uppercase tracking-wider mb-3" :style="labelStyle">
        ── Compaction overrides ──
      </h3>

      <div class="space-y-3">
        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              :checked="modelValue.max_capacity_tokens !== null"
              @change="setCapacityOverride(($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="profile-capacity-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the context window</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Falls back to top-level defaults → built-in.
              </span>
            </span>
          </label>
        </div>

        <div
          :class="{ 'opacity-50 pointer-events-none': modelValue.max_capacity_tokens === null }"
        >
          <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
          <input
            :value="capacityDisplay"
            @input="capacityDisplay = ($event.target as HTMLInputElement).value"
            type="number"
            min="0"
            step="1000"
            placeholder="500000"
            :class="inputBase"
            :style="inputStyle(!!errors?.max_capacity_tokens)"
            :disabled="modelValue.max_capacity_tokens === null"
            data-testid="profile-capacity-input"
          />
        </div>

        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              :checked="modelValue.compaction_threshold_percent !== null"
              @change="setThresholdOverride(($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="profile-threshold-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the compaction threshold</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Falls back to top-level defaults → built-in 80.
              </span>
            </span>
          </label>
        </div>

        <div
          :class="{ 'opacity-50 pointer-events-none': modelValue.compaction_threshold_percent === null }"
        >
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
            :disabled="modelValue.compaction_threshold_percent === null"
            data-testid="profile-threshold-slider"
          />
        </div>
      </div>
    </div>
  </div>
</template>

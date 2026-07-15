<script setup lang="ts">
import { computed } from 'vue'

export interface DefaultsConfig {
  api_endpoint: string
  api_key: string
  model: string
  url_style: string
  temperature: number
  max_tokens: string
  system_prompt: string
  notify_on_complete: boolean
  /** Optional top-level override for the model's context window (in tokens).
   * `null` = no top-level override (fall through to per-profile → built-in).
   * Added in plan 2026-07-07-compaction-inline. */
  max_capacity_token_model: number | null
  /** Optional top-level compaction threshold as a percentage (0-100).
   * `null` = no top-level override (fall through to per-profile → 80).
   * Added in plan 2026-07-07-compaction-inline. */
  compaction_threshold_percent: number | null
  /** Delay in milliseconds before the workflow retries a failed LLM
   * call. 0 = no delay (default). Range: 0–60 000. Added in plan
   * 2026-07-15-retry-delay. */
  retry_delay_ms: number
}

const props = defineProps<{ modelValue: DefaultsConfig }>()
const emit = defineEmits<{ 'update:modelValue': [value: DefaultsConfig] }>()

function update<K extends keyof DefaultsConfig>(key: K, val: DefaultsConfig[K]) {
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

// Approximate token count: words * 1.3, rounded up. Footer hint.
const systemPromptTokens = computed(() => {
  const text = props.modelValue.system_prompt.trim()
  if (!text) return 0
  const words = text.split(/\s+/).filter(Boolean).length
  return Math.ceil(words * 1.3)
})

// === Compaction defaults (top-level) — plan 2026-07-07-compaction-inline ===

/** Display the top-level context window override as a string for the
 *  number input. Empty string when the override is disabled (`null`)
 *  so the input renders blank rather than "0". */
const defaultsCapacityDisplay = computed<string>({
  get: () =>
    props.modelValue.max_capacity_token_model === null
      ? ''
      : String(props.modelValue.max_capacity_token_model),
  set: (raw: string) => {
    const trimmed = raw.trim()
    if (trimmed === '') return  // ignore transient empty
    const parsed = Number(trimmed)
    if (!Number.isFinite(parsed) || parsed < 0) return
    update('max_capacity_token_model', Math.floor(parsed))
  },
})

/** Display the top-level compaction threshold as a number for the
 *  range slider. Defaults to 80 when the override is null. */
const defaultsThresholdDisplay = computed<number>({
  get: () => props.modelValue.compaction_threshold_percent ?? 80,
  set: (v: number) => {
    if (!Number.isFinite(v)) return
    update(
      'compaction_threshold_percent',
      Math.max(0, Math.min(100, Math.floor(v))),
    )
  },
})

/** Toggle the context-window override. When turning on, seed with the
 *  current value or 500_000 if absent. When turning off, set to null. */
function setCapacityOverride(on: boolean) {
  update(
    'max_capacity_token_model',
    on ? (props.modelValue.max_capacity_token_model ?? 500000) : null,
  )
}

/** Toggle the threshold override. Same pattern as the capacity toggle. */
function setThresholdOverride(on: boolean) {
  update(
    'compaction_threshold_percent',
    on ? (props.modelValue.compaction_threshold_percent ?? 80) : null,
  )
}
</script>

<template>
  <div class="space-y-8">
    <!-- Default LLM -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Default LLM ──</h3>
      <div class="space-y-4">
        <div>
          <label :class="labelBase" :style="labelStyle">API endpoint</label>
          <input
            :value="modelValue.api_endpoint"
            @input="update('api_endpoint', ($event.target as HTMLInputElement).value)"
            type="text"
            placeholder="https://api.example.com/v1"
            :class="inputBase"
            :style="inputStyle"
            data-testid="api-endpoint-input"
          />
          <p class="text-xs mt-1" :style="helperStyle">Used by all profiles unless a profile overrides.</p>
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">API key</label>
          <input
            :value="modelValue.api_key"
            @input="update('api_key', ($event.target as HTMLInputElement).value)"
            type="password"
            placeholder="sk-…"
            :class="inputBase"
            :style="inputStyle"
            data-testid="api-key-input"
          />
          <p class="text-xs mt-1" :style="helperStyle">Stored in config.json. Not synced anywhere.</p>
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">Model</label>
          <input
            :value="modelValue.model"
            @input="update('model', ($event.target as HTMLInputElement).value)"
            type="text"
            placeholder="MiniMax-M2.7"
            :class="inputBase"
            :style="inputStyle"
            data-testid="model-input"
          />
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">URL style</label>
          <select
            :value="modelValue.url_style"
            @change="update('url_style', ($event.target as HTMLSelectElement).value)"
            :class="inputBase"
            :style="inputStyle"
          >
            <option value="openai">OpenAI (/v1/chat/completions)</option>
            <option value="anthropic">Anthropic (/v1/messages)</option>
          </select>
        </div>
      </div>
    </section>

    <!-- Model parameters -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Model parameters ──</h3>
      <div class="space-y-4">
        <div>
          <div class="flex items-center justify-between mb-1.5">
            <label :class="labelBase" :style="labelStyle" class="!mb-0">Temperature</label>
            <span class="font-mono text-xs" :style="labelStyle">{{ modelValue.temperature.toFixed(1) }}</span>
          </div>
          <input
            :value="modelValue.temperature"
            @input="update('temperature', parseFloat(($event.target as HTMLInputElement).value))"
            type="range"
            min="0"
            max="2"
            step="0.1"
            class="w-full"
            data-testid="temperature-slider"
          />
          <div class="flex justify-between text-xs mt-1 font-mono" :style="helperStyle">
            <span>Precise</span>
            <span>Creative</span>
          </div>
        </div>

        <div>
          <label :class="labelBase" :style="labelStyle">Max tokens</label>
          <input
            :value="modelValue.max_tokens"
            @input="update('max_tokens', ($event.target as HTMLInputElement).value)"
            type="number"
            placeholder="4096"
            :class="inputBase"
            :style="inputStyle"
          />
        </div>

        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              :checked="modelValue.notify_on_complete"
              @change="update('notify_on_complete', ($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="notify-checkbox"
            />
            <span>
              <span :style="labelStyle">Notify when an LLM response completes</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Fires an OS notification when a response finishes. Requires notify-send (Linux) / osascript (mac) / PowerShell (Windows).
              </span>
            </span>
          </label>
        </div>
      </div>
    </section>

    <!-- Compaction defaults (top-level) — plan 2026-07-07-compaction-inline -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Compaction defaults ──</h3>
      <div class="space-y-4">
        <div>
          <label class="flex items-start gap-2 cursor-pointer text-sm">
            <input
              :checked="modelValue.max_capacity_token_model !== null"
              @change="setCapacityOverride(($event.target as HTMLInputElement).checked)"
              type="checkbox"
              class="w-4 h-4 mt-0.5"
              style="accent-color: var(--color-violet);"
              data-testid="defaults-capacity-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the model's context window for all profiles</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Sets <code class="font-mono">max_capacity_token_model</code> in config.json.
                Profiles can override this in their own compaction settings.
              </span>
            </span>
          </label>
        </div>

        <div
          :class="{ 'opacity-50 pointer-events-none': modelValue.max_capacity_token_model === null }"
        >
          <label :class="labelBase" :style="labelStyle">Max capacity (tokens)</label>
          <input
            :value="defaultsCapacityDisplay"
            @input="defaultsCapacityDisplay = ($event.target as HTMLInputElement).value"
            type="number"
            min="0"
            step="1000"
            placeholder="500000"
            :class="inputBase"
            :style="inputStyle"
            :disabled="modelValue.max_capacity_token_model === null"
            data-testid="defaults-capacity-input"
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
              data-testid="defaults-threshold-override-checkbox"
            />
            <span>
              <span :style="labelStyle">Override the compaction threshold for all profiles</span>
              <span class="block text-xs mt-0.5" :style="helperStyle">
                Sets <code class="font-mono">compaction_threshold_percent</code> in config.json.
                Profiles can override this in their own compaction settings.
              </span>
            </span>
          </label>
        </div>

        <div
          :class="{ 'opacity-50 pointer-events-none': modelValue.compaction_threshold_percent === null }"
        >
          <div class="flex items-center justify-between mb-1.5">
            <label :class="labelBase" :style="labelStyle" class="!mb-0">Threshold (%)</label>
            <span class="font-mono text-xs" :style="labelStyle">{{ defaultsThresholdDisplay }}</span>
          </div>
          <input
            :value="defaultsThresholdDisplay"
            @input="defaultsThresholdDisplay = parseFloat(($event.target as HTMLInputElement).value)"
            type="range"
            min="0"
            max="100"
            step="1"
            class="w-full"
            :disabled="modelValue.compaction_threshold_percent === null"
            data-testid="defaults-threshold-slider"
          />
          <div class="flex justify-between text-xs mt-1 font-mono" :style="helperStyle">
            <span>Never</span>
            <span>80% (default)</span>
            <span>Always</span>
          </div>
        </div>
      </div>
    </section>

    <!-- Workflow behavior — plan 2026-07-15-retry-delay -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── Workflow behavior ──</h3>
      <div class="space-y-4">
        <div>
          <label :class="labelBase" :style="labelStyle">Retry delay (ms)</label>
          <input
            :value="modelValue.retry_delay_ms"
            @input="
              update(
                'retry_delay_ms',
                Math.max(0, Math.min(60000, parseInt(($event.target as HTMLInputElement).value, 10) || 0)),
              )
            "
            type="number"
            min="0"
            max="60000"
            step="100"
            placeholder="0"
            :class="inputBase"
            :style="inputStyle"
            data-testid="retry-delay-input"
          />
          <p class="text-xs mt-1" :style="helperStyle">
            Milliseconds to wait before retrying a failed LLM call. 0 = no delay (retry immediately).
            Useful when the upstream rate-limits and you want to back off instead of hammering it.
            Max 60 000 ms (1 min) — beyond that, cancel and start a new session.
          </p>
        </div>
      </div>
    </section>

    <!-- System prompt -->
    <section>
      <h3 :class="sectionHeader" :style="sectionHeaderStyle">── System prompt ──</h3>
      <div>
        <textarea
          :value="modelValue.system_prompt"
          @input="update('system_prompt', ($event.target as HTMLTextAreaElement).value)"
          rows="8"
          placeholder="Enter system prompt for the AI…"
          class="w-full px-3 py-2 rounded-md border text-sm resize-none"
          style="background-color: var(--semantic-content-bg); color: var(--semantic-text); border-color: var(--color-border); font-family: var(--font-mono);"
          data-testid="system-prompt-input"
        />
        <p class="text-xs mt-1 font-mono" :style="helperStyle">
          ~ {{ systemPromptTokens }} token{{ systemPromptTokens === 1 ? '' : 's' }} · keep it under 2,000 for best results
        </p>
      </div>
    </section>
  </div>
</template>

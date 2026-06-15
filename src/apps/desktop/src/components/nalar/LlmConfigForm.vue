<script setup lang="ts">
import { ref } from 'vue'

export interface LlmConfig {
  model: string
  base_url: string
  thinking: string
  temperature: string
  url_style: string
  api_key: string
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
const errorStyle = { color: 'var(--color-red)' }
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
          <option value="anthropic">Anthropic</option>
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
  </div>
</template>

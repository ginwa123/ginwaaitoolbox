<script setup lang="ts">
import { onMounted, watch } from 'vue'

const STORAGE_KEY = 'nalar-settings-active-tab'

type TabId = 'profiles' | 'sub-agents' | 'mcp'

const props = defineProps<{
  modelValue: TabId
}>()

const emit = defineEmits<{
  'update:modelValue': [value: TabId]
}>()

// Plan 2026-08-24-config-simplify-remove-defaults: the 'defaults' tab
// was removed — profiles are the only LLM config surface now.
const tabs: ReadonlyArray<{ id: TabId; label: string }> = [
  { id: 'profiles', label: 'Profiles' },
  { id: 'sub-agents', label: 'Sub-agents' },
  { id: 'mcp', label: 'MCP Servers' },
] as const

// localStorage is the source of truth on mount, but the parent's
// v-model is what drives the actual selection. The watcher writes
// to localStorage when the parent changes the model.
onMounted(() => {
  const saved = localStorage.getItem(STORAGE_KEY)
  if (saved && tabs.some(t => t.id === saved) && saved !== props.modelValue) {
    emit('update:modelValue', saved as TabId)
  }
})

watch(() => props.modelValue, (val) => {
  try { localStorage.setItem(STORAGE_KEY, val) } catch { /* quota / private mode */ }
})
</script>

<template>
  <div
    role="tablist"
    aria-label="Nalar settings sections"
    class="flex items-center gap-1 border-b"
    style="border-color: var(--color-border);"
  >
    <button
      v-for="tab in tabs"
      :key="tab.id"
      role="tab"
      type="button"
      :aria-selected="modelValue === tab.id"
      :data-tab-id="tab.id"
      :data-active="modelValue === tab.id ? 'true' : 'false'"
      @click="emit('update:modelValue', tab.id)"
      class="relative px-4 h-10 text-sm font-medium transition-colors duration-150"
      :style="{
        color: modelValue === tab.id ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
      }"
    >
      <span class="relative z-10">{{ tab.label }}</span>
      <span
        v-if="modelValue === tab.id"
        class="absolute left-2 right-2 bottom-0 h-0.5"
        style="background-color: var(--color-violet);"
        aria-hidden="true"
      />
    </button>
  </div>
</template>

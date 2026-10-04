<script setup lang="ts">
import { onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'

const STORAGE_KEY = 'pabrik-settings-active-tab'

type TabId = 'general' | 'profiles' | 'mcp' | 'tools' | 'evals'

const props = defineProps<{
  modelValue: TabId
}>()

const emit = defineEmits<{
  'update:modelValue': [value: TabId]
}>()

// Plan 2026-08-25-notify-on-error-and-retry-ms-in-settings: the
// 'general' tab is the FIRST tab — operational settings (notification
// toggles + retry delay) sit before profiles so the user lands on
// the most-frequently-touched settings first. Plan 2026-08-24-
// config-simplify-remove-defaults: the 'defaults' tab was removed
// (top-level LLM defaults no longer persist). Plan
// 2026-09-04-subagents-per-profile: the 'sub-agents' tab was removed
// (no global list — each profile owns its sub-agents, edited inline
// in the Profiles tab via expand chevron).
const tabs: ReadonlyArray<{ id: TabId; label: string }> = [
  { id: 'general', label: 'General' },
  { id: 'profiles', label: 'Profiles' },
  { id: 'mcp', label: 'MCP Servers' },
  { id: 'tools', label: 'Tools' },
  { id: 'evals', label: 'Skill Evals' },
] as const

// Undefined when mounted without a router (unit tests). The restore
// emit below must never run under a real router that already carries
// a `?section=` deep link — it would clobber the linked tab with the
// localStorage value on mount. The parent (PabrikSettings) reads
// `?section=` first, then falls back to localStorage itself.
const route = useRoute()

onMounted(() => {
  const raw = route?.query?.section
  const section = Array.isArray(raw) ? raw[0] : raw
  if (typeof section === 'string' && tabs.some((t) => t.id === section)) return
  const saved = localStorage.getItem(STORAGE_KEY)
  if (saved && tabs.some((t) => t.id === saved) && saved !== props.modelValue) {
    emit('update:modelValue', saved as TabId)
  }
})

watch(
  () => props.modelValue,
  (val) => {
    try {
      localStorage.setItem(STORAGE_KEY, val)
    } catch {
      /* quota / private mode */
    }
  },
)
</script>

<template>
  <div
    role="tablist"
    aria-label="Pabrik settings sections"
    class="flex items-center gap-1 border-b"
    style="border-color: var(--color-border)"
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
      class="relative px-4 h-10 text-body font-medium transition-colors duration-150"
      :style="{
        color: modelValue === tab.id ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
      }"
    >
      <span class="relative z-10">{{ tab.label }}</span>
      <span
        v-if="modelValue === tab.id"
        class="absolute left-2 right-2 bottom-0 h-0.5"
        style="background-color: var(--color-violet)"
        aria-hidden="true"
      />
    </button>
  </div>
</template>

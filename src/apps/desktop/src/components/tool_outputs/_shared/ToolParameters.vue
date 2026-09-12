<!--
  ToolParameters — shared Arguments block for tool-output cards.

  Extracted from McpTool.vue (hasArgs/prettyArgs + Arguments details markup)
  so every tool card renders parameters identically. Guard: trim in '',
  '{}' -> render nothing. pretty: try JSON.parse -> stringify null,2,
  else raw string (XML params display raw, matching McpTool behavior).
-->
<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  parameters?: string
}>()

const hasArgs = computed(() => {
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

const pretty = computed(() => {
  const p = (props.parameters ?? '').trim()
  if (!p) return ''
  try {
    return JSON.stringify(JSON.parse(p), null, 2)
  } catch {
    return p
  }
})
</script>

<template>
  <details v-if="hasArgs" class="px-2 py-1.5 border-t border-[var(--color-border)]">
    <summary class="cursor-pointer select-none text-[var(--semantic-text-dim)] hover:opacity-100 opacity-70">
      Arguments
    </summary>
    <pre class="mt-1 p-2 m-0 whitespace-pre-wrap break-words max-w-full min-w-0 overflow-x-auto text-[var(--semantic-text-dim)] text-xs">{{ pretty }}</pre>
  </details>
</template>

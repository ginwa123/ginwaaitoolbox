<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseReadFile } from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseReadFile(props.content))

// Display the parsed content; the parser already strips XML wrappers.
const fileContent = computed(() => parsed.value.content || '')

const lineCount = computed(() => {
  const c = fileContent.value
  if (!c) return 0
  return c.split('\n').length
})

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path; fall back to the parameters prop so a
// still-running tool (placeholder envelope with empty <data>) shows its path.
const displayPath = computed((): string | null => {
  return contentPath.value ?? extractParam(props.parameters, 'path')
})

// Running: empty envelope content, but we know the path.
const isRunning = computed(() => {
  return props.content.trim().length === 0 && displayPath.value !== null
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{ 'border-red-500/50 opacity-80': !!parsed.error }"
  >
    <ToolCardHeader
      tool-name="read_file"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :cwd="cwd"
      :right-meta="isRunning ? 'running…' : parsed.error ? 'Error' : `${lineCount}L`"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="parsed.error" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
      <pre
        v-else
        class="p-2 m-0 bg-black/[0.02] whitespace-pre overflow-x-visible leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5"
      >{{ fileContent || '(empty)' }}</pre>
    </div>
  </div>
</template>

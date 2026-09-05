<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseWriteFile } from './_shared/toolOutputParser'
import { extractParam } from '@/helpers/extractParam'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const parsed = computed(() => parseWriteFile(props.content))

const contentPath = computed((): string | null => {
  const p = parsed.value.path
  return p && p.trim() !== '' ? p : null
})

// Prefer the envelope's path (<file_write>); fall back to the parameters
// prop so a still-running tool (placeholder envelope with empty <data>)
// shows its path.
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
    :class="{ 'border-red-500/50 opacity-80': !parsed.success }"
  >
    <ToolCardHeader
      tool-name="write_file"
      :primary="displayPath"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="!!parsed.error"
      :cwd="cwd"
      :right-meta="isRunning ? 'running…' : null"
      @update:expanded="handleToggle"
    />

    <div
      v-if="isExpanded && parsed.error"
      class="border-t border-[var(--color-border)] bg-black/[0.02]"
    >
      <div class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ parsed.error }}</span>
      </div>
    </div>
  </div>
</template>

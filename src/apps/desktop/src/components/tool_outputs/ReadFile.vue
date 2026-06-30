<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'
import { parseReadFile } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
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

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !!parsed.error }"
  >
    <ToolCardHeader
      tool-name="read_file"
      :primary="parsed.path"
      :success="parsed.success"
      :expanded="isExpanded"
      :expandable="true"
      :cwd="cwd"
      :right-meta="parsed.error ? 'Error' : `${lineCount}L`"
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
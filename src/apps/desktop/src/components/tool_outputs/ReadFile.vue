<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolCardHeader from './_shared/ToolCardHeader.vue'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse <path>...</path>
const filePath = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
  return match ? match[1] : null
})

// Parse <error>...</error> (only when not success)
const errorMessage = computed(() => {
  if (!isSuccess.value) {
    const match = props.content.match(/<error>(.*?)<\/error>/)
    if (!match || !match[1]) return null
    return match[1].trim()
  }
  return null
})

// Parse <success>true|false</success> (default true for legacy)
const isSuccess = computed(() => {
  const match = props.content.match(/<success>([\s\S]*?)<\/success>/)
  if (!match || !match[1]) return true
  return match[1].trim() === 'true'
})

// Strip XML tags from the file content for clean display
const stripXml = (text: string | undefined | null): string => {
  if (!text) return ''
  return text
    .replace(/<path>.*?<\/path>/gs, '')
    .replace(/<content>[\s\S]*?<\/content>/gs, '')
    .replace(/<total_lines>.*?<\/total_lines>/gs, '')
    .replace(/<start_line>.*?<\/start_line>/gs, '')
    .replace(/<end_line>.*?<\/end_line>/gs, '')
    .replace(/<error>.*?<\/error>/gs, '')
    .replace(/<success>.*?<\/success>/gs, '')
    .trim()
}

const fileContent = computed(() => {
  const match = props.content.match(/<content>([\s\S]*?)<\/content>/)
  if (match) return stripXml(match[1])
  return stripXml(props.content)
})

const lineCount = computed(() => {
  const content = fileContent.value
  if (!content || typeof content !== 'string') return 0
  return content.split('\n').length
})

const handleToggle = (next: boolean) => {
  isExpanded.value = next
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': !!errorMessage }"
  >
    <ToolCardHeader
      tool-name="read_file"
      :primary="filePath"
      :success="isSuccess"
      :expanded="isExpanded"
      :expandable="true"
      :cwd="cwd"
      :right-meta="errorMessage ? 'Error' : `${lineCount}L`"
      @update:expanded="handleToggle"
    />

    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <div v-if="errorMessage" class="flex gap-2 px-2 py-1.5 text-red-500 text-xs">
        <span class="font-semibold shrink-0">Error:</span>
        <span class="whitespace-pre-wrap break-all">{{ errorMessage }}</span>
      </div>
      <pre
        v-else
        class="p-2 m-0 bg-black/[0.02] whitespace-pre overflow-x-visible leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5"
      >{{ fileContent || '(empty)' }}</pre>
    </div>
  </div>
</template>
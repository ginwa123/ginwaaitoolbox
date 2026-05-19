<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse file path from <path>...</path>
const filePath = computed(() => {
  const match = props.content.match(/<path>(.*?)<\/path>/)
  return match ? match[1] : null
})

// Parse error if any
const errorMessage = computed(() => {
  if (isSuccess.value == false) {
    const match = props.content.match(/<error>(.*?)<\/error>/)
    if (!match || !match[1]) return null
    return match[1].trim()
  }
  return
})

// Parse success status
const isSuccess = computed(() => {
  const match = props.content.match(/<success>([\s\S]*?)<\/success>/)
  if (!match || !match[1]) return true
  return match[1].trim() === 'true'
})

// Parse file content (clean, without XML)
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

// Line count
const lineCount = computed(() => {
  const content = fileContent.value
  if (!content || typeof content !== 'string') return 0
  return content.split('\n').length
})

const toggle = () => {
  isExpanded.value = !isExpanded.value
}

const copyPath = async (e: Event) => {
  e.stopPropagation()
  if (filePath.value) {
    await navigator.clipboard.writeText(filePath.value)
  }
}
</script>

<template>
  <div
    class="font-mono text-xs rounded-md overflow-hidden border border-[var(--color-border)] bg-[var(--semantic-card-bg)]"
    :class="{ 'border-red-500/50 opacity-80': errorMessage }"
  >
    <!-- Header -->
    <div
      class="group flex items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">read_file</span>
      <span
        class="flex-1 truncate text-left text-[var(--color-violet)] font-medium"
        :title="filePath || ''"
        >{{ filePath || 'unknown' }}</span
      >
      <span v-if="!errorMessage" class="text-[var(--semantic-text-muted)] text-xs">
        {{ lineCount }}L
      </span>
      <span v-if="errorMessage" class="text-red-500 text-xs font-medium"> Error </span>
      <button
        class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
        @click="copyPath"
        title="Copy path"
      >
        ⎘
      </button>
      <span class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)]">
      <pre
        class="p-2 m-0 bg-black/[0.02] whitespace-pre overflow-x-visible leading-relaxed text-[var(--semantic-text)] text-xs hover:bg-violet-500/5"
        >{{ fileContent || '(empty)' }}</pre
      >
    </div>
  </div>
</template>

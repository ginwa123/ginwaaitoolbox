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
  const match = props.content.match(/<error>(.*?)<\/error>/)
  return match ? match[1] : null
})

// Strip all XML tags for clean display
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

// Parse file content (clean, without XML)
const fileContent = computed(() => {
  // Try <content>...</content>
  const match = props.content.match(/<content>([\s\S]*?)<\/content>/)
  if (match) return stripXml(match[1])
  
  // Fallback: strip all tags
  return stripXml(props.content)
})

// File name (last segment of path)
const fileName = computed(() => {
  if (!filePath.value) return 'unknown'
  const parts = filePath.value.split('/')
  return parts[parts.length - 1]
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
  <div class="rf" :class="{ 'rf--error': errorMessage }">
    <!-- Header -->
    <div class="rf-header" @click="toggle">
      <span class="rf-path" :title="filePath || ''">{{ filePath || 'unknown' }}</span>
      <span class="rf-lines" v-if="!errorMessage">{{ lineCount }}L</span>
      <button class="rf-copy" @click="copyPath" title="Copy path">⎘</button>
      <span class="rf-toggle">{{ isExpanded ? '−' : '+' }}</span>
    </div>

    <!-- Content -->
    <div v-if="isExpanded" class="rf-content">
      <pre class="rf-pre">{{ fileContent || '(empty)' }}</pre>
    </div>
  </div>
</template>

<style scoped>
.rf {
  font-family: monospace;
  font-size: 0.75rem;
  border-radius: 6px;
  overflow: hidden;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
}

.rf--error {
  border-color: var(--color-red);
  opacity: 0.8;
}

.rf-header {
  display: flex;
  align-items: center;
  gap: 0.4rem;
  padding: 0.35rem 0.5rem;
  cursor: pointer;
  user-select: none;
}

.rf-header:hover {
  background: rgba(139, 92, 246, 0.04);
}

.rf-path {
  flex: 1;
  color: var(--color-violet);
  font-weight: 500;
}

.rf--error .rf-path {
  color: var(--color-red);
}

.rf-lines {
  color: var(--semantic-text-muted);
  font-size: 0.65rem;
}

.rf-copy {
  padding: 0 0.15rem;
  border: none;
  background: none;
  cursor: pointer;
  color: var(--semantic-text-muted);
  opacity: 0;
  transition: opacity 0.15s;
  font-size: 0.85rem;
}

.rf-header:hover .rf-copy {
  opacity: 1;
}

.rf-copy:hover {
  color: var(--color-violet);
}

.rf-toggle {
  color: var(--semantic-text-muted);
  font-size: 0.8rem;
  width: 1rem;
  text-align: center;
}

.rf-content {
  border-top: 1px solid var(--color-border);
  overflow-x: auto;
}

.rf-pre {
  margin: 0;
  padding: 0.5rem;
  background: rgba(0, 0, 0, 0.02);
  white-space: pre;
  overflow-x: visible;
  line-height: 1.5;
  color: var(--semantic-text);
  font-family: monospace;
  font-size: 0.72rem;
}

.rf-pre:hover {
  background: rgba(139, 92, 246, 0.04);
}
</style>
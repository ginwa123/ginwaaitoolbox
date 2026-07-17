<script setup lang="ts">
import { computed, ref } from 'vue'
import { useInjectOpenInCodeEditor } from '../../composables/useCodeEditor'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const openInEditor = useInjectOpenInCodeEditor()

// Parse glob pattern
const globPattern = computed(() => {
  const match = props.content.match(/pattern="([^"]+)"/)
  return match ? match[1] : null
})

// Parse total count
const totalCount = computed(() => {
  const match = props.content.match(/total="(\d+)"/)
  return match ? parseInt(match[1] ?? '0', 10) : 0
})

// Parse returned count
const returnedCount = computed(() => {
  const match = props.content.match(/returned="(\d+)"/)
  return match ? parseInt(match[1] ?? '0', 10) : 0
})

// Parse truncated count
const truncatedCount = computed(() => {
  const match = props.content.match(/truncated="(\d+)"/)
  return match ? parseInt(match[1] ?? '0', 10) : 0
})

// Parse offset
const offsetValue = computed(() => {
  const match = props.content.match(/offset="(\d+)"/)
  return match ? parseInt(match[1] ?? '0', 10) : 0
})

// Parse warning if no matches
const warningMessage = computed(() => {
  const match = props.content.match(/<warning>(.*?)<\/warning>/)
  return match ? match[1] : null
})

// Parse all file paths
const filePaths = computed((): string[] => {
  const results: string[] = []
  const fileRegex = /<f>(.*?)<\/f>/g
  let match
  while ((match = fileRegex.exec(props.content)) !== null) {
    results.push(match[1] ?? '')
  }
  return results
})

// Toggle expansion
const toggle = () => {
  if (!warningMessage.value && filePaths.value.length > 0) {
    isExpanded.value = !isExpanded.value
  }
}

// Copy path to clipboard
const copyPath = async (e: Event, path: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(path)
}

// Open file in code editor
const handleOpenInEditor = (e: Event, path: string) => {
  e.stopPropagation()
  if (!props.cwd || !openInEditor) return
  openInEditor({ filePath: path, cwd: props.cwd })
}
</script>

<template>
  <div class="gl" :class="{ 'gl--warning': warningMessage }">
    <!-- Header -->
    <div 
    role="button" tabindex="0"
    class="gl-header" @click="toggle">
      <span class="gl-title">glob</span>
      <span class="gl-pattern" :title="globPattern || ''">
        "{{ globPattern || 'unknown' }}"
      </span>

      <!-- Results summary -->
      <template v-if="!warningMessage">
        <span class="gl-summary">
          {{ totalCount }} {{ totalCount === 1 ? 'file' : 'files' }}
          <template v-if="returnedCount < totalCount">
            ({{ returnedCount }} returned{{ truncatedCount > 0 ? `, ${truncatedCount} truncated` : '' }})
          </template>
          <template v-if="offsetValue > 0">
            <span class="gl-offset">offset: {{ offsetValue }}</span>
          </template>
        </span>
      </template>

      <!-- Warning message -->
      <template v-else-if="warningMessage">
        <span class="gl-warning-text">{{ warningMessage }}</span>
      </template>

      <!-- Toggle indicator -->
      <span v-if="!warningMessage && filePaths.length > 0" class="gl-toggle">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- File list (expanded state only - no scroll) -->
    <div v-if="isExpanded && filePaths.length > 0" class="gl-content">
      <div v-for="(path, idx) in filePaths" :key="idx" class="gl-file">
        <span class="gl-file-path" :title="path">{{ path }}</span>
        <button class="gl-copy" @click="(e) => copyPath(e, path)" title="Copy path">⎘</button>
        <button
          v-if="props.cwd && openInEditor"
          class="gl-copy"
          @click="(e) => handleOpenInEditor(e, path)"
          title="Open in code editor"
        >
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
          </svg>
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.gl {
  font-family: monospace;
  font-size: 0.75rem;
  border-radius: 6px;
  overflow: hidden;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
}

.gl--warning {
  border-color: var(--color-orange);
  opacity: 0.85;
}

.gl-header {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.4rem;
  padding: 0.35rem 0.5rem;
  cursor: pointer;
  user-select: none;
}

.gl-title {
  color: var(--color-violet);
  font-weight: 600;
  font-size: 0.75rem;
}

.gl-header:hover {
  background: rgba(139, 92, 246, 0.04);
}

.gl-pattern {
  color: var(--color-violet);
  font-weight: 600;
  max-width: 200px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.gl-summary {
  margin-left: auto;
  color: var(--semantic-text-muted);
  font-size: 0.65rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
}

.gl-offset {
  color: var(--semantic-text-dim);
  font-size: 0.6rem;
}

.gl-warning-text {
  margin-left: auto;
  font-size: 0.7rem;
  color: var(--color-orange);
}

.gl--warning .gl-warning-text {
  color: var(--color-orange);
}

.gl-toggle {
  color: var(--semantic-text-muted);
  font-size: 0.8rem;
  width: 1rem;
  text-align: center;
}

.gl-content {
  border-top: 1px solid var(--color-border);
  background: rgba(0, 0, 0, 0.02);
}

.gl-file {
  display: flex;
  align-items: center;
  padding: 0.25rem 0.5rem;
  border-bottom: 1px dashed var(--color-border);
  gap: 0.3rem;
}

.gl-file:last-child {
  border-bottom: none;
}

.gl-file:hover {
  background: rgba(139, 92, 246, 0.04);
}

.gl-file-path {
  flex: 1;
  color: var(--semantic-text);
  font-size: 0.7rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.gl-copy {
  padding: 0 0.15rem;
  border: none;
  background: none;
  cursor: pointer;
  color: var(--semantic-text-muted);
  opacity: 0;
  transition: opacity 0.15s;
  font-size: 0.85rem;
  flex-shrink: 0;
}

.gl-file:hover .gl-copy {
  opacity: 1;
}

.gl-copy:hover {
  color: var(--color-violet);
}
</style>
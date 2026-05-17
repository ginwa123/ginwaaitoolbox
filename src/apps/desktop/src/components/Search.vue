<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  content: string
  expanded?: boolean
}>()

const isExpanded = ref(props.expanded ?? false)

// Parse search pattern and path
const searchPattern = computed(() => {
  const match = props.content.match(/pattern="([^"]+)"/)
  return match ? match[1] : null
})

const searchPath = computed(() => {
  const match = props.content.match(/path="([^"]+)"/)
  return match ? match[1] : null
})

// Parse warning if no matches
const warningMessage = computed(() => {
  const match = props.content.match(/<warning>(.*?)<\/warning>/)
  return match ? match[1] : null
})

// Parse error if any
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  return match ? match[1] : null
})

// Parse all files with matches
interface SearchMatch {
  lineNumber: number
  snippet: string
}

interface FileResult {
  path: string
  total: number
  count: number
  matches: SearchMatch[]
}

const fileResults = computed((): FileResult[] => {
  const results: FileResult[] = []
  
  // Match all <file ...>...</file> blocks
  const fileRegex = /<file path="([^"]+)" total="(\d+)" count="(\d+)">([\s\S]*?)<\/file>/g
  let match
  
  while ((match = fileRegex.exec(props.content)) !== null) {
    const filePath = match[1] ?? ''
    const total = parseInt(match[2] ?? '', 10) || 0
    const count = parseInt(match[3] ?? '', 10) || 0
    const fileContent = match[4] ?? ''
    
    // Parse individual matches within this file
    const matches: SearchMatch[] = []
    const matchRegex = /<m><l>(\d+)<\/l><s>([\s\S]*?)<\/s><\/m>/g
    let m
    while ((m = matchRegex.exec(fileContent)) !== null) {
      matches.push({
        lineNumber: parseInt(m[1] ?? '', 10) || 0,
        snippet: m[2] ?? ''
      })
    }
    
    results.push({ path: filePath, total, count, matches })
  }
  
  return results
})

// Total match count across all files
const totalMatchCount = computed(() => {
  return fileResults.value.reduce((sum, f) => sum + f.count, 0)
})

// Total file count
const totalFileCount = computed(() => fileResults.value.length)

// Toggle expansion
const toggle = () => {
  if (!warningMessage.value && !errorMessage.value && fileResults.value.length > 0) {
    isExpanded.value = !isExpanded.value
  }
}

// Copy path to clipboard
const copyPath = async (e: Event, path: string) => {
  e.stopPropagation()
  await navigator.clipboard.writeText(path)
}
</script>

<template>
  <div class="sr" :class="{ 'sr--warning': warningMessage, 'sr--error': errorMessage }">
    <!-- Header -->
    <div class="sr-header" @click="toggle">
      <span class="sr-title">search</span>
      <span class="sr-pattern" :title="searchPattern || ''">
        "{{ searchPattern || 'unknown' }}"
      </span>
      <span class="sr-path" :title="searchPath || ''">
        in {{ searchPath || 'unknown' }}
      </span>
      
      <!-- Results summary -->
      <template v-if="!warningMessage && !errorMessage">
        <span class="sr-summary">
          {{ totalFileCount }} {{ totalFileCount === 1 ? 'file' : 'files' }},
          {{ totalMatchCount }} {{ totalMatchCount === 1 ? 'match' : 'matches' }}
        </span>
      </template>
      
      <!-- Warning or error message -->
      <template v-else-if="warningMessage">
        <span class="sr-warning-text">{{ warningMessage }}</span>
      </template>
      <template v-else-if="errorMessage">
        <span class="sr-error-text">{{ errorMessage }}</span>
      </template>
      
      <!-- Toggle indicator -->
      <span v-if="!warningMessage && !errorMessage" class="sr-toggle">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded && fileResults.length > 0" class="sr-content">
      <div v-for="(file, idx) in fileResults" :key="idx" class="sr-file">
        <!-- File header -->
        <div class="sr-file-header">
          <span class="sr-file-path" :title="file.path">
            {{ file.path }}
          </span>
          <span class="sr-file-count">{{ file.count }}/{{ file.total }}</span>
          <button class="sr-copy" @click="(e) => copyPath(e, file.path)" title="Copy path">⎘</button>
        </div>
        
        <!-- Match list -->
        <div class="sr-matches">
          <div v-for="(m, mIdx) in file.matches" :key="mIdx" class="sr-match">
            <span class="sr-line-num">{{ m.lineNumber }}</span>
            <span class="sr-snippet">{{ m.snippet }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.sr {
  font-family: monospace;
  font-size: 0.75rem;
  border-radius: 6px;
  overflow: hidden;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
}

.sr--warning {
  border-color: var(--color-orange);
  opacity: 0.85;
}

.sr--error {
  border-color: var(--color-red);
  opacity: 0.85;
}

.sr-header {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.4rem;
  padding: 0.35rem 0.5rem;
  cursor: pointer;
  user-select: none;
}

.sr-title {
  color: var(--color-violet);
  font-weight: 600;
  font-size: 0.75rem;
}

.sr-header:hover {
  background: rgba(139, 92, 246, 0.04);
}

.sr-pattern {
  color: var(--color-violet);
  font-weight: 600;
  max-width: 200px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sr-path {
  color: var(--semantic-text-dim);
  font-size: 0.7rem;
  max-width: 150px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sr-summary {
  margin-left: auto;
  color: var(--semantic-text-muted);
  font-size: 0.65rem;
}

.sr-warning-text,
.sr-error-text {
  margin-left: auto;
  font-size: 0.7rem;
}

.sr--warning .sr-warning-text {
  color: var(--color-orange);
}

.sr--error .sr-error-text {
  color: var(--color-red);
}

.sr-toggle {
  color: var(--semantic-text-muted);
  font-size: 0.8rem;
  width: 1rem;
  text-align: center;
}

.sr-content {
  border-top: 1px solid var(--color-border);
  background: rgba(0, 0, 0, 0.02);
}

.sr-file {
  border-bottom: 1px dashed var(--color-border);
}

.sr-file:last-child {
  border-bottom: none;
}

.sr-file-header {
  display: flex;
  align-items: center;
  gap: 0.3rem;
  padding: 0.25rem 0.5rem;
  background: rgba(0, 0, 0, 0.02);
  position: sticky;
  top: 0;
}

.sr-file-path {
  flex: 1;
  color: var(--color-violet);
  font-size: 0.7rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.sr-file-count {
  color: var(--semantic-text-muted);
  font-size: 0.65rem;
}

.sr-copy {
  padding: 0 0.15rem;
  border: none;
  background: none;
  cursor: pointer;
  color: var(--semantic-text-muted);
  opacity: 0;
  transition: opacity 0.15s;
  font-size: 0.85rem;
}

.sr-file-header:hover .sr-copy {
  opacity: 1;
}

.sr-copy:hover {
  color: var(--color-violet);
}

.sr-matches {
  padding: 0.25rem 0;
}

.sr-match {
  display: flex;
  padding: 0.125rem 0.5rem;
  line-height: 1.5;
}

.sr-match:hover {
  background: rgba(139, 92, 246, 0.04);
}

.sr-line-num {
  color: var(--semantic-text-dim);
  min-width: 3rem;
  text-align: right;
  margin-right: 0.75rem;
  user-select: none;
  flex-shrink: 0;
}

.sr-snippet {
  color: var(--semantic-text);
  white-space: pre-wrap;
  word-break: break-all;
  font-size: 0.72rem;
}
</style>
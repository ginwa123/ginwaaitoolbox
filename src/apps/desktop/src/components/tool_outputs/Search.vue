<!-- eslint-disable vue/multi-word-component-names -->
<script setup lang="ts">
import { computed, ref } from 'vue'
import ToolParameters from './_shared/ToolParameters.vue'
import { useInjectOpenInCodeEditor } from '../../composables/useCodeEditor'
import { extractParam } from '../../helpers/extractParam'
import { unescapeXml } from './_shared/toolOutputParser'

const props = defineProps<{
  content: string
  expanded?: boolean
  cwd?: string
  parameters?: string
}>()

const isExpanded = ref(props.expanded ?? false)
const openInEditor = useInjectOpenInCodeEditor()

// Parse search pattern and path. The backend XML-escapes both attributes
// (a raw `"` or `&` in the pattern would otherwise terminate the attribute
// early), so decode them for display.
const searchPattern = computed(() => {
  const match = props.content.match(/pattern="([^"]+)"/)
  return match ? unescapeXml(match[1] ?? '') : null
})

const searchPath = computed(() => {
  const match = props.content.match(/path="([^"]+)"/)
  return match ? unescapeXml(match[1] ?? '') : null
})

// In-progress fallback: prefer envelope, fall back to tool-call parameters
const displayPattern = computed(
  () => searchPattern.value ?? extractParam(props.parameters, 'pattern'),
)
const displayPath = computed(() => searchPath.value ?? extractParam(props.parameters, 'path'))
const isRunning = computed(() => props.content.trim() === '' && displayPattern.value !== null)

// Parse warning if no matches (XML-escaped on the wire).
const warningMessage = computed(() => {
  const match = props.content.match(/<warning>(.*?)<\/warning>/)
  return match ? unescapeXml(match[1] ?? '') : null
})

// Parse error if any
const errorMessage = computed(() => {
  const match = props.content.match(/<error>(.*?)<\/error>/)
  if (!match || !match[1]) return null
  return match[1].trim()
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
    // Path + snippet are XML-escaped on the wire (search.zig escapes every
    // interpolated value), so decode before display. Escaping is also what
    // keeps a snippet from faking a <file> header or closing </m> early.
    const filePath = unescapeXml(match[1] ?? '')
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
        snippet: unescapeXml(m[2] ?? ''),
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

// Status for styling
const hasWarning = computed(() => !!warningMessage.value)
const hasError = computed(() => !!errorMessage.value)

/**
 * Collection summary from the `<search>` element
 * (`returned="N" total="M" truncated="true|false"`). Optional: envelopes
 * persisted before 2026-09-16 carry only pattern/path, so `null` means
 * "unknown" and the header keeps its old wording.
 *
 * `truncated` is the operator-visible half of the backend's silent-
 * truncation fix: a capped search (max_results/head/tail) renders
 * "N of M matches (truncated)" instead of looking exhaustive.
 */
interface SearchSummary {
  returned: number
  total: number
  truncated: boolean
}

const searchSummary = computed((): SearchSummary | null => {
  const m = props.content.match(
    /<search\b[^>]*\breturned="(\d+)"[^>]*\btotal="(\d+)"[^>]*\btruncated="(true|false)"/,
  )
  if (!m) return null
  return {
    returned: parseInt(m[1] ?? '', 10) || 0,
    total: parseInt(m[2] ?? '', 10) || 0,
    truncated: m[3] === 'true',
  }
})

// Arguments guard (mirrors ToolParameters.vue hasArgs): non-empty params
// mean there is something worth expanding even with zero file results.
const hasArgs = computed(() => {
  const p = (props.parameters ?? '').trim()
  return p !== '' && p !== '{}'
})

// Expandable unless pure-running-empty (in-flight, no display info yet).
const isExpandable = computed(() => {
  if (isRunning.value) return false
  return hasWarning.value || hasError.value || fileResults.value.length > 0 || hasArgs.value
})

// Toggle expansion
const toggle = () => {
  if (isExpandable.value) {
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
  <div
    class="chat-tool-card font-mono text-xs"
    :class="{
      'border-orange-500/50 opacity-85': hasWarning,
      'border-red-500/50 opacity-85': hasError,
    }"
  >
    <!-- Header -->
    <div
      class="group flex flex-wrap items-center gap-1 px-2 py-1 cursor-pointer select-none hover:bg-violet-500/5"
      @click="toggle"
      role="button"
      tabindex="0"
    >
      <span class="text-[var(--color-violet)] font-semibold text-xs">search</span>
      <span
        class="text-[var(--color-violet)] font-semibold max-w-[200px] truncate"
        :title="displayPattern || ''"
      >
        "{{ displayPattern || 'unknown' }}"
      </span>
      <span
        class="text-[var(--semantic-text-dim)] text-[0.7rem] max-w-[150px] truncate"
        :title="displayPath || ''"
      >
        in {{ displayPath || 'unknown' }}
      </span>
      <span
        v-if="isRunning"
        data-testid="search-running"
        class="text-[0.65rem] text-yellow-500 animate-pulse"
        >running…</span
      >

      <!-- Results summary -->
      <template v-if="!hasWarning && !hasError">
        <span class="ml-auto text-[var(--semantic-text-muted)] text-[0.65rem]">
          {{ totalFileCount }} {{ totalFileCount === 1 ? 'file' : 'files' }},
          <template v-if="searchSummary && searchSummary.truncated">
            <span data-testid="search-truncated" class="text-orange-500">
              {{ searchSummary.returned }} of {{ searchSummary.total }} matches (truncated)
            </span>
          </template>
          <template v-else>
            {{ totalMatchCount }} {{ totalMatchCount === 1 ? 'match' : 'matches' }}
          </template>
        </span>
      </template>

      <!-- Warning or error message -->
      <template v-else-if="hasWarning">
        <span class="ml-auto text-orange-500 text-[0.7rem]">{{ warningMessage }}</span>
      </template>
      <template v-else-if="hasError">
        <span class="ml-auto text-red-500 text-[0.7rem]">{{ errorMessage }}</span>
      </template>

      <!-- Toggle indicator -->
      <span v-if="isExpandable" class="w-4 text-center text-[var(--semantic-text-muted)] text-sm">
        {{ isExpanded ? '−' : '+' }}
      </span>
    </div>

    <!-- Expanded content -->
    <div v-if="isExpanded" class="border-t border-[var(--color-border)] bg-black/[0.02]">
      <div v-if="fileResults.length > 0">
        <div
          v-for="(file, idx) in fileResults"
          :key="idx"
          class="border-b border-dashed border-[var(--color-border)] last:border-b-0"
        >
          <!-- File header -->
          <div class="flex items-center gap-1 px-2 py-1 bg-black/[0.02]">
            <span
              class="flex-1 text-[var(--color-violet)] text-[0.7rem] truncate"
              :title="file.path"
            >
              {{ file.path }}
            </span>
            <span class="text-[var(--semantic-text-muted)] text-[0.65rem]"
              >{{ file.count }}/{{ file.total }}</span
            >
            <button
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 text-base transition-opacity"
              @click="(e) => copyPath(e, file.path)"
              title="Copy path"
            >
              ⎘
            </button>
            <button
              v-if="props.cwd && openInEditor"
              class="px-0.5 border-none bg-transparent cursor-pointer text-[var(--semantic-text-muted)] opacity-0 group-hover:opacity-100 hover:!text-violet-500 transition-opacity"
              @click="(e) => handleOpenInEditor(e, file.path)"
              title="Open in code editor"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                />
              </svg>
            </button>
          </div>

          <!-- Match list -->
          <div class="py-0.5">
            <div
              v-for="(m, mIdx) in file.matches"
              :key="mIdx"
              class="flex py-0.5 px-2 leading-relaxed hover:bg-violet-500/5"
            >
              <span
                class="min-w-[3rem] text-right mr-3 text-[var(--semantic-text-dim)] select-none shrink-0"
              >
                {{ m.lineNumber }}
              </span>
              <span
                class="whitespace-pre-wrap break-all text-[0.72rem] text-[var(--semantic-text)]"
              >
                {{ m.snippet }}
              </span>
            </div>
          </div>
        </div>
      </div>
      <ToolParameters :parameters="parameters" />
    </div>
  </div>
</template>

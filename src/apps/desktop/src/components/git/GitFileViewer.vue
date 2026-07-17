<script setup lang="ts">
import { ref, onMounted, watch, nextTick } from 'vue'
import * as api from '../../api'
import type { GitFileDiff } from '../../api'
import FileInput from '../file/FileInput.vue'

interface Props {
  cwd: string
  filePath: string
  fileName: string
  staged?: boolean
}

const props = withDefaults(defineProps<Props>(), {
  staged: false,
})

const emit = defineEmits<{
  close: []
  submitReview: [message: string]
}>()

// State
const isLoading = ref(false)
const error = ref<string | null>(null)
const diff = ref<GitFileDiff | null>(null)
const wordWrap = ref(false)

// Mini chat popup state
const showMiniChat = ref(false)
const miniChatPosition = ref({ x: 0, y: 0 })
const miniChatContent = ref('')
const miniChatFilePath = ref('')
const miniChatFileName = ref('')
const miniChatStartLine = ref(0)
const miniChatEndLine = ref(0)

// Stats
const stats = ref({ added: 0, removed: 0 })

// Parsed diff lines for GitHub-style rendering
interface DiffLine {
  type: 'add' | 'remove' | 'context' | 'header' | 'hunk' | 'empty'
  content: string
  oldLineNum?: number
  newLineNum?: number
  lineIndex: number
}

const diffLines = ref<DiffLine[]>([])

// Mini chat functions
const openMiniChat = (event: MouseEvent, line: DiffLine) => {
  console.log('[GitFileViewer] openMiniChat called', line.type, line.content.substring(0, 30))
  event.preventDefault()
  event.stopPropagation()
  
  // Get click position
  miniChatPosition.value = {
    x: event.clientX,
    y: event.clientY
  }
  
  // Build diff context (include nearby lines for context)
  const lineIdx = diffLines.value.indexOf(line)
  const startIdx = Math.max(0, lineIdx - 3)
  const endIdx = Math.min(diffLines.value.length, lineIdx + 4)
  
  const contextLines = diffLines.value.slice(startIdx, endIdx)
  
  // Guard: ensure contextLines is not empty
  if (contextLines.length === 0) return
  
  // Store file path and line numbers for review header
  miniChatFilePath.value = props.filePath
  miniChatFileName.value = props.fileName
  miniChatStartLine.value = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
  miniChatEndLine.value = contextLines[contextLines.length - 1]!.newLineNum || contextLines[contextLines.length - 1]!.oldLineNum || 0
  
  // Build content with line numbers
  miniChatContent.value = contextLines.map(l => {
    const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
    const lineNum = l.newLineNum || l.oldLineNum || ''
    return `${lineNum} ${prefix}${l.content}`
  }).join('\n')
  
  console.log('[GitFileViewer] showMiniChat set to true')
  showMiniChat.value = true
}

const closeMiniChat = () => {
  showMiniChat.value = false
  miniChatContent.value = ''
  miniChatFilePath.value = ''
  miniChatFileName.value = ''
  miniChatStartLine.value = 0
  miniChatEndLine.value = 0
}

const submitMiniChat = (message: string) => {
  // Build review message with code context, file path, and line numbers
  const lineRange = miniChatStartLine.value === miniChatEndLine.value
    ? `Line ${miniChatStartLine.value}`
    : `Lines ${miniChatStartLine.value}-${miniChatEndLine.value}`
  
  const reviewWithContext = `## Code Review\n**File:** \`${miniChatFilePath.value}\`\n**${lineRange}**\n\n\`\`\`\n${miniChatContent.value}\n\`\`\`\n\n## Review Comment\n\n${message}`
  emit('submitReview', reviewWithContext)
  closeMiniChat()
}

// Parse unified diff format from git diff command
const parseUnifiedDiff = (diffText: string) => {
  const lines = diffText.split('\n')
  const parsed: DiffLine[] = []
  
  let added = 0
  let removed = 0
  let lineIndex = 0
  
  // Current hunk state
  let oldLine = 0
  let newLine = 0
  let inHunk = false
  
  for (const line of lines) {
    // Skip the "diff --git" header line at the very start
    if (line.startsWith('diff --git') || line.startsWith('index ')) {
      continue
    }
    
    // Hunk header: @@ -oldStart,oldCount +newStart,newCount @@
    const hunkMatch = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)?$/)
    if (hunkMatch) {
      inHunk = true
      oldLine = tryParseInt(hunkMatch[1] ?? '') ?? 1
      newLine = tryParseInt(hunkMatch[2] ?? '') ?? 1
      
      parsed.push({
        type: 'hunk',
        content: line,
        lineIndex: lineIndex++,
      })
      continue
    }
    
    if (!inHunk) {
      // Before any hunk, this might be a new file indicator
      if (line.startsWith('---') || line.startsWith('+++')) {
        continue  // Skip file headers
      }
      continue
    }
    
    if (line.length === 0) {
      // Empty line - preserve alignment
      parsed.push({
        type: 'empty',
        content: '',
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      continue
    }
    
    const firstChar = line[0]
    
    if (firstChar === '+') {
      // Added line
      parsed.push({
        type: 'add',
        content: line.substring(1),
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      added++
      newLine++
    } else if (firstChar === '-') {
      // Removed line
      parsed.push({
        type: 'remove',
        content: line.substring(1),
        oldLineNum: oldLine,
        lineIndex: lineIndex++,
      })
      removed++
      oldLine++
    } else if (firstChar === ' ') {
      // Context line
      parsed.push({
        type: 'context',
        content: line.substring(1),
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      oldLine++
      newLine++
    } else {
      // Line without prefix (shouldn't happen in valid diff, but handle it)
      parsed.push({
        type: 'context',
        content: line,
        oldLineNum: oldLine,
        newLineNum: newLine,
        lineIndex: lineIndex++,
      })
      oldLine++
      newLine++
    }
  }
  
  diffLines.value = parsed
  stats.value = { added, removed }
}

// Helper to safely parse int
const tryParseInt = (s: string): number | null => {
  const n = parseInt(s, 10)
  return isNaN(n) ? null : n
}

// Syntax highlighting for a line (simple HTML escaping)
const highlightLine = (line: string): string => {
  if (!line) return '&nbsp;'
  
  // Escape HTML
  return line
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

// Load diff data
const loadDiff = async () => {
  if (!props.cwd || !props.filePath) return

  isLoading.value = true
  error.value = null

  try {
    console.log('[GitFileViewer] Fetching diff for:', props.filePath, 'staged:', props.staged)
    diff.value = await api.getGitFileDiff(props.cwd, props.filePath, props.staged)
    
    console.log('[GitFileViewer] Got diff response:', {
      path: diff.value.path,
      diffLength: diff.value.diff_content.length,
      diffPreview: diff.value.diff_content.substring(0, 500),
    })
    
    // Parse the unified diff
    parseUnifiedDiff(diff.value.diff_content)
    
    console.log('[GitFileViewer] Parsed lines:', diffLines.value.length, 'stats:', stats.value)
  } catch (err) {
    console.error('[GitFileViewer] Failed to load diff:', err)
    error.value = 'Failed to load file diff'
  } finally {
    isLoading.value = false
  }
}

// Watch for changes
watch(() => [props.cwd, props.filePath, props.staged], () => {
  loadDiff()
})

onMounted(() => {
  loadDiff()
})
</script>

<template>
  <div class="git-file-viewer flex flex-col h-full" style="background: var(--semantic-card-bg);">
    <!-- Header -->
    <div
      class="flex items-center h-10 px-4 shrink-0 gap-3"
      style="background: var(--color-bg-m2); border-bottom: 1px solid var(--color-border);"
    >
      <!-- File icon and name -->
      <div class="flex items-center gap-2 flex-1 min-w-0">
        <span class="text-sm">📄</span>
        <span
          class="text-sm font-medium truncate"
          style="color: var(--semantic-text);"
          :title="filePath"
        >
          {{ fileName }}
        </span>
        <span
          v-if="staged"
          class="text-xs px-1.5 py-0.5 rounded"
          style="background: rgba(135, 169, 135, 0.15); color: var(--color-green);"
        >
          Staged
        </span>
      </div>

      <!-- Stats -->
      <div class="flex items-center gap-3 text-xs font-mono">
        <span style="color: var(--color-green);">+{{ stats.added }}</span>
        <span style="color: var(--color-red);">-{{ stats.removed }}</span>
      </div>

      <!-- Word wrap toggle -->
      <button
        @click="wordWrap = !wordWrap"
        class="px-2 py-1 text-xs rounded transition-colors"
        :style="{
          backgroundColor: wordWrap ? 'var(--semantic-active-bg)' : 'transparent',
          color: wordWrap ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
        }"
        title="Toggle word wrap"
      >
        Wrap
      </button>

      <!-- Close button -->
      <button
        @click="emit('close')"
        class="p-1.5 rounded hover:opacity-70 transition-opacity"
        title="Close"
      >
        <svg class="w-4 h-4" style="color: var(--semantic-text-dim);" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <!-- Loading -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <svg class="animate-spin w-6 h-6" style="color: var(--color-aqua);" viewBox="0 0 24 24" fill="none">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
      </svg>
    </div>

    <!-- Error -->
    <div v-else-if="error" class="flex-1 flex flex-col items-center justify-center p-4">
      <span class="text-3xl mb-3">⚠️</span>
      <p class="text-sm" style="color: var(--semantic-error);">{{ error }}</p>
      <button
        @click="loadDiff"
        class="mt-3 px-3 py-1.5 text-sm rounded"
        style="background: var(--color-green); color: var(--color-bg);"
      >
        Retry
      </button>
    </div>

    <!-- No diff content -->
    <div
      v-else-if="diffLines.length === 0"
      class="flex-1 flex flex-col items-center justify-center p-4"
    >
      <span class="text-3xl mb-3">📄</span>
      <p class="text-sm" style="color: var(--semantic-text-dim);">No changes detected</p>
      <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
        File may be identical to the committed version
      </p>
    </div>

    <!-- GitHub-style Diff View -->
    <div
      v-else
      class="flex-1 overflow-auto"
      :class="{ 'wrap-on': wordWrap }"
      :style="{ fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace' }"
    >
      <table class="w-full border-collapse" style="font-size: 12px; line-height: 20px;">
        <tbody>
          <template v-for="(line, idx) in diffLines" :key="idx">
            <!-- Hunk header -->
            <tr
              v-if="line.type === 'hunk'"
              class="hunk-header"
            >
              <td
                colspan="3"
                class="px-3 py-1"
                style="background: rgba(139, 164, 176, 0.1); color: var(--color-blue);"
              >
                {{ line.content }}
              </td>
            </tr>
            
            <!-- Empty line placeholder -->
            <tr
              v-else-if="line.type === 'empty'"
              style="background: var(--semantic-card-bg); height: 20px;"
            >
              <td class="w-12"></td>
              <td class="w-12"></td>
              <td style="border-left: 3px solid transparent;"></td>
            </tr>
            
            <!-- Added line -->
            <tr
              v-else-if="line.type === 'add'"
              class="diff-line diff-line-add"
              @click="openMiniChat($event, line)"
              style="cursor: pointer;"
            >
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none;"
              >
                {{ line.newLineNum || '' }}
              </td>
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none;"
              >
              </td>
              <td
                class="px-2"
                style="border-left: 3px solid var(--color-green); background: rgba(135, 169, 135, 0.15); color: var(--semantic-text);"
              >
                <span style="color: var(--color-green); font-weight: bold;">+</span>
                <span v-html="highlightLine(line.content)"></span>
              </td>
            </tr>
            
            <!-- Removed line -->
            <tr
              v-else-if="line.type === 'remove'"
              class="diff-line diff-line-remove"
              @click="openMiniChat($event, line)"
              style="cursor: pointer;"
            >
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none;"
              >
              </td>
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none;"
              >
                {{ line.oldLineNum || '' }}
              </td>
              <td
                class="px-2"
                style="border-left: 3px solid var(--color-red); background: rgba(196, 116, 110, 0.15); color: var(--semantic-text);"
              >
                <span style="color: var(--color-red); font-weight: bold;">-</span>
                <span v-html="highlightLine(line.content)"></span>
              </td>
            </tr>
            
            <!-- Context line -->
            <tr
              v-else-if="line.type === 'context'"
              class="diff-line diff-line-context"
            >
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none;"
              >
                {{ line.oldLineNum || '' }}
              </td>
              <td
                class="w-12 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none;"
              >
                {{ line.newLineNum || '' }}
              </td>
              <td
                class="px-2"
                style="border-left: 3px solid transparent; color: var(--semantic-text);"
              >
                <span style="color: var(--semantic-text-dim);"> </span>
                <span v-html="highlightLine(line.content)"></span>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>

    <!-- Mini Chat Popup (floating near clicked line) -->
    <Teleport to="body">
      <div v-if="showMiniChat" 
        class="mini-chat-popup"
        :style="{
          left: miniChatPosition.x + 'px',
          top: miniChatPosition.y + 'px',
        }">
        <div class="mini-chat-header">
          <span style="color: var(--color-green);">💬</span>
          <span class="text-sm font-medium" style="color: var(--semantic-text);">Review this code</span>
          <button @click="closeMiniChat" class="ml-auto p-1 rounded hover:opacity-70">
            <svg class="w-4 h-4" style="color: var(--semantic-text-dim);" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        <div class="mini-chat-code">
          <pre>{{ miniChatContent }}</pre>
        </div>
        <FileInput
          :cwd="cwd"
          :reviewMode="true"
          :initialMessage="''"
          @submit="submitMiniChat"
        />
      </div>
    </Teleport>
  </div>
</template>

<style>
/* Mini Chat Popup - NOT scoped because it uses Teleport */
.mini-chat-popup {
  position: fixed;
  z-index: 9999;
  width: 400px;
  max-width: 90vw;
  background: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  border-radius: 12px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
  overflow: hidden;
  transform: translate(-50%, 10px);
}

.mini-chat-popup .mini-chat-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  background: var(--color-bg-m2);
  border-bottom: 1px solid var(--color-border);
}

.mini-chat-popup .mini-chat-code {
  max-height: 150px;
  overflow-y: auto;
  padding: 10px 12px;
  background: var(--semantic-sidebar-bg);
  border-bottom: 1px solid var(--color-border);
}

.mini-chat-popup .mini-chat-code pre {
  margin: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 11px;
  line-height: 1.5;
  color: var(--semantic-text);
  white-space: pre-wrap;
  word-break: break-all;
}
</style>

<style scoped>
.git-file-viewer {
  height: 100%;
}

/* Word wrap support */
.wrap-on table {
  white-space: pre-wrap;
  word-break: break-all;
}

.wrap-on .diff-line td:last-child {
  word-break: break-all;
}

/* Scrollbar styling */
.overflow-auto::-webkit-scrollbar {
  width: 10px;
  height: 10px;
}

.overflow-auto::-webkit-scrollbar-track {
  background: var(--color-bg-m2);
}

.overflow-auto::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 5px;
}

.overflow-auto::-webkit-scrollbar-thumb:hover {
  background: var(--color-gray-3);
}

.overflow-auto::-webkit-scrollbar-corner {
  background: var(--semantic-card-bg);
}

/* Line hover effect */
.diff-line:hover {
  filter: brightness(1.1);
}

/* Hunk header */
.hunk-header td {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}
</style>
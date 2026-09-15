<script setup lang="ts">
import { computed, ref } from 'vue'
import FileInput from '../../file/FileInput.vue'
import { escapeDiffHtml, type ParsedDiffLine } from './parseUnifiedDiff'

/**
 * Shared full diff view: file header (back/filename/stats/Wrap/Open),
 * loading/error/empty states, GitHub-style hunk table, and the
 * review mini-chat popup. Presentational — data flows in via props,
 * user actions flow out via emits. Used full-height in ChatView's
 * center column; the sidebar panel is list-only.
 */
const props = defineProps<{
  path: string
  lines: ParsedDiffLine[]
  added: number
  removed: number
  staged?: boolean
  loading?: boolean
  error?: string | null
  /** cwd for the review FileInput. */
  cwd: string
  /** Show the back button (center mode). Panel list mode hides it. */
  showBack?: boolean
  backLabel?: string
}>()

const emit = defineEmits<{
  back: []
  open: [payload: { path: string; line?: number }]
  retry: []
  'submit-review': [message: string]
}>()

const wordWrap = ref(false)

// Mini chat popup state (moved verbatim from SidebarDiffPanel).
const showMiniChat = ref(false)
const miniChatPosition = ref({ x: 0, y: 0 })
const miniChatContent = ref('')
const miniChatFilePath = ref('')
const miniChatStartLine = ref(0)
const miniChatEndLine = ref(0)

const miniChatStyle = computed(() => {
  const vw = typeof globalThis.window !== 'undefined' ? globalThis.window.innerWidth : 1280
  const vh = typeof globalThis.window !== 'undefined' ? globalThis.window.innerHeight : 800
  return {
    left: Math.min(miniChatPosition.value.x, vw - 420) + 'px',
    top: Math.min(miniChatPosition.value.y, vh - 300) + 'px',
    width: '400px',
    backgroundColor: 'var(--semantic-card-bg)',
    border: '1px solid var(--color-border)',
  }
})

const openMiniChat = (event: MouseEvent, line: ParsedDiffLine) => {
  if (line.type !== 'add' && line.type !== 'remove') return
  event.preventDefault()
  event.stopPropagation()
  miniChatPosition.value = { x: event.clientX, y: event.clientY }
  const lineIdx = props.lines.indexOf(line)
  const startIdx = Math.max(0, lineIdx - 3)
  const endIdx = Math.min(props.lines.length, lineIdx + 4)
  const contextLines = props.lines.slice(startIdx, endIdx)
  if (contextLines.length === 0) return
  miniChatFilePath.value = props.path
  miniChatStartLine.value = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
  const last = contextLines[contextLines.length - 1]!
  miniChatEndLine.value = last.newLineNum || last.oldLineNum || 0
  miniChatContent.value = contextLines
    .map((l) => {
      const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
      const lineNum = l.newLineNum || l.oldLineNum || ''
      return `${lineNum} ${prefix}${l.content}`
    })
    .join('\n')
  showMiniChat.value = true
}

const closeMiniChat = () => {
  showMiniChat.value = false
  miniChatContent.value = ''
  miniChatFilePath.value = ''
  miniChatStartLine.value = 0
  miniChatEndLine.value = 0
}

const submitMiniChat = (message: string) => {
  const lineRange =
    miniChatStartLine.value === miniChatEndLine.value
      ? `Line ${miniChatStartLine.value}`
      : `Lines ${miniChatStartLine.value}-${miniChatEndLine.value}`
  emit(
    'submit-review',
    `## Code Review\n**File:** \`${miniChatFilePath.value}\`\n**${lineRange}**\n\n\`\`\`\n${miniChatContent.value}\n\`\`\`\n\n## Review Comment\n\n${message}`,
  )
  closeMiniChat()
}

const firstAddLine = computed(() => props.lines.find((l) => l.type === 'add')?.newLineNum)

const openFile = () => emit('open', { path: props.path, line: firstAddLine.value })
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="sidebar-diff-view">
    <div
      class="flex items-center gap-2 px-3 py-2 shrink-0"
      style="background: var(--color-bg-m2); border-bottom: 1px solid var(--color-border)"
    >
      <button
        v-if="showBack"
        type="button"
        class="shrink-0 px-2 h-7 rounded flex items-center gap-1 text-xs hover:opacity-70 transition-opacity"
        style="color: var(--semantic-text-dim)"
        title="Back to chat"
        aria-label="Back to chat"
        data-testid="sidebar-diff-back"
        @click="emit('back')"
      >
        ‹ {{ backLabel ?? 'Back' }}
      </button>
      <span
        class="text-xs font-medium truncate flex-1"
        style="color: var(--semantic-text)"
        :title="path"
        data-testid="sidebar-diff-selected"
      >
        {{ path }}
      </span>
      <span
        v-if="staged"
        class="text-xs px-1.5 py-0.5 rounded"
        style="background: rgba(135, 169, 135, 0.15); color: var(--color-green)"
      >
        Staged
      </span>
      <span class="text-xs font-mono" style="color: var(--color-green)"> +{{ added }} </span>
      <span class="text-xs font-mono" style="color: var(--color-red)"> -{{ removed }} </span>
      <button
        type="button"
        class="px-2 py-1 text-xs rounded"
        :style="{
          backgroundColor: wordWrap ? 'var(--semantic-active-bg)' : 'transparent',
          color: wordWrap ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
        }"
        title="Toggle word wrap"
        @click="wordWrap = !wordWrap"
      >
        Wrap
      </button>
      <button
        type="button"
        class="px-2 py-1 text-xs rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Open file in code browser"
        aria-label="Open file in code browser"
        data-testid="sidebar-diff-open-file"
        @click="openFile"
      >
        ⤴
      </button>
    </div>

    <div v-if="loading" class="flex items-center justify-center py-6">
      <svg
        class="animate-spin w-5 h-5"
        style="color: var(--color-aqua)"
        viewBox="0 0 24 24"
        fill="none"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
        />
      </svg>
    </div>

    <div v-else-if="error" class="flex flex-col items-center justify-center p-4">
      <span class="text-2xl mb-2">⚠️</span>
      <p class="text-xs" style="color: var(--semantic-error)">{{ error }}</p>
      <button
        type="button"
        class="mt-3 px-3 py-1.5 text-sm rounded"
        style="background: var(--color-green); color: var(--color-bg)"
        data-testid="sidebar-diff-retry"
        @click="emit('retry')"
      >
        Retry
      </button>
    </div>

    <div v-else-if="lines.length === 0" class="flex flex-col items-center justify-center p-4">
      <span class="text-2xl mb-2">📄</span>
      <p class="text-xs" style="color: var(--semantic-text-dim)">No changes detected</p>
    </div>

    <div
      v-else
      class="flex-1 min-h-0 overflow-auto"
      :class="{ 'wrap-on': wordWrap }"
      :style="{
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
      }"
    >
      <table class="w-full border-collapse" style="font-size: 12px; line-height: 20px">
        <tbody>
          <template v-for="(line, idx) in lines" :key="idx">
            <tr v-if="line.type === 'hunk'">
              <td
                colspan="3"
                class="px-3 py-1"
                style="background: rgba(139, 164, 176, 0.1); color: var(--color-blue)"
              >
                {{ line.content }}
              </td>
            </tr>
            <tr
              v-else-if="line.type === 'add'"
              style="cursor: pointer"
              @click="openMiniChat($event, line)"
            >
              <td
                class="w-10 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.newLineNum || '' }}
              </td>
              <td
                class="w-10 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              ></td>
              <td
                class="px-2"
                style="
                  border-left: 3px solid var(--color-green);
                  background: rgba(135, 169, 135, 0.15);
                  color: var(--semantic-text);
                "
              >
                <span style="color: var(--color-green); font-weight: bold">+</span>
                <span v-html="escapeDiffHtml(line.content)"></span>
              </td>
            </tr>
            <tr
              v-else-if="line.type === 'remove'"
              style="cursor: pointer"
              @click="openMiniChat($event, line)"
            >
              <td
                class="w-10 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.oldLineNum || '' }}
              </td>
              <td
                class="w-10 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              ></td>
              <td
                class="px-2"
                style="
                  border-left: 3px solid var(--color-red);
                  background: rgba(169, 135, 135, 0.15);
                  color: var(--semantic-text);
                "
              >
                <span style="color: var(--color-red); font-weight: bold">−</span>
                <span v-html="escapeDiffHtml(line.content)"></span>
              </td>
            </tr>
            <tr v-else-if="line.type === 'context'">
              <td
                class="w-10 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.oldLineNum || '' }}
              </td>
              <td
                class="w-10 px-2 text-right select-none"
                style="color: var(--semantic-text-dim); user-select: none"
              >
                {{ line.newLineNum || '' }}
              </td>
              <td class="px-2" style="color: var(--semantic-text-dim)">
                <span>&nbsp;</span>
                <span v-html="escapeDiffHtml(line.content)"></span>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>

    <Teleport to="body">
      <div
        v-if="showMiniChat"
        class="mini-chat-popup fixed z-50 rounded-lg shadow-lg p-3"
        :style="miniChatStyle"
      >
        <div class="text-xs mb-2 flex items-center gap-2" style="color: var(--semantic-text-dim)">
          <span class="flex-1"
            >Review {{ miniChatFilePath }} ({{ miniChatStartLine }}–{{ miniChatEndLine }})</span
          >
          <button
            type="button"
            class="hover:opacity-70"
            title="Close review"
            @click="closeMiniChat"
          >
            ✕
          </button>
        </div>
        <FileInput :cwd="cwd" :review-mode="true" @submit="submitMiniChat" />
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.wrap-on td:last-child {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>

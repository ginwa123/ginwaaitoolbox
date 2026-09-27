<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import DiffCommentBox, {
  copyTextToClipboard,
  deleteSavedComment,
  formatReviewComment,
  listSavedComments,
  type DiffCommentSavePayload,
  type SavedComment,
} from './DiffCommentBox.vue'
import { escapeDiffHtml, type ParsedDiffLine } from './parseUnifiedDiff'

/**
 * Shared full diff view: file header (back/filename/stats/Open),
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
  /** cwd for the review DiffCommentBox. */
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
  'comment-saved': [payload: DiffCommentSavePayload]
}>()

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

const openBoxAtRange = (start: number, end: number, context: string) => {
  miniChatFilePath.value = props.path
  miniChatStartLine.value = start
  miniChatEndLine.value = end
  miniChatContent.value = context
  showMiniChat.value = true
}

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
  const start = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
  const last = contextLines[contextLines.length - 1]!
  const end = last.newLineNum || last.oldLineNum || 0
  const content = contextLines
    .map((l) => {
      const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
      const lineNum = l.newLineNum || l.oldLineNum || ''
      return `${lineNum} ${prefix}${l.content}`
    })
    .join('\n')
  openBoxAtRange(start, end, content)
}

const closeMiniChat = () => {
  showMiniChat.value = false
  miniChatContent.value = ''
  miniChatFilePath.value = ''
  miniChatStartLine.value = 0
  miniChatEndLine.value = 0
}

const reviewedVersion = ref(0)
const savedThreads = computed(() => {
  void reviewedVersion.value
  return listSavedComments(props.cwd, props.path)
})

const threadsAfterRow = computed(() => {
  const map = new Map<number, SavedComment[]>()
  for (const thread of savedThreads.value) {
    let anchor = -1
    props.lines.forEach((line, idx) => {
      let n: number | undefined
      if (line.type === 'add') n = line.newLineNum
      else if (line.type === 'remove') n = line.oldLineNum
      else if (line.type === 'context') n = line.newLineNum || line.oldLineNum
      else return
      if (n != null && n >= thread.start && n <= thread.end) anchor = idx
    })
    if (anchor < 0) continue
    const list = map.get(anchor)
    if (list) list.push(thread)
    else map.set(anchor, [thread])
  }
  return map
})

function threadsAfter(idx: number): SavedComment[] {
  return threadsAfterRow.value.get(idx) ?? []
}

function formatSavedTime(ts: number): string {
  try {
    return new Date(ts).toLocaleString()
  } catch {
    return ''
  }
}

const editingKey = ref<string | null>(null)
const threadKey = (thread: SavedComment) => `${thread.start}-${thread.end}`

const editThread = (thread: SavedComment) => {
  editingKey.value = threadKey(thread)
}

const cancelEdit = () => {
  editingKey.value = null
}

const deleteThread = (thread: SavedComment) => {
  deleteSavedComment(props.cwd, props.path, thread.start, thread.end)
  reviewedVersion.value++
}

const copiedKey = ref<string | null>(null)
let copiedTimer: ReturnType<typeof setTimeout> | null = null

const copyThread = async (thread: SavedComment) => {
  await copyTextToClipboard(
    formatReviewComment(props.path, thread.start, thread.end, thread.context, thread.message),
  )
  copiedKey.value = threadKey(thread)
  if (copiedTimer) clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => {
    copiedKey.value = null
  }, 2000)
}

watch(
  () => props.path,
  () => {
    reviewedVersion.value = 0
    editingKey.value = null
  },
)

const handleCommentSave = (payload: DiffCommentSavePayload) => {
  closeMiniChat()
  editingKey.value = null
  reviewedVersion.value++
  emit('comment-saved', payload)
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
      class="flex-1 min-h-0 overflow-auto diff-wrap"
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
            <tr
              v-if="threadsAfter(idx).length > 0"
              data-testid="diff-comment-thread"
            >
              <td colspan="3" class="px-2 py-1">
                <div
                  v-for="thread in threadsAfter(idx)"
                  :key="`${thread.start}-${thread.end}`"
                  class="rounded p-2 mb-1"
                  style="border: 1px solid var(--color-border)"
                >
                  <div
                    class="text-xs font-medium mb-1"
                    style="color: var(--semantic-text)"
                  >
                    Comment on lines {{ thread.start }}–{{ thread.end }}
                    <span
                      v-if="thread.savedAt"
                      class="font-normal"
                      style="color: var(--semantic-text-dim)"
                      data-testid="diff-comment-time"
                      >· {{ formatSavedTime(thread.savedAt) }}</span
                    >
                  </div>
                  <div v-if="editingKey === threadKey(thread)">
                    <DiffCommentBox
                      :file-path="path"
                      :start-line="thread.start"
                      :end-line="thread.end"
                      :context="thread.context"
                      :cwd="cwd"
                      @save="handleCommentSave"
                    />
                    <button
                      type="button"
                      class="text-xs hover:opacity-70 mt-1"
                      style="color: var(--color-blue)"
                        data-testid="diff-comment-cancel"
                      @click="cancelEdit"
                    >
                      Cancel
                    </button>
                  </div>
                  <div v-else>
                    <div
                      class="text-xs whitespace-pre-wrap mb-1"
                      style="color: var(--semantic-text)"
                      data-testid="diff-comment-message"
                    >
                      {{ thread.message }}
                    </div>
                    <div class="flex gap-3">
                      <button
                        type="button"
                        class="text-xs hover:opacity-70"
                        style="color: var(--color-blue)"
                        data-testid="diff-comment-edit"
                        @click="editThread(thread)"
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        class="text-xs hover:opacity-70"
                        style="color: var(--color-blue)"
                        data-testid="diff-comment-delete"
                        @click="deleteThread(thread)"
                      >
                        Delete
                      </button>
                      <button
                        type="button"
                        class="text-xs hover:opacity-70"
                        style="color: var(--color-blue)"
                        data-testid="diff-comment-copy"
                        @click="copyThread(thread)"
                      >
                        Copy
                      </button>
                      <span
                        v-if="copiedKey === threadKey(thread)"
                        class="text-xs"
                        style="color: var(--color-green)"
                        data-testid="diff-comment-copied"
                      >
                        Copied
                      </span>
                    </div>
                  </div>
                </div>
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
        <DiffCommentBox
          :file-path="miniChatFilePath"
          :start-line="miniChatStartLine"
          :end-line="miniChatEndLine"
          :context="miniChatContent"
          :cwd="cwd"
          @save="handleCommentSave"
        />
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
/* Long diff lines are the common case (minified blobs, wide tables), so
   soft-wrap is always on rather than an opt-in header toggle. */
.diff-wrap td:last-child {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>

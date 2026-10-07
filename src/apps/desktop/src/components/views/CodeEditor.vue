<script setup lang="ts">
import { computed, nextTick, onMounted, onUpdated, ref } from 'vue'
import { detectLanguage, highlightLine } from '@/helpers/codeHighlight'
import { displayPathFor } from '@/composables/useCodeEditorSession'
import UiIcon from '../ui/UiIcon.vue'
import type { UiIconName } from '../ui/icons'

/**
 * Read-only code viewer for `?view=code-editor`.
 *
 * Rendering follows the git-diff-review pattern (`SidebarDiffView.vue` /
 * `GitFileViewer.vue` / `tool_outputs/_shared/DiffView.vue`): one table row
 * per line, a sticky line-number gutter, soft-wrap always on, and the
 * repo's zero-dependency tokenizer (`helpers/codeHighlight`) painting
 * `tok-*` spans with the same palette as the diff cards.
 *
 * Why not Monaco (bug: task_1790594549955_1 — "when i click code editor
 * there is no code"): the previous version lazy-loaded monaco through a
 * dynamic import marked with the `@vite-ignore` comment. That marker
 * makes Vite keep the BARE specifier in the emitted bundle
 * (``import(`monaco-editor`)``), which no browser can resolve, so
 * `onMounted` rejected with `Failed to resolve module specifier
 * "monaco-editor"` and the body rendered empty while the header still
 * painted. The jsdom specs could not see it (vitest aliases
 * `monaco-editor` to a stub and ignores unhandled errors) and the Vite
 * dev server resolves bare specifiers itself — only the built bundle
 * failed. Rendering with the shared tokenizer removes the runtime module
 * resolution entirely, so there is nothing left to resolve at runtime,
 * and the viewer matches the diff review the user already reads.
 *
 * The component is presentational: `AppLayout` owns the open-file session
 * (file / content / loading / error) and passes the text down.
 */

const props = defineProps<{
  filePath: string
  fileName: string
  /** Whole-file text, already fetched by the session composable. */
  content?: string
  /** Explicit language override; defaults to the file extension. */
  language?: string
  cwd?: string
  /**
   * Optional 1-based line to jump to once the viewer mounts (threaded
   * from the diff review's "open at this line" / `?line=` deep link).
   * The target row is marked and scrolled to the middle of the viewport.
   */
  line?: number
}>()

const emit = defineEmits<{
  close: []
}>()

const bodyEl = ref<HTMLElement | null>(null)

const detectedLanguage = computed(() => props.language || detectLanguage(props.fileName))

const hasContent = computed(() => (props.content ?? '').length > 0)

// A file that ends in a newline would otherwise render a phantom last
// row (editors number real lines only).
const lines = computed<string[]>(() => {
  const raw = (props.content ?? '').split('\n')
  if (raw.length > 1 && raw[raw.length - 1] === '') raw.pop()
  return raw
})

const lineCount = computed(() => lines.value.length)

const targetLine = computed(() =>
  typeof props.line === 'number' && props.line > 0 ? props.line : null,
)

const isTarget = (lineNumber: number) => targetLine.value === lineNumber

/** Split one line into colored token spans (plaintext ⇒ one plain span). */
const tokensFor = (line: string) => highlightLine(line, detectedLanguage.value)

/**
 * Bring the requested line into view. Best-effort: jsdom has no
 * `scrollIntoView`, and a `?line=` beyond EOF is simply ignored.
 */
async function scrollToTarget(): Promise<void> {
  const line = targetLine.value
  if (line === null) return
  await nextTick()
  const row = bodyEl.value?.querySelector<HTMLElement>(`[data-line="${line}"]`)
  if (row && typeof row.scrollIntoView === 'function') {
    row.scrollIntoView({ block: 'center' })
  }
}

onMounted(() => {
  void scrollToTarget()
})

// Re-scroll when the target line or the content changes (prev-value guard
// on update — same call the watcher made; mount is covered above).
let prevEditorLine = props.line
let prevEditorContent = props.content
onUpdated(() => {
  if (props.line === prevEditorLine && props.content === prevEditorContent) return
  prevEditorLine = props.line
  prevEditorContent = props.content
  void scrollToTarget()
})

// Footer shows the full path. filePath from the sidebar explorer is
// already absolute (backend listDirectory joins dir_path + name), so
// prefixing cwd would double it:
// /home/u/work//home/u/work/migration/README.md. The shared
// displayPathFor helper joins only relative paths.
const displayPath = computed(() => displayPathFor(props.cwd, props.filePath))

// File icon for display
const getFileIcon = (fileName: string): UiIconName => {
  const ext = fileName.split('.').pop()?.toLowerCase() || ''
  const iconMap: Record<string, UiIconName> = {
    js: 'scroll',
    jsx: 'atom',
    ts: 'book',
    tsx: 'atom',
    vue: 'code',
    html: 'globe',
    htm: 'globe',
    css: 'palette',
    scss: 'palette',
    less: 'palette',
    json: 'clipboard',
    md: 'note',
    markdown: 'note',
    xml: 'file',
    yaml: 'settings',
    yml: 'settings',
    py: 'code',
    zig: 'code',
    rs: 'code',
    go: 'circle',
    txt: 'file',
    gitignore: 'lock',
    env: 'key',
  }
  return iconMap[ext] ?? 'file'
}

const handleClose = () => {
  emit('close')
}
</script>

<template>
  <div
    class="code-editor flex flex-col h-full min-h-0 overflow-hidden"
    data-testid="code-editor"
    style="background-color: var(--semantic-content-bg)"
  >
    <!-- Header -->
    <div
      class="h-12 flex items-center justify-between px-4 shrink-0"
      style="background-color: var(--color-bg-m2); border-bottom: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-3 min-w-0">
        <button
          type="button"
          @click="handleClose"
          class="p-2 rounded-lg hover:opacity-70 transition-opacity shrink-0"
          title="Close"
          aria-label="Close"
          data-testid="code-editor-close"
        >
          <svg
            class="w-4 h-4"
            style="color: var(--semantic-text)"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 19l-7-7 7-7"
            />
          </svg>
        </button>
        <UiIcon :name="getFileIcon(fileName)" class="w-5 h-5" />
        <div class="flex items-center gap-2 min-w-0">
          <span
            class="text-body font-medium truncate"
            style="color: var(--semantic-text)"
            :title="filePath"
          >
            {{ fileName }}
          </span>
          <span
            class="text-dense px-2 py-0.5 rounded shrink-0"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim)"
            data-testid="code-editor-line-count"
          >
            {{ lineCount }} {{ lineCount === 1 ? 'line' : 'lines' }}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <!-- Language indicator -->
        <span
          class="text-dense px-2 py-1 rounded"
          style="background-color: var(--semantic-active-bg); color: var(--semantic-text-muted)"
          data-testid="code-editor-language"
        >
          {{ detectedLanguage }}
        </span>
      </div>
    </div>

    <!-- Lines: sticky number gutter on the left, token-colored content
         on the right. Soft-wrap is always on (same decision as the diff
         views), so a long line never pushes a horizontal scrollbar. -->
    <div
      ref="bodyEl"
      class="flex-1 min-h-0 overflow-auto code-body"
      data-testid="code-editor-body"
      :style="{
        fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
      }"
    >
      <div
        v-if="!hasContent"
        class="flex flex-col items-center justify-center h-full italic text-dense"
        style="color: var(--semantic-text-dim)"
        data-testid="code-editor-empty"
      >
        This file is empty
      </div>

      <table
        v-else
        class="w-full border-collapse"
        style="font-size: var(--text-dense); line-height: 20px"
      >
        <tbody>
          <tr
            v-for="(line, idx) in lines"
            :key="idx"
            class="code-row"
            :class="{ 'code-row-target': isTarget(idx + 1) }"
            data-testid="code-line"
            :data-line="idx + 1"
            :data-target="isTarget(idx + 1) ? 'true' : 'false'"
          >
            <td
              class="code-gutter px-2 text-right select-none align-top"
              style="color: var(--semantic-text-dim); user-select: none"
              data-testid="code-line-number"
            >
              {{ idx + 1 }}
            </td>
            <td class="code-content px-2 align-top" style="color: var(--semantic-text)">
              <span
                v-for="(token, tokenIdx) in tokensFor(line)"
                :key="tokenIdx"
                :class="`tok-${token.type}`"
                >{{ token.text || '\u00a0' }}</span
              >
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Footer with file path -->
    <div
      v-if="cwd || filePath"
      class="h-6 flex items-center px-3 shrink-0 text-dense truncate"
      style="
        background-color: var(--color-bg-m2);
        border-top: 1px solid var(--color-border);
        color: var(--semantic-text-dim);
      "
      :title="displayPath"
    >
      {{ displayPath }}
    </div>
  </div>
</template>

<style scoped>
.code-editor {
  background-color: var(--semantic-content-bg);
}

/* Soft-wrap is always on: long lines are the common case (minified
   blobs, wide tables) and were the reason the diff views dropped their
   Wrap toggle. `break-word` keeps the gutter aligned with its row. */
.code-body table {
  white-space: pre-wrap;
  word-break: break-word;
}

.code-gutter {
  width: 3.5rem;
  position: sticky;
  left: 0;
  background-color: var(--semantic-content-bg);
  border-right: 1px solid var(--color-border);
  z-index: 1;
}

.code-row:hover {
  background-color: rgba(255, 255, 255, 0.03);
}

/* The row reached from the diff review's "open at this line" / ?line=N. */
.code-row-target {
  background-color: rgba(139, 164, 176, 0.14);
}

.code-row-target .code-gutter {
  background-color: rgba(139, 164, 176, 0.14);
  border-right-color: var(--color-blue);
  color: var(--semantic-text);
}

/* Scrollbar styling — same as the diff viewers. */
.code-body::-webkit-scrollbar {
  width: 10px;
  height: 10px;
}

.code-body::-webkit-scrollbar-track {
  background: var(--color-bg-m2);
}

.code-body::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 5px;
}

.code-body::-webkit-scrollbar-thumb:hover {
  background: var(--color-gray-3);
}

/* Code token colors — the shared palette from the diff review
   (`tool_outputs/_shared/DiffView.vue`, `SidebarDiffView.vue`). Scoped
   here so the viewer matches the diff cards exactly. */
.tok-plain {
  color: inherit;
}
.tok-keyword {
  color: #8992a7;
  font-weight: 600;
}
.tok-string {
  color: #87a987;
}
.tok-comment {
  color: #7a8382;
  font-style: italic;
}
.tok-number {
  color: #c4b28a;
}
.tok-function {
  color: #8ea4a2;
}
.tok-type {
  color: #8ba4b0;
}
</style>

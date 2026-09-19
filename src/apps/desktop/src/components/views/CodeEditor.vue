<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch, shallowRef } from 'vue'
import { detectLanguage } from '@/helpers/codeHighlight'

// LAZY LOADED — DO NOT statically `import 'monaco-editor'`.
//
// Why this matters (Linux 99% CPU bug, task_1787683960703_0, 2026-08-25):
// Monaco Editor ships ~30 language worker bundles (TypeScript,
// JavaScript, JSON, CSS, HTML, Handlebars, Razor, Freemarker, Liquid,
// …) totaling ~96 MB across 64 cached blobs in the WebKitGTK disk
// cache. A static `import * as monaco from 'monaco-editor'` here
// forces Vite to ship the entire tree into the entry chunk. On
// WebKitGTK (Linux) the cached responses are re-parsed on every app
// start, pinning one CPU core at 80–100% for ~10–30 s. WKWebView
// (macOS) uses memory-mapped cache + a faster JS engine so the same
// workload is invisible. Dynamic `import()` defers the bundle load
// until the user actually opens a file in the editor — until then no
// monaco chunk is downloaded and nothing lands in the WebKitGTK
// cache.
//
// `monaco` is typed as `unknown` at script scope and narrowed inside
// onMounted after the dynamic import resolves. The test
// `CodeEditor.lazy-monaco.spec.ts` greps this file and fails the
// build if a future refactor re-introduces a top-level static import.

// Minimal structural type for the editor instance — we only need a
// few methods on it. Using `unknown` instead of `monaco.editor.IStandaloneCodeEditor`
// keeps the monaco-editor package out of this file's static module
// graph.
type EditorInstance = {
  getValue(): string
  setValue(v: string): void
  getOptions(): { get(id: unknown): unknown }
  getModel(): unknown
  updateOptions(opts: { readOnly?: boolean }): void
  revealLineInCenter(line: number): void
  setSelection(sel: {
    startLineNumber: number
    startColumn: number
    endLineNumber: number
    endColumn: number
  }): void
  focus(): void
  onDidChangeModelContent(cb: () => void): { dispose(): void }
  addCommand(keybind: number, cb: () => void): void
  dispose(): void
}

// Same for monaco's namespace API — only the methods/types we
// actually call. Kept narrow on purpose: if a future change needs a
// new monaco feature, add the typed surface here (NOT a top-level
// `import`).
//
// We type the loaded namespace as `unknown` (not as `MonacoNs`) so
// `vue-tsc` doesn't demand a structurally compatible shape from the
// real monaco-editor type definition — the dynamic import resolves
// to the real package types which are richer than our hand-written
// narrow surface. The cast happens once at the import site, all
// downstream uses go through the typed ref below.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type MonacoNs = any

// Configure Monaco's worker URL *once*. `self.MonacoEnvironment` is a
// global that Monaco reads at worker-spawn time — it doesn't need
// the monaco-editor package to be imported for this side effect to
// take effect. We register only the language workers we actually use
// (TS/JS/JSON/CSS/HTML/Markdown) so Vite's lazy import never pulls
// in the 30+ language parsers we don't render.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const g = globalThis as any
g.MonacoEnvironment = g.MonacoEnvironment || {}
// No eslint-disable needed here — the function body itself doesn't
// declare an `any` type (the cast is on `g` two lines above).
g.MonacoEnvironment.getWorker = function (_moduleId: string, label: string) {
  const getWorkerModule = (moduleUrl: string) => {
    return new Worker(g.MonacoEnvironment.getWorkerUrl(moduleUrl, label), {
      name: label,
      type: 'module',
    })
  }
  switch (label) {
    case 'json':
      return getWorkerModule('/monaco-editor/esm/vs/language/json/json.worker?worker')
    case 'css':
    case 'scss':
    case 'less':
      return getWorkerModule('/monaco-editor/esm/vs/language/css/css.worker?worker')
    case 'html':
      return getWorkerModule('/monaco-editor/esm/vs/language/html/html.worker?worker')
    case 'typescript':
    case 'javascript':
      return getWorkerModule('/monaco-editor/esm/vs/language/typescript/ts.worker?worker')
    case 'markdown':
      // Monaco ships markdown under the html worker; reuse it.
      return getWorkerModule('/monaco-editor/esm/vs/language/html/html.worker?worker')
    default:
      // Any other language (yaml, python, shell, zig, …) falls back
      // to the base editor worker — no syntax highlighting but no
      // extra 1–2 MB bundle download either.
      return getWorkerModule('/monaco-editor/esm/vs/editor/editor.worker?worker')
  }
}

const props = defineProps<{
  filePath: string
  fileName: string
  content?: string
  language?: string
  readonly?: boolean
  cwd?: string
  /**
   * Optional 1-based line number to scroll to once the editor mounts.
   * When undefined, the editor opens at the top.
   * Set from `OpenInCodeEditorOptions.line` so clicking a diff line number
   * opens the file already scrolled to that line.
   */
  line?: number
}>()

const emit = defineEmits<{
  close: []
  save: [content: string]
  'content-change': [content: string]
}>()

const editorContainer = ref<HTMLDivElement | null>(null)
const editor = shallowRef<EditorInstance | null>(null)
// Holds the loaded monaco namespace so the post-mount watchers and
// the read-only toggle button can call into it without re-importing
// or holding a static reference. `null` until onMounted resolves the
// dynamic import.
const monacoNs = shallowRef<MonacoNs | null>(null)
const isModified = ref(false)
const originalContent = ref(props.content || '')

// detectLanguage lives in @/helpers/codeHighlight (shared with DiffView).
// Get file icon for display
const getFileIcon = (fileName: string): string => {
  const ext = fileName.split('.').pop()?.toLowerCase() || ''
  const iconMap: Record<string, string> = {
    js: '📜',
    jsx: '⚛️',
    ts: '📘',
    tsx: '⚛️',
    vue: '💚',
    html: '🌐',
    htm: '🌐',
    css: '🎨',
    scss: '🎨',
    less: '🎨',
    json: '📋',
    md: '📝',
    markdown: '📝',
    xml: '📄',
    yaml: '⚙️',
    yml: '⚙️',
    py: '🐍',
    zig: '⚡',
    rs: '🦀',
    go: '🔵',
    txt: '📄',
    gitignore: '🔒',
    env: '🔐',
  }
  return iconMap[ext] || '📄'
}

const detectedLanguage = ref(props.language || detectLanguage(props.fileName))

onMounted(async () => {
  if (!editorContainer.value) return

  // LAZY LOAD — see the long comment block at the top of this file.
  // Until this line runs, no monaco-editor code has been downloaded.
  // WebKitGTK's disk cache stays empty of the 96 MB of language
  // worker bundles, so subsequent app starts don't re-parse them.
  //
  // `/* @vite-ignore */` tells Vite's optimizer not to analyse this
  // dynamic import. Without it, Vite sees the named-export usage
  // (`monaco.editor.create`, `monaco.editor.defineTheme`, etc.) and
  // hoists the resolved module into the entry chunk's static import
  // graph — exactly what we DON'T want. With the comment, the chunk
  // stays separate and is only fetched when the user actually opens
  // a file in the editor.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const monaco = (await import(/* @vite-ignore */ 'monaco-editor')) as any
  monacoNs.value = monaco

  // Configure editor theme to match Kanagawa Dragon theme
  monaco.editor.defineTheme('nalar-dark', {
    base: 'vs-dark',
    inherit: true,
    rules: [
      { token: 'comment', foreground: '7a8382', fontStyle: 'italic' },
      { token: 'keyword', foreground: '8992a7' },
      { token: 'string', foreground: '87a987' },
      { token: 'number', foreground: 'c4b28a' },
      { token: 'type', foreground: '8ba4b0' },
      { token: 'function', foreground: '8ea4a2' },
      { token: 'variable', foreground: 'c5c9c5' },
    ],
    colors: {
      'editor.background': '#181616',
      'editor.foreground': '#c5c9c5',
      'editor.lineHighlightBackground': '#1D1C19',
      'editorCursor.foreground': '#8ea4a2',
      'editor.selectionBackground': '#282727',
      'editorLineNumber.foreground': '#7a8382',
      'editorLineNumber.activeForeground': '#8992a7',
      'editor.inactiveSelectionBackground': '#282727',
      'editorIndentGuide.background': '#282727',
      'editorIndentGuide.activeBackground': '#393836',
      'editor.wordHighlightBackground': '#282727',
      'editor.wordHighlightStrongBackground': '#12120f',
      'editorBracketMatch.background': '#282727',
      'editorBracketMatch.border': '#8992a7',
      'scrollbar.shadow': '#12120f',
      'scrollbarSlider.background': '#28272780',
      'scrollbarSlider.hoverBackground': '#39383680',
      'scrollbarSlider.activeBackground': '#8992a780',
      'minimap.background': '#181616',
    },
  })

  const editorInstance = monaco.editor.create(editorContainer.value, {
    value: props.content || '',
    language: detectedLanguage.value,
    theme: 'nalar-dark',
    readOnly: props.readonly || false,
    automaticLayout: true,
    minimap: { enabled: true },
    fontSize: 13,
    fontFamily: "'Fira Code', 'Consolas', 'Monaco', monospace",
    fontLigatures: true,
    lineNumbers: 'on',
    renderLineHighlight: 'all',
    scrollBeyondLastLine: false,
    wordWrap: 'on',
    tabSize: 2,
    insertSpaces: true,
    cursorBlinking: 'smooth',
    cursorSmoothCaretAnimation: 'on',
    smoothScrolling: true,
    padding: { top: 8, bottom: 8 },
  })

  editor.value = editorInstance

  // If the caller passed a line number, scroll to it (centered) once the
  // editor is laid out. Monaco's `revealLineInCenter` handles both the
  // scroll position and a brief selection highlight so the user sees
  // exactly which line they jumped to from the diff.
  if (typeof props.line === 'number' && props.line > 0) {
    // Wait one tick so automaticLayout has produced real line heights.
    setTimeout(() => {
      editorInstance.revealLineInCenter(props.line!)
      editorInstance.setSelection({
        startLineNumber: props.line!,
        startColumn: 1,
        endLineNumber: props.line!,
        endColumn: 1,
      })
      editorInstance.focus()
    }, 0)
  }

  // Listen for content changes
  editorInstance.onDidChangeModelContent(() => {
    const newContent = editorInstance.getValue()
    isModified.value = newContent !== originalContent.value
    emit('content-change', newContent)
  })

  // Add keyboard shortcut for save
  editorInstance.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
    if (!props.readonly && isModified.value) {
      handleSave()
    }
  })
})

onUnmounted(() => {
  editor.value?.dispose()
})

// Watch for external content changes
watch(
  () => props.content,
  (newContent) => {
    if (editor.value && newContent !== editor.value.getValue()) {
      editor.value.setValue(newContent || '')
      originalContent.value = newContent || ''
      isModified.value = false
    }
  },
)

// Watch for language changes
watch(
  () => props.language,
  (newLanguage) => {
    if (editor.value && newLanguage && monacoNs.value) {
      const model = editor.value.getModel()
      if (model) {
        monacoNs.value.editor.setModelLanguage(model, newLanguage)
        detectedLanguage.value = newLanguage
      }
    }
  },
)

const handleClose = () => {
  emit('close')
}

const handleSave = () => {
  if (editor.value) {
    const content = editor.value.getValue()
    emit('save', content)
    originalContent.value = content
    isModified.value = false
  }
}

const handleReadOnlyToggle = () => {
  if (editor.value && monacoNs.value) {
    const options = editor.value.getOptions()
    const newReadonly = !options.get(monacoNs.value.editor.EditorOption.readOnly)
    editor.value.updateOptions({ readOnly: newReadonly })
  }
}
</script>

<template>
  <div class="code-editor-container flex flex-col h-full overflow-hidden">
    <!-- Header -->
    <div
      class="h-12 flex items-center justify-between px-4 shrink-0"
      style="background-color: var(--color-bg-m2); border-bottom: 1px solid var(--color-border)"
    >
      <div class="flex items-center gap-3">
        <button
          @click="handleClose"
          class="p-2 rounded-lg hover:opacity-70 transition-opacity"
          title="Close"
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
        <span class="text-lg">{{ getFileIcon(fileName) }}</span>
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium" style="color: var(--semantic-text)">
            {{ fileName }}
          </span>
          <span
            v-if="isModified"
            class="w-2 h-2 rounded-full"
            style="background-color: var(--color-orange)"
            title="Unsaved changes"
          />
          <span
            v-if="props.readonly"
            class="text-xs px-2 py-0.5 rounded"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim)"
          >
            READONLY
          </span>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <!-- Language indicator -->
        <span
          class="text-xs px-2 py-1 rounded"
          style="background-color: var(--semantic-active-bg); color: var(--semantic-text-muted)"
        >
          {{ detectedLanguage }}
        </span>

        <!-- Readonly toggle -->
        <button
          v-if="!isModified"
          @click="handleReadOnlyToggle"
          class="p-2 rounded-lg hover:opacity-70 transition-opacity"
          :title="props.readonly ? 'Enable editing' : 'Make readonly'"
        >
          <svg
            class="w-4 h-4"
            style="color: var(--semantic-text-dim)"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
            />
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
            />
          </svg>
        </button>

        <!-- Save button -->
        <button
          v-if="isModified && !props.readonly"
          @click="handleSave"
          class="px-3 py-1.5 rounded-lg text-sm font-medium transition-colors hover:opacity-90"
          style="background-color: var(--color-green); color: var(--color-bg)"
          title="Save (Ctrl+S)"
        >
          Save
        </button>

        <!-- Unsaved indicator -->
        <span
          v-if="isModified && !props.readonly"
          class="text-xs"
          style="color: var(--color-orange)"
        >
          Unsaved
        </span>
      </div>
    </div>

    <!-- Editor container -->
    <div ref="editorContainer" class="flex-1 overflow-hidden" />

    <!-- Footer with file path -->
    <div
      v-if="props.cwd || filePath"
      class="h-6 flex items-center px-3 shrink-0 text-xs truncate"
      style="
        background-color: var(--color-bg-m2);
        border-top: 1px solid var(--color-border);
        color: var(--semantic-text-dim);
      "
      :title="cwd ? `${cwd}/${filePath}` : filePath"
    >
      {{ cwd ? `${cwd}/${filePath}` : filePath }}
    </div>
  </div>
</template>

<style scoped>
.code-editor-container {
  background-color: var(--semantic-content-bg);
}

.code-editor-container :deep(.monaco-editor) {
  padding-top: 8px;
}

.code-editor-container :deep(.monaco-editor .margin) {
  background-color: var(--semantic-content-bg);
}

.code-editor-container :deep(.minimap) {
  background-color: var(--semantic-sidebar-bg) !important;
}
</style>

<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch, shallowRef } from 'vue'
import * as monaco from 'monaco-editor'

// Monaco Editor configuration for workers
self.MonacoEnvironment = self.MonacoEnvironment || {}
self.MonacoEnvironment.getWorker = function (_moduleId: string, label: string) {
  const getWorkerModule = (moduleUrl: string) => {
    return new Worker(self.MonacoEnvironment!.getWorkerUrl!(moduleUrl, label), {
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
      return getWorkerModule('/monaco-editor/esm/vs/language/css/css.worker?worer')
    case 'html':
    case 'handlebars':
    case 'razor':
      return getWorkerModule('/monaco-editor/esm/vs/language/html/html.worker?worker')
    case 'typescript':
    case 'javascript':
      return getWorkerModule('/monaco-editor/esm/vs/language/typescript/ts.worker?worker')
    default:
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
  'close': []
  'save': [content: string]
  'content-change': [content: string]
}>()

const editorContainer = ref<HTMLDivElement | null>(null)
const editor = shallowRef<monaco.editor.IStandaloneCodeEditor | null>(null)
const isModified = ref(false)
const originalContent = ref(props.content || '')

// Detect language from file extension
const detectLanguage = (fileName: string): string => {
  const ext = fileName.split('.').pop()?.toLowerCase() || ''
  const languageMap: Record<string, string> = {
    'js': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'vue': 'html',
    'html': 'html',
    'htm': 'html',
    'css': 'css',
    'scss': 'scss',
    'less': 'less',
    'json': 'json',
    'jsonc': 'json',
    'md': 'markdown',
    'markdown': 'markdown',
    'xml': 'xml',
    'yaml': 'yaml',
    'yml': 'yaml',
    'py': 'python',
    'python': 'python',
    'sh': 'shell',
    'bash': 'shell',
    'zsh': 'shell',
    'ps1': 'powershell',
    'psm1': 'powershell',
    'psd1': 'powershell',
    'powershell': 'powershell',
    'zig': 'zig',
    'rs': 'rust',
    'toml': 'ini',
    'ini': 'ini',
    'txt': 'plaintext',
    'log': 'plaintext',
    'gitignore': 'plaintext',
    'env': 'plaintext',
    'sql': 'sql',
    'graphql': 'graphql',
    'go': 'go',
    'java': 'java',
    'c': 'c',
    'cpp': 'cpp',
    'h': 'c',
    'hpp': 'cpp',
  }
  return languageMap[ext] || 'plaintext'
}

// Get file icon for display
const getFileIcon = (fileName: string): string => {
  const ext = fileName.split('.').pop()?.toLowerCase() || ''
  const iconMap: Record<string, string> = {
    'js': '📜',
    'jsx': '⚛️',
    'ts': '📘',
    'tsx': '⚛️',
    'vue': '💚',
    'html': '🌐',
    'htm': '🌐',
    'css': '🎨',
    'scss': '🎨',
    'less': '🎨',
    'json': '📋',
    'md': '📝',
    'markdown': '📝',
    'xml': '📄',
    'yaml': '⚙️',
    'yml': '⚙️',
    'py': '🐍',
    'zig': '⚡',
    'rs': '🦀',
    'go': '🔵',
    'txt': '📄',
    'gitignore': '🔒',
    'env': '🔐',
  }
  return iconMap[ext] || '📄'
}

const detectedLanguage = ref(props.language || detectLanguage(props.fileName))

onMounted(() => {
  if (!editorContainer.value) return

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
      editorInstance.revealLineInCenter(props.line!, 0)
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
watch(() => props.content, (newContent) => {
  if (editor.value && newContent !== editor.value.getValue()) {
    editor.value.setValue(newContent || '')
    originalContent.value = newContent || ''
    isModified.value = false
  }
})

// Watch for language changes
watch(() => props.language, (newLanguage) => {
  if (editor.value && newLanguage) {
    const model = editor.value.getModel()
    if (model) {
      monaco.editor.setModelLanguage(model, newLanguage)
      detectedLanguage.value = newLanguage
    }
  }
})

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
  if (editor.value) {
    const options = editor.value.getOptions()
    const newReadonly = !options.get(monaco.editor.EditorOption.readOnly)
    editor.value.updateOptions({ readOnly: newReadonly })
  }
}
</script>

<template>
  <div class="code-editor-container flex flex-col h-full overflow-hidden">
    <!-- Header -->
    <div
      class="h-12 flex items-center justify-between px-4 shrink-0"
      style="background-color: var(--color-bg-m2); border-bottom: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-3">
        <button
          @click="handleClose"
          class="p-2 rounded-lg hover:opacity-70 transition-opacity"
          title="Close"
        >
          <svg class="w-4 h-4" style="color: var(--semantic-text);" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
        </button>
        <span class="text-lg">{{ getFileIcon(fileName) }}</span>
        <div class="flex items-center gap-2">
          <span class="text-sm font-medium" style="color: var(--semantic-text);">
            {{ fileName }}
          </span>
          <span
            v-if="isModified"
            class="w-2 h-2 rounded-full"
            style="background-color: var(--color-orange);"
            title="Unsaved changes"
          />
          <span
            v-if="props.readonly"
            class="text-xs px-2 py-0.5 rounded"
            style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim);"
          >
            READONLY
          </span>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <!-- Language indicator -->
        <span
          class="text-xs px-2 py-1 rounded"
          style="background-color: var(--semantic-active-bg); color: var(--semantic-text-muted);"
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
          <svg class="w-4 h-4" style="color: var(--semantic-text-dim);" fill="none" viewBox="0 0 24 24" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
          </svg>
        </button>

        <!-- Save button -->
        <button
          v-if="isModified && !props.readonly"
          @click="handleSave"
          class="px-3 py-1.5 rounded-lg text-sm font-medium transition-colors hover:opacity-90"
          style="background-color: var(--color-green); color: var(--color-bg);"
          title="Save (Ctrl+S)"
        >
          Save
        </button>

        <!-- Unsaved indicator -->
        <span
          v-if="isModified && !props.readonly"
          class="text-xs"
          style="color: var(--color-orange);"
        >
          Unsaved
        </span>
      </div>
    </div>

    <!-- Editor container -->
    <div
      ref="editorContainer"
      class="flex-1 overflow-hidden"
    />

    <!-- Footer with file path -->
    <div
      v-if="props.cwd || filePath"
      class="h-6 flex items-center px-3 shrink-0 text-xs truncate"
      style="background-color: var(--color-bg-m2); border-top: 1px solid var(--color-border); color: var(--semantic-text-dim);"
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

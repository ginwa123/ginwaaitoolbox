<!--
  KanbanDescriptionEditor — Markdown-aware description editor for kanban
  tasks. Extracted from KanbanTaskDetailDialog's inline <textarea> block
  so the dialog can swap between this component (edit mode) and
  <MarkdownDescription> (display mode) without re-rendering the form.

  Features (mirrored from FileInput.vue patterns where applicable):
    - Markdown text v-model on the textarea.
    - Image paste (Ctrl/Cmd+V) with cross-browser fallback for WebKitGTK
      (uses the same clipboardData.items + navigator.clipboard.read
      strategy as FileInput.vue).
    - Paperclip button → hidden <input type="file" accept="image/*"
      multiple>.
    - @-trigger file picker that fetches via /api/system/folder
      recursive scan and inserts `@/path` at the cursor.

  Storage format:
    The modelValue is a Markdown string. Pasted/picked images are
    encoded as `![filename](data:image/<ext>;base64,<payload>)` directly
    in the markdown — self-contained, no upload endpoint, no image
    table. Downscales images larger than MAX_IMAGE_BYTES via <canvas>.

  Cap strategy:
    Text length is bounded by props.maxLength (default 5000). Image
    size is bounded per-image by MAX_IMAGE_BYTES (4 MB). Total
    description (text + data URLs) is NOT capped here — the DB TEXT
    column accepts multi-MB; the text cap protects the form's UX
    (char counter is text-only).

  Create mode (taskId=''):
    The dialog opens this editor with taskId='' before the task
    exists on the server. Pasted/picked images are STAGED in
    `previewFiles` (visual) and `pendingFiles` (data, exposed via
    defineExpose). The textarea is NOT modified — we never write
    `data:image/png;base64,…` into the description, which would
    blow past the 5000-char cap and store multi-MB base64 in the
    DB TEXT column. After the task is created, the dialog's host
    reads `pendingFiles`, uploads each via `api.uploadTaskAttachment`,
    and patches the description with `![name](<url>)` markdown.
    See docs/superpowers/plans/2026-08-06-kanban-no-base64-in-desc.md.
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick, onMounted } from 'vue'
import FilePreview, { type PreviewFile } from '../file/FilePreview.vue'
import * as api from '../../api'

interface FileEntry {
  name: string
  path: string
  isDirectory: boolean
}

const props = withDefaults(
  defineProps<{
    modelValue: string
    cwd: string
    // Required for image upload. The kanban task id is used as the
    // upload bucket — files land in
    // `<item.path>/.nalar/attachments/<taskId>/<n>.<ext>`.
    // Empty string disables image upload (the editor still works for
    // text + @path references).
    taskId?: string
    maxLength?: number
    placeholder?: string
    testId?: string
  }>(),
  {
    taskId: '',
    maxLength: 5000,
    placeholder: 'Add a description…',
    testId: 'kanban-description-editor',
  },
)

const emit = defineEmits<{
  'update:modelValue': [value: string]
}>()

// ─── State ──────────────────────────────────────────────────────────────

const text = ref(props.modelValue)
const previewFiles = ref<PreviewFile[]>([])
// Files staged in CREATE mode (taskId='') — uploaded by the host AFTER
// the task exists. Mirrors previewFiles but exists only for the
// create-mode flow; in edit mode it stays empty because uploads happen
// inline (see addImageFile). Exposed via defineExpose so the parent
// dialog can hand it to the host's create-then-upload orchestrator.
const pendingFiles = ref<PreviewFile[]>([])
const showFilePicker = ref(false)
const fileQuery = ref('')
const fileList = ref<FileEntry[]>([])
const isLoadingFiles = ref(false)
const selectedFileIndex = ref(0)
const fileDebounceTimer: { value: ReturnType<typeof setTimeout> | null } = { value: null }
const textareaRef = ref<HTMLTextAreaElement | null>(null)
const nativeFileInput = ref<HTMLInputElement | null>(null)

// Caps
const MAX_IMAGE_BYTES = 4 * 1024 * 1024

// Mirror the prop into a local ref so the textarea is editable.
watch(
  () => props.modelValue,
  (v) => {
    if (v !== text.value) text.value = v
  },
)

// Emit on every text edit.
watch(text, (v) => {
  emit('update:modelValue', v)
})

const counterText = computed<string>(() => `${text.value.length} / ${props.maxLength}`)

// ─── @-trigger file picker ──────────────────────────────────────────────
// Pattern is mirrored from FileInput.vue — recursive scan via
// /system/folder?action=list, debounced 150ms after typing.

const detectAtTrigger = () => {
  if (!textareaRef.value) return
  const pos = textareaRef.value.selectionStart ?? 0
  const textBeforeCursor = text.value.slice(0, pos)
  const atMatch = textBeforeCursor.match(/@([\w./\\:-]*)$/)
  if (atMatch) {
    fileQuery.value = atMatch[1] ?? ''
    if (!showFilePicker.value) {
      showFilePicker.value = true
      selectedFileIndex.value = 0
      loadAllFiles(props.cwd)
    }
  } else {
    showFilePicker.value = false
    fileQuery.value = ''
  }
}

const loadAllFiles = async (rootPath: string) => {
  if (!rootPath) return
  isLoadingFiles.value = true
  fileList.value = []

  const results: FileEntry[] = []
  const scanDir = async (dirPath: string) => {
    try {
      const response = await fetch(
        `${api.API_BASE}/system/folder?path=${encodeURIComponent(dirPath)}&action=list`,
      )
      if (!response.ok) return
      const data = (await response.json()) as { entries?: FileEntry[] }
      const entries = data.entries ?? []
      for (const entry of entries) {
        if (entry.name.startsWith('.')) continue
        const relativePath = entry.path.replace(rootPath, '')
        results.push({
          name: entry.name,
          path: relativePath,
          isDirectory: entry.isDirectory,
        })
        if (entry.isDirectory) {
          await scanDir(entry.path)
        }
      }
    } catch (err) {
      console.error('Failed to scan:', dirPath, err)
    }
  }

  try {
    await scanDir(rootPath)
    results.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1
      return a.path.localeCompare(b.path)
    })
    fileList.value = results
  } finally {
    isLoadingFiles.value = false
  }
}

const filteredFiles = computed<FileEntry[]>(() => {
  if (!fileQuery.value) return fileList.value
  const q = fileQuery.value.toLowerCase()
  // Out-of-order char match (FileInput pattern): "comp" matches
  // "components" because all chars appear in order, not contiguously.
  const matchesOutOfOrder = (path: string, query: string): boolean => {
    const lowerPath = path.toLowerCase()
    let pathIdx = 0
    let queryIdx = 0
    while (queryIdx < query.length && pathIdx < lowerPath.length) {
      if (lowerPath[pathIdx] === query[queryIdx]) queryIdx++
      pathIdx++
    }
    return queryIdx === query.length
  }
  return fileList.value.filter((f) => matchesOutOfOrder(f.path, q))
})

const selectFile = (file: FileEntry) => {
  if (!textareaRef.value) return
  const pos = textareaRef.value.selectionStart ?? 0
  const before = text.value.slice(0, pos)
  const after = text.value.slice(pos)
  // Strip the `@` trigger token but keep the file path verbatim
  // (e.g. `/src/main.zig` inserts as-is — no `@` prefix). The path
  // chip detector in <MarkdownDescription> matches `/path/to/file`
  // directly, so a leading `@` is unnecessary noise.
  const atMatch = before.match(/@([\w./\\:-]*)$/)
  const insertText = file.path
  if (atMatch && atMatch.index !== undefined) {
    text.value = before.slice(0, atMatch.index) + insertText + after
  } else {
    text.value = before + insertText + after
  }
  showFilePicker.value = false
  fileQuery.value = ''
  nextTick(() => {
    if (!textareaRef.value) return
    const newPos = (atMatch?.index ?? before.length) + insertText.length
    textareaRef.value.setSelectionRange(newPos, newPos)
    textareaRef.value.focus()
  })
}

const handleTextareaInput = () => {
  if (fileDebounceTimer.value) clearTimeout(fileDebounceTimer.value)
  fileDebounceTimer.value = setTimeout(detectAtTrigger, 150)
}

const onTextareaInput = (event: Event) => {
  const target = event.target as HTMLTextAreaElement
  text.value = target.value
  handleTextareaInput()
  autoResize(event)
}

// ─── Image paste (mirrors FileInput.vue strategy 1 + 2) ────────────────

const isImageFile = (file: File): boolean => file.type.startsWith('image/')

const fileToDataUrl = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = reject
    reader.readAsDataURL(file)
  })

const downscaleIfTooLarge = async (file: File): Promise<File> => {
  if (file.size <= MAX_IMAGE_BYTES) return file
  // Downscale via canvas to ~max 1920px wide while keeping aspect ratio.
  const dataUrl = await fileToDataUrl(file)
  const img = await new Promise<HTMLImageElement>((resolve, reject) => {
    const i = new Image()
    i.onload = () => resolve(i)
    i.onerror = reject
    i.src = dataUrl
  })
  const maxWidth = 1920
  const scale = Math.min(1, maxWidth / img.width)
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(img.width * scale)
  canvas.height = Math.round(img.height * scale)
  const ctx = canvas.getContext('2d')
  if (!ctx) return file
  ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
  const out = canvas.toDataURL('image/jpeg', 0.85)
  // Convert data URL back to a File object so PreviewFile's previewUrl
  // stays a blob: URL (preview thumbnail), separate from the markdown
  // payload (data: URL).
  const blob = await (await fetch(out)).blob()
  return new File([blob], file.name.replace(/\.[^.]+$/, '.jpg'), {
    type: 'image/jpeg',
  })
}

const addImageFile = async (file: File) => {
  if (!isImageFile(file)) return
  const downscaled = await downscaleIfTooLarge(file)

  // Show a preview slot so the user sees the image they just pasted.
  // The blob URL is cheap and revoked on preview-removal (see
  // handlePreviewUpdate).
  const previewUrl = URL.createObjectURL(downscaled)
  const previewEntry: PreviewFile = { file: downscaled, previewUrl }
  previewFiles.value.push(previewEntry)

  if (!props.taskId) {
    // CREATE MODE — the task doesn't exist on the server yet, so
    // there's no taskId to upload to. We MUST NOT inject the base64
    // payload into the description text:
    //   - It would blow past the 5000-char text cap (a 4 MB image
    //     base64-encodes to ~5.5 MB).
    //   - It would store multi-MB raw base64 in the DB TEXT column,
    //     which then propagates into the chat view's render of the
    //     task description (see the bug screenshot — 487 052/5000).
    //
    // Instead, stage the file in `pendingFiles` (exposed via
    // defineExpose). The dialog's host (KanbanView.handleCreateTaskSave)
    // reads pendingFiles after `addTask` returns the new taskId,
    // uploads each via `api.uploadTaskAttachment(taskId, file)`, then
    // patches the description with `![name](<url>)` markdown.
    pendingFiles.value.push(previewEntry)
    return
  }

  // EDIT MODE — upload immediately. Inline `![name](<url>)` is
  // inserted into the description text so the user sees the image
  // right away and can save with one click.
  const uploadingIdx = previewFiles.value.length - 1
  try {
    const { url } = await api.uploadTaskAttachment(props.taskId, downscaled)
    insertMarkdown(`![${downscaled.name}](${url})`)
  } catch (err) {
    console.error('[attachment] upload failed:', err)
    // Roll back the preview thumbnail on failure so the user knows
    // the upload didn't go through. Keep the user's text intact.
    previewFiles.value.splice(uploadingIdx, 1)
    if (previewUrl.startsWith('blob:')) URL.revokeObjectURL(previewUrl)
  }
}

const insertMarkdown = (insertText: string) => {
  if (textareaRef.value) {
    const pos = textareaRef.value.selectionStart ?? text.value.length
    text.value = text.value.slice(0, pos) + insertText + text.value.slice(pos)
    nextTick(() => {
      if (!textareaRef.value) return
      const newPos = pos + insertText.length
      textareaRef.value.setSelectionRange(newPos, newPos)
      textareaRef.value.focus()
    })
  } else {
    text.value += insertText
  }
}

const handlePaste = async (event: ClipboardEvent) => {
  const items = event.clipboardData?.items
  let pastedImageCount = 0
  if (items && items.length > 0) {
    for (const item of items) {
      if (item.kind !== 'file') continue
      if (!item.type.startsWith('image/')) continue
      const file = item.getAsFile()
      if (!file) continue
      const renamed = file.name
        ? file
        : new File(
            [file],
            `pasted-image-${Date.now()}.${item.type.split('/')[1] ?? 'png'}`,
            { type: item.type },
          )
      await addImageFile(renamed)
      pastedImageCount++
    }
  }
  // WebKitGTK fallback — sync path often yields 0 files for image paste.
  if (pastedImageCount === 0 && navigator.clipboard?.read) {
    try {
      const clipboardItems = await navigator.clipboard.read()
      for (const ci of clipboardItems) {
        for (const type of ci.types) {
          if (!type.startsWith('image/')) continue
          const blob = await ci.getType(type)
          const file = new File(
            [blob],
            `pasted-image-${Date.now()}.${type.split('/')[1] ?? 'png'}`,
            { type },
          )
          await addImageFile(file)
          pastedImageCount++
        }
      }
    } catch (err) {
      console.debug('[paste] clipboard.read fallback skipped:', err)
    }
  }
  if (pastedImageCount > 0) event.preventDefault()
}

// ─── Native file picker (paperclip) ────────────────────────────────────

const triggerFilePicker = () => {
  nativeFileInput.value?.click()
}

const handleNativeFileSelect = async (event: Event) => {
  const target = event.target as HTMLInputElement
  const files = target.files
  if (!files || files.length === 0) return
  for (const file of Array.from(files)) {
    if (!file) continue
    if (!isImageFile(file)) continue
    await addImageFile(file)
  }
  target.value = ''
}

// ─── Preview removal — strips the matching data URL from the markdown ──

const handlePreviewUpdate = (newFiles: PreviewFile[]) => {
  // Find removed files (in old but not in new).
  const removed = previewFiles.value.filter((old) => !newFiles.includes(old))
  if (removed.length === 0) {
    previewFiles.value = newFiles
    return
  }
  for (const r of removed) {
    if (r.previewUrl.startsWith('blob:')) URL.revokeObjectURL(r.previewUrl)
    // In edit mode the description carries an `![name](<url>)` block
    // we need to strip — same logic as before. In create mode the
    // description never received a markdown block (the file is only
    // in previewFiles/pendingFiles), so the regex find/replace is a
    // safe no-op (nothing matches).
    const fileName = r.file.name
    const escapedName = fileName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const blockRegex = new RegExp(`!\\[${escapedName}\\]\\([^)]+\\)`, 'g')
    text.value = text.value.replace(blockRegex, '').replace(/[ \t]+(\n|$)/g, '$1')
    // Drop the corresponding entry from pendingFiles (create mode).
    // The user's intent on removing a preview is "don't upload this
    // either" — otherwise the host would silently upload a file the
    // user already discarded.
    const pendingIdx = pendingFiles.value.findIndex((p) => p.previewUrl === r.previewUrl)
    if (pendingIdx !== -1) pendingFiles.value.splice(pendingIdx, 1)
  }
  previewFiles.value = newFiles
}

// ─── Mount: re-hydrate previewFiles from existing modelValue ───────────

const ATTACHMENT_URL_PREFIX = '/api/workspaces/tasks/'

// Decode a `data:<mime>;base64,<payload>` URL into a File. Avoids
// `fetch(dataUrl)` because jsdom does not implement data: URL fetch.
const dataUrlToFile = (dataUrl: string, name: string): File => {
  const [meta, base64] = dataUrl.split(',')
  const mimeMatch = meta?.match(/data:([^;]+)/)
  const mime = mimeMatch ? mimeMatch[1]! : 'image/png'
  const binary = atob(base64 ?? '')
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  const ext = mime.split('/')[1] ?? 'png'
  return new File([bytes], name || `pasted-image-${Date.now()}.${ext}`, { type: mime })
}

// Fetch a server-side attachment and convert it to a File for the
// preview thumbnail. Uses fetch() which jsdom supports (unlike
// data: URLs).
const serverUrlToFile = async (
  url: string,
  filename: string,
): Promise<File | null> => {
  try {
    const response = await fetch(url)
    if (!response.ok) return null
    const blob = await response.blob()
    // Detect MIME from the response (or fall back to extension guess).
    const mime = blob.type || guessMimeFromFilename(filename)
    return new File([blob], filename, { type: mime })
  } catch {
    return null
  }
}

const guessMimeFromFilename = (filename: string): string => {
  const dot = filename.lastIndexOf('.')
  const ext = dot >= 0 ? filename.slice(dot + 1).toLowerCase() : ''
  if (ext === 'png') return 'image/png'
  if (ext === 'jpg' || ext === 'jpeg') return 'image/jpeg'
  if (ext === 'gif') return 'image/gif'
  if (ext === 'webp') return 'image/webp'
  if (ext === 'svg') return 'image/svg+xml'
  if (ext === 'bmp') return 'image/bmp'
  return 'application/octet-stream'
}

const rehydratePreviews = () => {
  // Match both inline data: URLs (legacy / fallback) and server-side
  // attachment URLs.
  const imageRegex = /!\[([^\]]*)\]\((data:image\/[^)]+|[^)]+\.(?:png|jpg|jpeg|gif|webp|svg|bmp))\)/g
  const matches = [...text.value.matchAll(imageRegex)]
  if (matches.length === 0) return
  for (const m of matches) {
    const alt = m[1] ?? ''
    const url = m[2] ?? ''
    if (url.startsWith('data:')) {
      try {
        const file = dataUrlToFile(url, alt)
        const previewUrl = URL.createObjectURL(file)
        previewFiles.value.push({ file, previewUrl })
      } catch (err) {
        console.warn('[rehydrate] failed to load inline image', err)
      }
    } else {
      // Server-side attachment — fetch async, push when ready.
      void (async () => {
        const filename = url.split('/').pop() ?? 'attachment'
        const file = await serverUrlToFile(url, filename)
        if (!file) return
        const previewUrl = URL.createObjectURL(file)
        previewFiles.value.push({ file, previewUrl })
      })()
    }
  }
}

onMounted(() => {
  // Only rehydrate if there's existing image content (i.e. editing an
  // existing task). For empty modelValue the for-loop above is a no-op.
  rehydratePreviews()
})

// ─── Watch modelValue for external image changes (e.g. dialog re-open) ──
// We only re-hydrate when the modelValue grows (new image added externally).
let lastSeenText = props.modelValue
watch(
  () => props.modelValue,
  (v) => {
    if (v === lastSeenText) return
    lastSeenText = v
    // Only re-hydrate when the new value contains image references
    // (inline data: OR server-side attachment URLs) and the preview
    // list is currently empty (avoids duplicate previews).
    if (previewFiles.value.length === 0 && /!\[.*?\]\(((data:image\/|\/api\/))/.test(v)) {
      rehydratePreviews()
    }
  },
)

// ─── Watch modelValue for external image changes (e.g. dialog re-open) ──
// We only re-hydrate when the modelValue grows (new image added externally).
// (lastSeenText + the two watches are declared at the top of the file
// to avoid duplicate declarations; this comment is a marker for the
// second half of the lifecycle logic.)
watch(text, (v) => {
  lastSeenText = v
})

const autoResize = (event: Event) => {
  const target = event.target as HTMLTextAreaElement
  target.style.height = 'auto'
  target.style.height = `${Math.min(target.scrollHeight, 400)}px`
}

// Expose `pendingFiles` to the parent dialog so it can pass the staged
// files up to the host's create-then-upload orchestrator. Vue auto-unwraps
// refs in defineExpose, so `wrapper.vm.pendingFiles` returns the raw
// array (not a Ref). See KanbanDescriptionEditor.spec.ts for the
// pendingFiles contract (5 tests).
defineExpose({ pendingFiles })
</script>

<template>
  <div :data-testid="testId">
    <!-- File picker dropdown (above the textarea) -->
    <div
      v-if="showFilePicker && (filteredFiles.length > 0 || isLoadingFiles)"
      class="file-picker-list mb-2 p-2 rounded-lg shadow-lg max-h-72 overflow-y-auto"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
    >
      <div v-if="isLoadingFiles" class="p-4 text-center">
        <div
          class="w-6 h-6 border-2 rounded-full animate-spin mx-auto mb-2"
          style="border-color: var(--color-violet); border-top-color: transparent;"
        />
        <p class="text-sm" style="color: var(--semantic-text-dim)">Scanning files…</p>
        <p class="text-xs mt-1" style="color: var(--semantic-text-dim)">
          {{ fileList.length }} found
        </p>
      </div>
      <div
        v-else-if="filteredFiles.length === 0"
        class="p-2 text-sm"
        style="color: var(--semantic-text-dim)"
      >
        No files found
      </div>
      <div v-else>
        <button
          v-for="(file, idx) in filteredFiles"
          :key="file.path"
          type="button"
          class="w-full text-left px-3 py-1.5 rounded text-sm flex items-center gap-2 transition-colors"
          :class="idx === selectedFileIndex ? 'file-item-selected' : ''"
          :style="
            idx === selectedFileIndex
              ? 'background-color: var(--color-violet); color: var(--color-bg);'
              : 'color: var(--semantic-text);'
          "
          @click="selectFile(file)"
          @mouseenter="selectedFileIndex = idx"
        >
          <span>{{ file.isDirectory ? '📁' : '📄' }}</span>
          <span class="truncate font-mono text-xs">{{ file.path }}</span>
        </button>
      </div>
    </div>

    <!-- Image preview list -->
    <FilePreview
      :model-value="previewFiles"
      max-height="120px"
      @update:model-value="handlePreviewUpdate"
    />

    <!-- Textarea + paperclip -->
    <div class="flex gap-2 items-end">
      <textarea
        ref="textareaRef"
        :value="text"
        :placeholder="placeholder"
        :maxlength="maxLength"
        :data-testid="testId"
        rows="6"
        class="flex-1 px-3 py-2.5 rounded-lg text-sm outline-none transition-all duration-200 resize-y"
        style="
          background-color: var(--semantic-sidebar-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
          font-family: inherit;
          min-height: 160px;
        "
        @input="onTextareaInput"
        @paste="handlePaste"
      />
      <button
        type="button"
        :data-testid="`${testId}-paperclip`"
        @click="triggerFilePicker"
        class="shrink-0 w-10 h-10 rounded-lg flex items-center justify-center transition-colors"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        title="Attach image"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.586a6 6 0 108.486 8.486L20.5 13"
          />
        </svg>
      </button>
    </div>

    <!-- Hidden native file input -->
    <input
      ref="nativeFileInput"
      type="file"
      accept="image/*"
      multiple
      class="hidden"
      @change="handleNativeFileSelect"
    />

    <!-- Char counter -->
    <div
      class="text-[10px] mt-1 text-right"
      :data-testid="`${testId}-counter`"
      style="color: var(--semantic-text-dim)"
    >
      {{ counterText }}
    </div>
  </div>
</template>

<style scoped>
.file-item-selected {
  /* Hover state styling */
}
</style>
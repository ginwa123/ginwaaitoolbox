<script setup lang="ts">
import { ref, watch, nextTick, computed, onMounted, onBeforeUnmount } from 'vue'
import * as api from '../../api'
import { getActivePinia } from 'pinia'
import { useTabsStore } from '../../stores/tabs'
import FilePreview from './FilePreview.vue'
import { parseBackgroundCommandOutput } from '@/helpers/isBackgroundCommandOutput'

export interface QueuedMessage {
  id: string
  message: string
}

export interface PreviewFile {
  file: File
  previewUrl: string
}

const props = defineProps<{
  cwd: string
  queuedMessages?: QueuedMessage[]
  isLoading?: boolean
  isLLMProcessing?: boolean
  initialMessage?: string
  reviewMode?: boolean
  /**
   * True while the parent is waiting for the stop-session API call to
   * resolve. Drives the Stop button's spinner state + click-debounce.
   * The parent (ChatView) sets this to `true` immediately on click
   * and resets it to `false` when the LLM is no longer processing
   * (driven by the SSE `worker deleted` event).
   */
  isStopping?: boolean
  /**
   * Optional draft bucket. When set, typed-but-unsent text survives this
   * component being remounted — and remounting is exactly what every tab
   * switch does (AppLayout keys each view by the active tab), so without a
   * bucket the text would silently vanish. Parents that pass no `draftKey`
   * (GitFileViewer) read and write nothing.
   */
  draftKey?: string
  /**
   * True while the parent view is still running its initial load
   * (ChatView's `isInitializing`: session id unassigned or first history
   * fetch outstanding). Disables the textarea + send button so the user
   * can't submit against an unloaded session. Independent from
   * `isLoading` (which also covers in-flight sends and flips the label
   * to "Queue").
   */
  isInitializing?: boolean
}>()

const emit = defineEmits<{
  submit: [message: string, files?: File[]]
  /**
   * Emitted when the user clicks the Stop button. Parent
   * (ChatView) calls api.stopSession(sessionId) — the API call
   * lives at the parent layer because the input is shared across
   * multiple chat views and the stop semantics are tied to the
   * chat's sessionId, not the input box. The parent should also
   * pass `:isStopping="true"` back via prop to show the spinner.
   */
  'stop-session': []
}>()

interface FileEntry {
  name: string
  path: string
  isDirectory: boolean
}

const inputText = ref('')
const cursorPos = ref(0)
const showFilePicker = ref(false)
const fileQuery = ref('')
const fileList = ref<FileEntry[]>([])
const isLoadingFiles = ref(false)
const selectedFileIndex = ref(0)
const filePickerRef = ref<HTMLElement | null>(null)
let fileDebounceTimer: ReturnType<typeof setTimeout> | null = null

// File input ref for native file selection
const nativeFileInput = ref<HTMLInputElement | null>(null)

// Textarea ref for the document-level paste handler to scope intercepts
// to our textarea only — so we don't swallow paste events from sibling
// inputs (other chat tabs, search fields, etc.).
const chatTextareaRef = ref<HTMLTextAreaElement | null>(null)

// ── Draft survival across remounts (tab switches) ─────────────────────
// Every tab switch remounts this component, so the text in the box would
// otherwise be lost. The bucket lives in the tabs store (in memory, per
// window) and is keyed by the chat session, so closing and reopening a tab
// within the session still finds the draft.
const draftKey = computed(() => props.draftKey ?? '')

function draftBucket(): ReturnType<typeof useTabsStore> | null {
  if (!draftKey.value) return null
  // FileInput is also mounted outside any app (unit tests, GitFileViewer)
  // where there is no active pinia — drafts are simply unavailable there.
  if (!getActivePinia()) return null
  return useTabsStore()
}

let draftTimer: ReturnType<typeof setTimeout> | null = null

function flushDraft(): void {
  if (draftTimer) {
    clearTimeout(draftTimer)
    draftTimer = null
  }
  const bucket = draftBucket()
  if (bucket) bucket.setDraft(draftKey.value, inputText.value)
}

watch(inputText, (value) => {
  if (!draftKey.value) return
  if (draftTimer) clearTimeout(draftTimer)
  draftTimer = setTimeout(() => {
    draftTimer = null
    draftBucket()?.setDraft(draftKey.value, value)
  }, 200)
})

// ── Autofocus on session switch ───────────────────────────────────────
// Clicking a chat session remounts ChatView (AppLayout `:key="activeChatId"`)
// which remounts this input. Auto-focus the textarea so the user can type
// immediately with no second mouse click. Guards: never steal focus from
// an open modal dialog or a background tab.
const focusInput = () => {
  const el = chatTextareaRef.value
  if (!el || el.disabled) return
  if (typeof document !== 'undefined') {
    if (document.hidden) return
    if (document.querySelector('[role="dialog"], .modal-open')) return
  }
  el.focus({ preventScroll: true })
}
defineExpose({ focusInput })

// Pre-fill input when initialMessage is provided (after inputText is declared)
if (props.initialMessage) {
  inputText.value = props.initialMessage
}

// Image preview state
const previewFiles = ref<PreviewFile[]>([])

// ── Stop button state ─────────────────────────────────────────────────────
//
// `isStopping` is the parent's claim about whether a stop request is in
// flight. We watch `isLLMProcessing` and reset to false when the LLM
// stops — covers the fast path (SSE `worker deleted` arrives before the
// API round-trip) and the slow path (backend processes cancel before
// SSE). Without this reset, the spinner could stay stuck on after the
// SSE event hid the button, then re-appear the next time the agent
// runs.
const isStopping = ref(props.isStopping ?? false)
watch(
  () => props.isStopping,
  (v) => {
    isStopping.value = v ?? false
  },
)
watch(
  () => props.isLLMProcessing,
  (isProcessing) => {
    if (!isProcessing) isStopping.value = false
  },
)

const handleStopClick = () => {
  // Debounce: while a stop is already in flight, ignore subsequent
  // clicks. The button is also `:disabled` while `isStopping`, so
  // this is a defensive check for the case where the prop hasn't
  // propagated yet (same render frame as the click).
  if (isStopping.value) return
  isStopping.value = true
  emit('stop-session')
}

const isImageFile = (file: File): boolean => {
  return file.type.startsWith('image/')
}

const isVideoFile = (file: File): boolean => {
  return file.type.startsWith('video/')
}

const isMediaFile = (file: File): boolean => {
  return isImageFile(file) || isVideoFile(file)
}

// 25 MB client cap for video (mirrors MAX_VIDEO_URLS_BYTES server-side).
const MAX_VIDEO_BYTES = 25 * 1024 * 1024

// Send message with files converted to base64
const sendMessageWithFiles = async () => {
  if (!inputText.value.trim() && previewFiles.value.length === 0) return

  const message = inputText.value
  const files = previewFiles.value.map((p) => p.file)

  // Clear state before emit so parent can process
  inputText.value = ''
  if (draftTimer) {
    clearTimeout(draftTimer)
    draftTimer = null
  }
  // The text is gone from the box AND from the draft bucket — a sent
  // message must never come back as a draft.
  draftBucket()?.clearDraft(draftKey.value)
  showFilePicker.value = false
  previewFiles.value.forEach((item) => {
    if (item.previewUrl.startsWith('blob:')) {
      URL.revokeObjectURL(item.previewUrl)
    }
  })
  previewFiles.value = []

  emit('submit', message, files)

  nextTick(() => {
    const textarea = document.querySelector('.file-input-wrapper textarea') as HTMLTextAreaElement
    if (textarea) textarea.style.height = '48px'
  })
}

// Watch for changes to initialMessage (e.g., when selecting diff lines)
watch(
  () => props.initialMessage,
  (newVal) => {
    if (newVal) {
      inputText.value = newVal
    }
  },
)

// Trigger native file picker
const triggerFilePicker = () => {
  nativeFileInput.value?.click()
}

// Add a single image or video file to the preview list (shared by paperclip + paste flows)
const addImageFile = (file: File) => {
  if (!isMediaFile(file)) return
  if (isVideoFile(file) && file.size > MAX_VIDEO_BYTES) return
  const previewUrl = URL.createObjectURL(file)
  previewFiles.value.push({ file, previewUrl })
}

// Handle native file selection
const handleNativeFileSelect = (event: Event) => {
  const target = event.target as HTMLInputElement
  const files = target.files
  if (!files || files.length === 0) return

  for (const file of files) {
    if (!file) continue
    addImageFile(file)
  }

  // Reset the input so same files can be selected again
  target.value = ''
}

// Handle paste event — attach pasted images as file attachments (Ctrl/Cmd+V).
//
// Chromium / Firefox: `e.clipboardData.items` natively contains file items,
// so the standard sync loop below is enough.
//
// WebKitGTK (and WKWebView on some macOS releases): even with
// `javascript_can_access_clipboard=true`, the `<textarea>` paste event
// filters out non-text items from `clipboardData.items`. The paste event
// still fires with `clipboardData` present but `items` and `files` empty,
// so the loop below silently no-ops and the screenshot the user pasted
// vanishes. nalar-desktop uses WebKitGTK on Linux, which is why the same
// `FileInput` code works in `bun dev` (Chrome) but not in
// `nalar-desktop` (WebKitGTK).
//
// The fix: after the sync `clipboardData.items` loop, if no files were
// attached AND `navigator.clipboard.read()` is available, use the async
// Clipboard API to read the actual clipboard contents. That call bypasses
// the element-level filter because it reads the system clipboard directly,
// which is what we want.
const handlePaste = async (e: ClipboardEvent) => {
  // Scope: this listener is attached at document level (see onMounted
  // below), so we get every paste on the page. Only intercept paste when
  // it originated in OUR textarea — sibling input components (other chat
  // tabs, search fields, etc.) keep their native paste behavior.
  if (e.target !== chatTextareaRef.value) return

  const items = e.clipboardData?.items
  let pastedImageCount = 0

  // Strategy 1: clipboardData.items (works in Chrome, Firefox, and WebKit
  // variants where the focused element permits file pastes — e.g.
  // contenteditable divs).
  if (items && items.length > 0) {
    for (const item of items) {
      if (item.kind !== 'file') continue
      // Accept images and video (matches the paperclip flow)
      if (!item.type.startsWith('image/') && !item.type.startsWith('video/')) continue
      const file = item.getAsFile()
      if (!file) continue

      // Browsers often leave `file.name` empty for clipboard images; give it
      // a sensible name + extension so FilePreview's tooltip is readable.
      if (!file.name) {
        const ext = item.type.split('/')[1] ?? 'png'
        const renamed = new File([file], `pasted-image-${Date.now()}.${ext}`, { type: item.type })
        addImageFile(renamed)
      } else {
        addImageFile(file)
      }
      pastedImageCount++
    }
  }

  // Strategy 2: WebKitGTK <textarea> filter workaround. If the sync path
  // found no files AND the async Clipboard API is available, use it to read
  // the actual clipboard contents (bypassing the element-level filter).
  // This is silently skipped in browsers without `navigator.clipboard.read`
  // (very old Chromium), and silently no-ops if the user denies the
  // permission prompt the API raises in some configurations.
  if (pastedImageCount === 0 && navigator.clipboard?.read) {
    try {
      const clipboardItems = await navigator.clipboard.read()
      for (const ci of clipboardItems) {
        for (const type of ci.types) {
          if (!type.startsWith('image/') && !type.startsWith('video/')) continue
          const blob = await ci.getType(type)
          const ext = type.split('/')[1] ?? 'png'
          const file = new File([blob], `pasted-image-${Date.now()}.${ext}`, { type })
          addImageFile(file)
          pastedImageCount++
        }
      }
    } catch (err) {
      // Permission denied, clipboard unavailable, or no images present.
      // Silent fall-through — the user can still type and send text.

      console.debug(
        '[paste] navigator.clipboard.read() fallback skipped:',
        err instanceof Error ? err.message : err,
      )
    }
  }

  // If we attached at least one image, suppress the default text paste so
  // the textarea doesn't get a multi-MB `data:image/png;base64,…` string.
  // NOTE: by the time the async fallback (Strategy 2) resolves, the browser's
  // default paste action has already run synchronously, so `preventDefault()`
  // here can't undo it. In the WebKitGTK image-only paste case, the default
  // action would have been a no-op (items is empty), so this is a no-op too.
  // The rarer text+image case loses the text (because WebKitGTK filtered out
  // both text and image items from the paste event); we accept that
  // regression in v1 — text+image paste is uncommon and the workaround
  // would require either a contenteditable refactor or intercepting the
  // keydown event before the browser's paste handler runs.
  if (pastedImageCount > 0) {
    e.preventDefault()
  }
}

// Register the document-level capture-phase paste listener on mount and
// unregister on unmount.
//
// Why document-level (capture phase) instead of `@paste` on the <textarea>?
// The WebKitGTK filter operates on the focused element when it constructs
// `ClipboardEvent.clipboardData` — it does NOT matter where the listener is
// attached (capture phase at document, bubbling phase at document, or
// directly on the textarea all see the same filtered data). The reason we
// move to document-level here is consistency: the handler is mounted once
// at component lifecycle and uses `e.target` to scope intercepts to our
// textarea, so sibling input components (other chat tabs, global search
// boxes) keep their native paste behavior. Capture phase runs before the
// browser's own default-handler in the bubble phase, giving us the option
// to preventDefault sync before the fallback async read decides whether
// images were attached.
onMounted(() => {
  document.addEventListener('paste', handlePaste, true)
  // Restore a draft from an earlier mount of this chat (tab switch), but
  // never clobber text the parent already put in the box.
  const bucket = draftBucket()
  if (bucket && !inputText.value) {
    const saved = bucket.getDraft(draftKey.value)
    if (saved) inputText.value = saved
  }
  // Session switch remounts this component — land the cursor in the box.
  nextTick(() => focusInput())
})

onBeforeUnmount(() => {
  // A fast tab switch can beat the 200 ms debounce — persist synchronously
  // so the text is already in the bucket when the next mount looks for it.
  if (draftTimer) flushDraft()
  document.removeEventListener('paste', handlePaste, true)
  if (fileDebounceTimer) clearTimeout(fileDebounceTimer)
  if (fileSearchTimer) clearTimeout(fileSearchTimer)
  fileSearchAbort?.abort()
})

const queuedMessagesList = computed(() => props.queuedMessages ?? [])
const hasQueuedMessages = computed(() => queuedMessagesList.value.length > 0)

// Toggle queue panel
const showQueuePanel = ref(false)

const toggleQueuePanel = () => {
  showQueuePanel.value = !showQueuePanel.value
}

// Use a queued message
const useQueuedMessage = (msg: QueuedMessage) => {
  inputText.value = msg.message
  showQueuePanel.value = false
}

const isCompletionMsg = (msg: { message: string }): boolean =>
  parseBackgroundCommandOutput(msg.message) !== null
const completionPid = (msg: { message: string }): string | null =>
  parseBackgroundCommandOutput(msg.message)?.pid ?? null

// ── @ picker server search (Task 2: plan
// docs/superpowers/plans/2026-09-08-chatview-search-files-perf.md) ──────
// Single round-trip per query via `api.searchFiles` — replaces the old
// N-sequential-fetch full-tree walk (`loadAllFiles`, deleted).
let fileSearchTimer: ReturnType<typeof setTimeout> | null = null
let fileSearchGen = 0
let fileSearchAbort: AbortController | null = null
// Per-cwd cache for EMPTY-query top-N only (bounded: max 3 cwds, oldest
// evicted). Non-empty queries always hit the server (fresh ranking).
const fileSearchCache = new Map<string, FileEntry[]>()
const FILE_SEARCH_CACHE_MAX_CWDS = 3
// Total entries returned by the server for the current query (footer Y).
const serverTotal = ref(0)
// True when the server errored and `filteredFiles` falls back to the
// client subsequence filter over the cached top-N.
const serverFailed = ref(false)

const setFileSearchCache = (cwd: string, entries: FileEntry[]) => {
  if (!fileSearchCache.has(cwd) && fileSearchCache.size >= FILE_SEARCH_CACHE_MAX_CWDS) {
    const oldest = fileSearchCache.keys().next()
    if (!oldest.done) fileSearchCache.delete(oldest.value)
  }
  fileSearchCache.set(cwd, entries)
}

const toRelativeFileEntry = (
  rootPath: string,
  entry: { name: string; path: string; is_directory: boolean },
): FileEntry => ({
  name: entry.name,
  path: entry.path.startsWith(rootPath) ? entry.path.slice(rootPath.length) : entry.path,
  isDirectory: entry.is_directory,
})

const runFileSearch = async (cwd: string, query: string, gen: number, signal: AbortSignal) => {
  isLoadingFiles.value = true
  try {
    const data = await api.searchFiles(cwd, query, 50, 8, signal)
    if (gen !== fileSearchGen) return // stale — superseded by a newer query
    const mapped = (data.entries ?? []).map((e) => toRelativeFileEntry(cwd, e))
    fileList.value = mapped
    serverTotal.value = mapped.length
    serverFailed.value = false
    if (query === '') setFileSearchCache(cwd, mapped)
  } catch {
    if (gen !== fileSearchGen) return // stale — superseded, stay silent
    if (signal.aborted) return // cancelled on retype/close — expected, silent
    // Error fallback: client subsequence filter over the cached top-N.
    serverFailed.value = true
    fileList.value = fileSearchCache.get(cwd) ?? []
    serverTotal.value = fileList.value.length
  } finally {
    if (gen === fileSearchGen) isLoadingFiles.value = false
  }
}

const scheduleFileSearch = (immediate: boolean) => {
  if (fileSearchTimer) {
    clearTimeout(fileSearchTimer)
    fileSearchTimer = null
  }
  // Cancel any in-flight request (retype/close) — the generation counter
  // below discards responses that still resolve afterwards.
  fileSearchAbort?.abort()
  const run = () => {
    const cwd = props.cwd
    const query = fileQuery.value
    if (!cwd || !showFilePicker.value) return
    // Empty-query cache hit: sync, no network.
    if (query === '' && fileSearchCache.has(cwd)) {
      const cached = fileSearchCache.get(cwd)!
      fileList.value = cached
      serverTotal.value = cached.length
      serverFailed.value = false
      isLoadingFiles.value = false
      return
    }
    fileSearchGen++
    const gen = fileSearchGen
    fileSearchAbort = new AbortController()
    void runFileSearch(cwd, query, gen, fileSearchAbort.signal)
  }
  if (immediate) run()
  else fileSearchTimer = setTimeout(run, 150)
}

const closeFilePicker = () => {
  showFilePicker.value = false
  fileQuery.value = ''
  if (fileSearchTimer) {
    clearTimeout(fileSearchTimer)
    fileSearchTimer = null
  }
  fileSearchAbort?.abort()
  fileSearchGen++ // invalidate in-flight responses
  isLoadingFiles.value = false
}

// Smart word matching: support "out of order" characters
// e.g., "comp" matches "components", "tst" matches "test"
// Used ONLY as the server-error fallback (operates on cached top-N).
const matchesOutOfOrder = (path: string, query: string): boolean => {
  const lowerPath = path.toLowerCase()
  let pathIdx = 0
  let queryIdx = 0

  while (queryIdx < query.length && pathIdx < lowerPath.length) {
    if (lowerPath[pathIdx] === query[queryIdx]) {
      queryIdx++
    }
    pathIdx++
  }
  return queryIdx === query.length
}

const filteredFiles = computed(() => {
  // Server results are already ranked + filtered — use them directly.
  if (!serverFailed.value) return fileList.value
  if (!fileQuery.value) return fileList.value
  const q = fileQuery.value.toLowerCase()
  return fileList.value.filter((f) => matchesOutOfOrder(f.path, q))
})

// Render cap: at most 50 rows in the DOM (v1 — no virtual list).
const visibleFiles = computed(() => filteredFiles.value.slice(0, 50))

const detectAtTrigger = () => {
  const text = inputText.value
  const pos = cursorPos.value
  // Find @ before cursor that starts a file query (includes / and \ for paths)
  const textBeforeCursor = text.slice(0, pos)
  const atMatch = textBeforeCursor.match(/@([\w./\\:-]*)$/)
  if (atMatch) {
    const q = atMatch[1] ?? ''
    const wasOpen = showFilePicker.value
    const queryChanged = q !== fileQuery.value
    fileQuery.value = q
    if (!wasOpen) {
      showFilePicker.value = true
      selectedFileIndex.value = 0
      scheduleFileSearch(true) // immediate on open
    } else if (queryChanged) {
      selectedFileIndex.value = 0
      scheduleFileSearch(false) // debounced 150ms on retype
    }
  } else {
    closeFilePicker()
  }
}

watch(inputText, () => {
  if (fileDebounceTimer) clearTimeout(fileDebounceTimer)
  fileDebounceTimer = setTimeout(detectAtTrigger, 150)
})

const selectFile = (file: FileEntry) => {
  const text = inputText.value
  const pos = cursorPos.value
  // Replace @query at cursor position (includes /, \, :, - for paths).
  // The @ trigger must be preserved — the picked path is inserted AFTER the @,
  // not in place of it, so users see "@/folder" in the input rather than "/folder".
  const textBeforeCursor = text.slice(0, pos)
  const textAfterCursor = text.slice(pos)
  const atMatch = textBeforeCursor.match(/@([\w./\\:-]*)$/)
  if (atMatch && atMatch.index !== undefined) {
    // Slice up to (but not including) the @ — keeps everything before
    // the trigger untouched. Then prepend @ + picked path. The query
    // part (atMatch[1]) is dropped because the picker already filtered
    // down to exactly the entry the user picked.
    inputText.value = textBeforeCursor.slice(0, atMatch.index) + '@' + file.path + textAfterCursor
  }
  closeFilePicker()
}

const handleKeydown = (e: KeyboardEvent) => {
  // Handle file picker navigation
  if (showFilePicker.value) {
    const files = filteredFiles.value
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      e.stopPropagation()
      selectedFileIndex.value = Math.min(selectedFileIndex.value + 1, files.length - 1)
      scrollSelectedIntoView()
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      e.stopPropagation()
      selectedFileIndex.value = Math.max(selectedFileIndex.value - 1, 0)
      scrollSelectedIntoView()
    } else if (e.key === 'Enter') {
      e.preventDefault()
      e.stopPropagation()
      const selectedFile = files[selectedFileIndex.value]
      if (selectedFile) {
        selectFile(selectedFile)
      }
    } else if (e.key === 'Escape') {
      e.stopPropagation()
      closeFilePicker()
    } else if (e.key === 'Tab') {
      e.preventDefault()
      e.stopPropagation()
      const selectedFile = files[selectedFileIndex.value]
      if (selectedFile) {
        selectFile(selectedFile)
      }
    }
    return
  }

  // Handle Enter key for sending
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault()
    sendMessage()
  }
}

const updateCursorPos = (e: Event) => {
  const target = e.target as HTMLTextAreaElement
  cursorPos.value = target.selectionStart ?? 0
}

const autoResize = (e: Event) => {
  const target = e.target as HTMLTextAreaElement
  cursorPos.value = target.selectionStart ?? 0
  target.style.height = 'auto'
  target.style.height = `${Math.min(target.scrollHeight, 200)}px`
}

const scrollSelectedIntoView = () => {
  setTimeout(() => {
    // Scoped to this picker's DOM node (not document) so sibling chat
    // tabs / kanban editors never steal the scroll target.
    const root = filePickerRef.value
    if (!root) return
    const buttons = root.querySelectorAll('button')
    const selectedBtn = buttons[selectedFileIndex.value]
    if (selectedBtn) {
      selectedBtn.scrollIntoView({ behavior: 'auto', block: 'nearest' })
    }
  }, 50)
}

const sendMessage = () => {
  // Use sendMessageWithFiles for full functionality with base64 encoding
  sendMessageWithFiles()
}
</script>

<template>
  <div class="file-input-wrapper composer-card" :class="{ 'review-mode': reviewMode }">
    <!-- Hidden native file input -->
    <input
      ref="nativeFileInput"
      type="file"
      class="hidden"
      accept="image/*,video/*"
      @change="handleNativeFileSelect"
    />

    <!-- Review mode header -->
    <div
      v-if="reviewMode"
      class="mb-3 px-4 py-2 rounded-lg flex items-center gap-2"
      style="background: rgba(135, 169, 135, 0.15); border: 1px solid var(--color-green)"
    >
      <span style="color: var(--color-green)">💬</span>
      <span class="text-sm font-medium" style="color: var(--color-green)">Review Mode</span>
      <span class="text-xs" style="color: var(--semantic-text-dim)"
        >- Submit your code review comment</span
      >
    </div>

    <!-- File picker dropdown -->
    <div
      v-if="showFilePicker && (filteredFiles.length > 0 || isLoadingFiles)"
      ref="filePickerRef"
      class="file-picker-list mb-2 p-2 rounded-lg shadow-lg max-h-72 overflow-y-auto"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      tabindex="0"
    >
      <!-- Loading state (driven by the request lifecycle, not fileList) -->
      <div v-if="isLoadingFiles" class="p-4 text-center">
        <div
          class="w-6 h-6 border-2 rounded-full animate-spin mx-auto mb-2"
          style="border-color: var(--color-violet); border-top-color: transparent"
        ></div>
        <p class="text-sm" style="color: var(--semantic-text-dim)">Searching…</p>
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
          v-for="(file, idx) in visibleFiles"
          :key="file.path"
          @click="selectFile(file)"
          class="w-full text-left px-3 py-1.5 rounded text-sm flex items-center gap-2 transition-colors"
          :class="idx === selectedFileIndex ? 'file-item-selected' : ''"
          :style="
            idx === selectedFileIndex
              ? 'background-color: var(--color-violet); color: var(--color-bg);'
              : 'color: var(--semantic-text);'
          "
          @mouseenter="selectedFileIndex = idx"
        >
          <span>{{ file.isDirectory ? '📁' : '📄' }}</span>
          <span class="truncate font-mono text-xs">{{ file.path }}</span>
        </button>
      </div>
      <!-- Footer info (render cap vs server total) -->
      <div
        v-if="!isLoadingFiles && filteredFiles.length > 0"
        class="px-3 py-1.5 text-xs rounded mt-1"
        style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-dim)"
      >
        showing {{ visibleFiles.length }} of {{ serverTotal }} files
      </div>
    </div>

    <!-- Image preview list -->
    <FilePreview v-model="previewFiles" max-height="120px" />

    <!-- Input form -->
    <form @submit.prevent="sendMessage" class="flex gap-2 items-end">
      <!-- Queue indicator button -->
      <div v-if="hasQueuedMessages" class="relative">
        <button
          type="button"
          @click="toggleQueuePanel"
          class="flex items-center gap-2 px-3 py-3 rounded-xl text-sm transition-all duration-200 border"
          :style="
            showQueuePanel
              ? 'background-color: var(--color-blue-1); border-color: var(--color-violet); color: var(--semantic-text);'
              : 'background-color: var(--semantic-card-bg); border-color: var(--color-border); color: var(--semantic-text);'
          "
        >
          <span
            class="text-xs font-medium px-1.5 py-0.5 rounded"
            style="background-color: var(--color-violet); color: var(--color-bg)"
          >
            {{ queuedMessagesList.length }}
          </span>
          <span style="color: var(--semantic-text-dim)">Queued</span>
          <span
            class="text-xs"
            :style="
              showQueuePanel ? 'color: var(--color-violet);' : 'color: var(--semantic-text-muted);'
            "
          >
            {{ showQueuePanel ? '▲' : '▼' }}
          </span>
        </button>

        <!-- Queue messages panel -->
        <div
          v-if="showQueuePanel"
          class="absolute bottom-full left-0 mb-2 w-80 rounded-xl border shadow-lg overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border-color: var(--color-border);
            max-height: 300px;
          "
        >
          <!-- Panel header -->
          <div
            class="px-4 py-2 border-b flex items-center justify-between"
            style="border-color: var(--color-border)"
          >
            <span class="text-sm font-medium" style="color: var(--semantic-text)"
              >Queued Messages</span
            >
            <span class="text-xs" style="color: var(--semantic-text-dim)"
              >{{ queuedMessagesList.length }} messages</span
            >
          </div>

          <!-- Messages list -->
          <div class="overflow-y-auto" style="max-height: 220px">
            <div
              v-for="msg in queuedMessagesList"
              :key="msg.id"
              class="px-4 py-3 border-b cursor-pointer transition-colors"
              style="border-color: var(--color-border-light)"
              @mouseenter="
                (e) =>
                  ((e.target as HTMLElement).style.backgroundColor = 'var(--hover-bg, #1D1C19)')
              "
              @mouseleave="(e) => ((e.target as HTMLElement).style.backgroundColor = '')"
              @click="useQueuedMessage(msg)"
            >
              <span v-if="isCompletionMsg(msg)" class="text-xs font-medium"
                >Background pid {{ completionPid(msg) }}</span
              >
              <p class="text-sm truncate" style="color: var(--semantic-text)">{{ msg.message }}</p>
              <p class="text-xs mt-1" style="color: var(--semantic-text-dim)">Click to use</p>
            </div>
          </div>

          <!-- Panel footer -->
          <div
            class="px-4 py-2 text-xs text-center"
            style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted)"
          >
            Click a message to use it
          </div>
        </div>
      </div>

      <textarea
        ref="chatTextareaRef"
        v-model="inputText"
        placeholder="Type a message... (@ to search files)"
        :disabled="isInitializing"
        data-testid="chat-message-textarea"
        class="flex-1 px-4 py-3 rounded-xl text-sm outline-none transition-all duration-200 resize-none"
        :class="isInitializing ? 'opacity-60 cursor-not-allowed' : ''"
        style="
          background-color: transparent;
          color: var(--semantic-text);
          border: 1px solid transparent;
          height: 48px;
          max-height: 200px;
          overflow-y: auto;
        "
        @keydown="handleKeydown"
        @input="autoResize"
        @click="autoResize"
        @blur="updateCursorPos"
      ></textarea>
      <!-- Native file picker button -->
      <button
        type="button"
        @click="triggerFilePicker"
        class="px-3 py-3 rounded-xl text-sm transition-all duration-200 border flex items-center gap-1 composer-ghost-btn"
        style="
          background-color: transparent;
          border-color: transparent;
          color: var(--semantic-text-dim);
        "
        title="Select a file (docs, images, etc.)"
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
      <!--
        Stop button — visible only while the LLM is processing. Click
        emits `stop-session`; parent (ChatView) translates to
        POST /api/llm/session/:session/stop. Auto-hides when the SSE
        `worker deleted` event lands (driven by the parent's
        `isLLMProcessing` prop flipping to false).

        The Send/Queue submit button on the right is HIDDEN while the
        agent is processing (`v-if="!isLLMProcessing"`). The brief
        network-in-flight moment (local `isLoading=true` BEFORE the
        SSE `worker created` event lands in processingState) still
        shows the button with its label flipped to "Queue" + spinner —
        so users can see the in-flight submit state — but as soon as
        the agent is actually running the button disappears. Only the
        Stop button is visible during processing.
      -->
      <button
        v-if="isLLMProcessing"
        type="button"
        @click="handleStopClick"
        :disabled="isStopping"
        data-testid="stop-session-button"
        class="px-4 py-3 rounded-xl text-sm font-medium transition-all duration-200 border flex items-center justify-center gap-2 composer-stop-btn"
        :class="isStopping ? 'cursor-not-allowed opacity-70' : ''"
        style="
          background-color: transparent;
          color: var(--color-red);
          border-color: var(--color-border);
          min-width: 96px;
        "
        title="Stop the running agent"
        aria-label="Stop session"
      >
        <div
          v-if="isStopping"
          class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-red); border-top-color: transparent"
        ></div>
        <svg
          v-else
          xmlns="http://www.w3.org/2000/svg"
          class="w-4 h-4"
          viewBox="0 0 24 24"
          fill="currentColor"
        >
          <rect x="6" y="6" width="12" height="12" rx="2" />
        </svg>
        <span>{{ isStopping ? 'Stopping…' : 'Stop' }}</span>
      </button>
      <button
        v-if="!isLLMProcessing"
        type="submit"
        :disabled="isLoading || isInitializing"
        data-testid="send-message-button"
        class="px-4 py-3 rounded-xl font-medium text-sm transition-all duration-200 border flex items-center justify-center gap-2"
        :class="
          isLoading || isInitializing ? 'cursor-not-allowed' : 'hover:opacity-90 active:scale-95'
        "
        :style="
          isLoading
            ? 'background-color: var(--color-orange); color: var(--color-bg); border-color: var(--color-border); min-width: 96px;'
            : 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg); border-color: var(--color-border); min-width: 96px;'
        "
      >
        <div
          v-if="isLoading"
          class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-bg); border-top-color: transparent"
        ></div>
        <span>{{ isLoading ? 'Queue' : 'Send' }}</span>
      </button>
    </form>
    <!-- Composer toolbar strip (V1 single-card): the parent (ChatView)
         projects its status row here so input + status read as one card.
         Rendered only when the slot is provided — other hosts that mount
         FileInput without a toolbar see no extra chrome. -->
    <div v-if="$slots.toolbar" class="composer-toolbar" data-testid="composer-toolbar">
      <slot name="toolbar" />
    </div>
  </div>
</template>

<style scoped>
.file-input-wrapper {
  max-width: 100%;
}

/* V1 single composer card: the wrapper owns the card surface so the
   textarea, action buttons and the projected toolbar strip read as one
   unit. Previously each control carried its own card bg + border, which
   rendered as disconnected floating rows. */
.composer-card {
  background-color: var(--semantic-card-bg);
  border: 1px solid var(--color-border);
  border-radius: 0.75rem;
  padding: 0.75rem 0.75rem 0.375rem;
  transition: border-color 0.2s ease;
}

.composer-card:focus-within {
  border-color: var(--color-violet);
}

.composer-ghost-btn:hover {
  background-color: var(--hover-bg, rgba(255, 255, 255, 0.04));
  color: var(--semantic-text);
}

.composer-stop-btn:hover {
  background-color: rgba(224, 122, 110, 0.12);
}

/* Hairline-separated toolbar strip pinned to the card's bottom edge. */
.composer-toolbar {
  border-top: 1px solid var(--color-border);
  margin-top: 0.5rem;
  padding: 0.375rem 0.25rem 0.25rem;
}

.file-picker-list {
  outline: none;
}

.file-item-selected .font-mono {
  color: var(--color-bg);
}
</style>

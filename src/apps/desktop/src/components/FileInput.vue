<script setup lang="ts">
import { ref, watch, nextTick, computed } from 'vue'
import * as api from '../api'
import FilePreview from './FilePreview.vue'

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
}>()

const emit = defineEmits<{
  'submit': [message: string, files?: File[]]
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

// Pre-fill input when initialMessage is provided (after inputText is declared)
if (props.initialMessage) {
  inputText.value = props.initialMessage
}

// Image preview state
const previewFiles = ref<PreviewFile[]>([])

const isImageFile = (file: File): boolean => {
  return file.type.startsWith('image/')
}

// Convert File to base64 data URL
const fileToBase64 = (file: File): Promise<string> => {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result as string)
    reader.onerror = reject
    reader.readAsDataURL(file)
  })
}

// Send message with files converted to base64
const sendMessageWithFiles = async () => {
  if (!inputText.value.trim() && previewFiles.value.length === 0) return
  
  const message = inputText.value
  const files = previewFiles.value.map(p => p.file)
  
  // Clear state before emit so parent can process
  inputText.value = ''
  showFilePicker.value = false
  previewFiles.value.forEach(item => {
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
watch(() => props.initialMessage, (newVal) => {
  if (newVal) {
    inputText.value = newVal
  }
})

// Trigger native file picker
const triggerFilePicker = () => {
  nativeFileInput.value?.click()
}

// Handle native file selection
const handleNativeFileSelect = (event: Event) => {
  const target = event.target as HTMLInputElement
  const files = target.files
  if (!files || files.length === 0) return
  
  for (const file of files) {
    if (!file) continue
    
    // Create preview for image files
    if (isImageFile(file)) {
      const previewUrl = URL.createObjectURL(file)
      previewFiles.value.push({ file, previewUrl })
    }
  }
  
  // Reset the input so same files can be selected again
  target.value = ''
}



const queuedMessagesList = computed(() => props.queuedMessages ?? [])
const hasQueuedMessages = computed(() => queuedMessagesList.value.length > 0)
const isReviewMode = computed(() => props.reviewMode ?? false)

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

const loadAllFiles = async (rootPath: string) => {
  if (!rootPath) return
  isLoadingFiles.value = true
  fileList.value = []

  const results: FileEntry[] = []

  const scanDir = async (dirPath: string, depth: number) => {


    try {
      const response = await fetch(
        `${api.API_BASE}/system/folder?path=${encodeURIComponent(dirPath)}&action=list`,
      )
      if (!response.ok) return
      const data = await response.json()
      const entries = data.entries || []

      for (const entry of entries) {


        // Skip hidden files/folders (starting with .)
        if (entry.name.startsWith('.')) continue

        if (entry.is_directory) {
          // Add folder as an entry
          const relativePath = entry.path.replace(rootPath, '')
          results.push({
            name: entry.name,
            path: relativePath,
            isDirectory: true,
          })
          // Recurse into subfolder
          await scanDir(entry.path, depth + 1)
        } else {
          // Add file with relative path
          const relativePath = entry.path.replace(rootPath, '')
          results.push({
            name: entry.name,
            path: relativePath,
            isDirectory: false,
          })
        }
      }
    } catch (err) {
      console.error("Failed to scan:", dirPath, err)
    }
  }

  try {
    await scanDir(rootPath, 0)
    // Sort: directories first, then files, alphabetically by path
    results.sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1
      return a.path.localeCompare(b.path)
    })
    fileList.value = results
  } finally {
    isLoadingFiles.value = false
  }
}

const filteredFiles = computed(() => {
  if (!fileQuery.value) return fileList.value
  const q = fileQuery.value.toLowerCase()

  // Smart word matching: support "out of order" characters
  // e.g., "comp" matches "components", "tst" matches "test"
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

  return fileList.value
    .filter(f => matchesOutOfOrder(f.path, q))
})

const detectAtTrigger = () => {
  const text = inputText.value
  const pos = cursorPos.value
  // Find @ before cursor that starts a file query (includes / and \ for paths)
  const textBeforeCursor = text.slice(0, pos)
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

watch(inputText, () => {
  if (fileDebounceTimer) clearTimeout(fileDebounceTimer)
  fileDebounceTimer = setTimeout(detectAtTrigger, 150)
})

const selectFile = (file: FileEntry) => {
  const text = inputText.value
  const pos = cursorPos.value
  // Replace @query at cursor position (includes /, \, :, - for paths)
  const textBeforeCursor = text.slice(0, pos)
  const textAfterCursor = text.slice(pos)
  const atMatch = textBeforeCursor.match(/@([\w./\\:-]*)$/)
  if (atMatch) {
    inputText.value = textBeforeCursor.slice(0, -atMatch[0].length) + file.path + textAfterCursor
  }
  showFilePicker.value = false
  fileQuery.value = ''
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
      showFilePicker.value = false
      fileQuery.value = ''
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
    const buttons = document.querySelectorAll('.file-picker-list button')
    const selectedBtn = buttons[selectedFileIndex.value]
    if (selectedBtn) {
      selectedBtn.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    }
  }, 50)
}

const sendMessage = () => {
  // Use sendMessageWithFiles for full functionality with base64 encoding
  sendMessageWithFiles()
}
</script>

<template>
  <div class="file-input-wrapper" :class="{ 'review-mode': reviewMode }">
    <!-- Hidden native file input -->
    <input
      ref="nativeFileInput"
      type="file"
      class="hidden"
      @change="handleNativeFileSelect"
    />

    <!-- Review mode header -->
    <div v-if="reviewMode" class="mb-3 px-4 py-2 rounded-lg flex items-center gap-2"
      style="background: rgba(135, 169, 135, 0.15); border: 1px solid var(--color-green);">
      <span style="color: var(--color-green);">💬</span>
      <span class="text-sm font-medium" style="color: var(--color-green);">Review Mode</span>
      <span class="text-xs" style="color: var(--semantic-text-dim);">- Submit your code review comment</span>
    </div>

    <!-- File picker dropdown -->
    <div v-if="showFilePicker && (filteredFiles.length > 0 || isLoadingFiles)" ref="filePickerRef"
      class="file-picker-list mb-2 p-2 rounded-lg shadow-lg max-h-72 overflow-y-auto"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
      tabindex="0">
      <!-- Loading state -->
      <div v-if="isLoadingFiles" class="p-4 text-center">
        <div class="w-6 h-6 border-2 rounded-full animate-spin mx-auto mb-2"
          style="border-color: var(--color-violet); border-top-color: transparent;"></div>
        <p class="text-sm" style="color: var(--semantic-text-dim);">Scanning files...</p>
        <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">{{ fileList.length }} found</p>
      </div>
      <div v-else-if="filteredFiles.length === 0" class="p-2 text-sm" style="color: var(--semantic-text-dim);">
        No files found
      </div>
      <div v-else>
        <button v-for="(file, idx) in filteredFiles" :key="file.path" @click="selectFile(file)"
          class="w-full text-left px-3 py-1.5 rounded text-sm flex items-center gap-2 transition-colors"
          :class="idx === selectedFileIndex ? 'file-item-selected' : ''"
          :style="idx === selectedFileIndex
            ? 'background-color: var(--color-violet); color: var(--color-bg);'
            : 'color: var(--semantic-text);'"
          @mouseenter="selectedFileIndex = idx">
          <span>{{ file.isDirectory ? '📁' : '📄' }}</span>
          <span class="truncate font-mono text-xs">{{ file.path }}</span>
        </button>
      </div>
      <!-- Footer info -->
      <div v-if="!isLoadingFiles && filteredFiles.length > 0" class="px-3 py-1.5 text-xs rounded mt-1"
        style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-dim);">
        {{ filteredFiles.length }} of {{ fileList.length }} files shown
      </div>
    </div>

    <!-- Image preview list -->
    <FilePreview v-model="previewFiles" max-height="120px" />

    <!-- Input form -->
    <form @submit.prevent="sendMessage" class="flex gap-3 items-end">
      <!-- Queue indicator button -->
      <div v-if="hasQueuedMessages" class="relative">
        <button type="button" @click="toggleQueuePanel"
          class="flex items-center gap-2 px-3 py-3 rounded-xl text-sm transition-all duration-200 border"
          :style="showQueuePanel
            ? 'background-color: var(--color-blue-1); border-color: var(--color-violet); color: var(--semantic-text);'
            : 'background-color: var(--semantic-card-bg); border-color: var(--color-border); color: var(--semantic-text);'">
          <span class="text-xs font-medium px-1.5 py-0.5 rounded"
            style="background-color: var(--color-violet); color: var(--color-bg);">
            {{ queuedMessagesList.length }}
          </span>
          <span style="color: var(--semantic-text-dim);">Queued</span>
          <span class="text-xs" :style="showQueuePanel ? 'color: var(--color-violet);' : 'color: var(--semantic-text-muted);'">
            {{ showQueuePanel ? '▲' : '▼' }}
          </span>
        </button>

        <!-- Queue messages panel -->
        <div v-if="showQueuePanel"
          class="absolute bottom-full left-0 mb-2 w-80 rounded-xl border shadow-lg overflow-hidden"
          style="background-color: var(--semantic-card-bg); border-color: var(--color-border); max-height: 300px;">
          <!-- Panel header -->
          <div class="px-4 py-2 border-b flex items-center justify-between"
            style="border-color: var(--color-border);">
            <span class="text-sm font-medium" style="color: var(--semantic-text);">Queued Messages</span>
            <span class="text-xs" style="color: var(--semantic-text-dim);">{{ queuedMessagesList.length }} messages</span>
          </div>

          <!-- Messages list -->
          <div class="overflow-y-auto" style="max-height: 220px;">
            <div v-for="msg in queuedMessagesList" :key="msg.id"
              class="px-4 py-3 border-b cursor-pointer transition-colors"
              style="border-color: var(--color-border-light);"
              @mouseenter="(e) => (e.target as HTMLElement).style.backgroundColor = 'var(--hover-bg, #1D1C19)'"
              @mouseleave="(e) => (e.target as HTMLElement).style.backgroundColor = ''"
              @click="useQueuedMessage(msg)">
              <p class="text-sm truncate" style="color: var(--semantic-text);">{{ msg.message }}</p>
              <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">Click to use</p>
            </div>
          </div>

          <!-- Panel footer -->
          <div class="px-4 py-2 text-xs text-center"
            style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);">
            Click a message to use it
          </div>
        </div>
      </div>

      <textarea v-model="inputText" placeholder="Type a message... (@ to search files)"
        class="flex-1 px-4 py-3 rounded-xl text-sm outline-none transition-all duration-200 resize-none"
        style="
          background-color: var(--semantic-card-bg);
          color: var(--semantic-text);
          border: 1px solid var(--color-border);
          height: 48px;
          max-height: 200px;
          overflow-y: auto;
        " @keydown="handleKeydown" @input="autoResize" @click="autoResize" @blur="updateCursorPos"></textarea>
      <!-- Native file picker button -->
      <button type="button" @click="triggerFilePicker"
        class="px-3 py-3 rounded-xl text-sm transition-all duration-200 border flex items-center gap-1"
        style="background-color: var(--semantic-card-bg); border-color: var(--color-border); color: var(--semantic-text);"
        title="Select a file (docs, images, etc.)">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.172 7l-6.586 6.586a2 2 0 102.828 2.828l6.414-6.586a4 4 0 00-5.656-5.656l-6.415 6.586a6 6 0 108.486 8.486L20.5 13"/>
        </svg>
      </button>
      <button type="submit" :disabled="isLoading || isLLMProcessing"
        class="px-5 py-3 rounded-xl font-medium text-sm transition-all duration-200 border flex items-center gap-2"
        :class="isLoading || isLLMProcessing ? 'cursor-not-allowed' : 'hover:opacity-90 active:scale-95'"
        :style="isLoading || isLLMProcessing
          ? 'background-color: var(--color-orange); color: var(--color-bg); border-color: var(--color-border);'
          : 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg); border-color: var(--color-border);'">
        <div v-if="isLoading || isLLMProcessing" class="w-3.5 h-3.5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-bg); border-top-color: transparent;"></div>
        <span>{{ isLoading || isLLMProcessing ? 'Queue' : 'Send' }}</span>
      </button>
    </form>
  </div>
</template>

<style scoped>
.file-input-wrapper {
  max-width: 100%;
}

.file-picker-list {
  outline: none;
}

.file-item-selected .font-mono {
  color: var(--color-bg);
}
</style>
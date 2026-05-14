<script setup lang="ts">
import { ref, watch, nextTick, computed } from 'vue'
import * as api from '../api'

const props = defineProps<{
  cwd: string
}>()

const emit = defineEmits<{
  'submit': [message: string]
}>()

interface FileEntry {
  name: string
  path: string
  isDirectory: boolean
}

const inputText = ref('')
const showFilePicker = ref(false)
const fileQuery = ref('')
const fileList = ref<FileEntry[]>([])
const isLoadingFiles = ref(false)
const selectedFileIndex = ref(0)
const filePickerRef = ref<HTMLElement | null>(null)
let fileDebounceTimer: ReturnType<typeof setTimeout> | null = null

const MAX_DEPTH = 5
const MAX_FILES = 500

const loadAllFiles = async (rootPath: string) => {
  if (!rootPath) return
  isLoadingFiles.value = true
  fileList.value = []

  const results: FileEntry[] = []

  const scanDir = async (dirPath: string, depth: number) => {
    if (depth > MAX_DEPTH || results.length >= MAX_FILES) return

    try {
      const response = await fetch(
        `${api.API_BASE}/system/folder?path=${encodeURIComponent(dirPath)}&action=list`,
      )
      if (!response.ok) return
      const data = await response.json()
      const entries = data.entries || []

      for (const entry of entries) {
        if (results.length >= MAX_FILES) break

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
  if (!fileQuery.value) return fileList.value.slice(0, 50)
  const q = fileQuery.value.toLowerCase()
  return fileList.value
    .filter(f => f.path.toLowerCase().includes(q))
    .slice(0, 50)
})

const detectAtTrigger = () => {
  const text = inputText.value
  const match = text.match(/@([\w.]*)$/)
  if (match) {
    fileQuery.value = match[1] ?? ''
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
  // Replace @query with the file path (handle dots in query)
  inputText.value = text.replace(/@[\w.]*$/, file.path)
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
  if (!inputText.value.trim()) return
  const message = inputText.value
  inputText.value = ''
  showFilePicker.value = false
  emit('submit', message)
}
</script>

<template>
  <div class="file-input-wrapper">
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

    <!-- Input form -->
    <form @submit.prevent="sendMessage" class="flex gap-3 items-end">
      <textarea v-model="inputText" placeholder="Type a message... (@ to search files)" rows="3"
        class="flex-1 px-4 py-3 rounded-xl text-sm outline-none transition-all duration-200 resize-none"
        style="
          background-color: var(--semantic-card-bg);
          color: var(--semantic-text);
          border: 1px solid var(--color-border);
          min-height: 60px;
          max-height: 200px;
        " @keydown="handleKeydown"></textarea>
      <button type="submit"
        class="px-5 py-3 rounded-xl font-medium text-sm transition-all duration-200"
        style="background-color: var(--color-violet); color: var(--color-bg);"
        onmouseover="this.style.opacity='0.85';" onmouseout="this.style.opacity='1';">
        Send
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
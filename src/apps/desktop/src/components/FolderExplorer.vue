<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { listFolder, type FolderEntry } from '../api'

const props = defineProps<{
  cwd?: string
  name?: string
}>()

const emit = defineEmits<{
  'file-click': [file: FolderEntry]
}>()

// Compute header info from props or fall back to path
const headerName = computed(() => props.name || (props.cwd ? props.cwd.split('/').pop() || props.cwd : null))

// Check if we have valid input
const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')

// Nested folders state
const nestedEntriesCache = ref<Record<string, FolderEntry[]>>({})
const rootEntries = ref<FolderEntry[]>([])
const isLoading = ref(false)
const loadError = ref<string | null>(null)

// Load root directory
const loadRoot = async () => {
  if (!props.cwd) {
    rootEntries.value = []
    return
  }

  isLoading.value = true
  loadError.value = null

  try {
    const data = await listFolder(props.cwd)
    rootEntries.value = data.entries || []
  } catch (err) {
    console.error('Failed to load folder:', err)
    loadError.value = 'Failed to load folder'
    rootEntries.value = []
  } finally {
    isLoading.value = false
  }
}

// Watch for cwd changes
watch(() => props.cwd, (newCwd) => {
  nestedEntriesCache.value = {}
  rootEntries.value = []
  if (newCwd) {
    loadRoot()
  }
}, { immediate: true })

// Toggle folder expansion
const toggleFolder = async (entry: FolderEntry) => {
  if (!entry.is_directory) return

  const pathKey = entry.path

  if (nestedEntriesCache.value[pathKey]) {
    // Already fetched, just toggle visibility
    delete nestedEntriesCache.value[pathKey]
  } else {
    // Fetch nested contents
    try {
      const data = await listFolder(pathKey)
      nestedEntriesCache.value = {
        ...nestedEntriesCache.value,
        [pathKey]: data.entries || []
      }
    } catch {
      // Ignore errors
    }
  }
}

// Check if folder is expanded
const isExpanded = (path: string) => !!nestedEntriesCache.value[path]

// Flatten tree for display
interface FlatEntry {
  entry: FolderEntry
  depth: number
  path: string
}

const flattenedEntries = computed(() => {
  const result: FlatEntry[] = []

  const addEntries = (entries: FolderEntry[], depth: number) => {
    for (const entry of entries) {
      const entryPath = entry.path
      result.push({ entry, depth, path: entryPath })

      if (entry.is_directory && nestedEntriesCache.value[entryPath]) {
        const nested = nestedEntriesCache.value[entryPath]
        addEntries(nested, depth + 1)
      }
    }
  }

  addEntries(rootEntries.value, 0)
  return result
})

// Emit event when file is clicked (for opening in editor)
const handleFileClick = (entry: FolderEntry) => {
  if (entry.is_directory) {
    toggleFolder(entry)
  } else {
    // Emit file click event for non-directory files
    emit('file-click', entry)
  }
}

// Open folder on click (for files) or toggle (for folders)
const handleClick = (entry: FolderEntry) => {
  handleFileClick(entry)
}
</script>

<template>
  <div
    class="flex flex-col h-full"
    style="width: 260px; background-color: var(--semantic-sidebar-bg); border-left: 1px solid var(--color-border);"
  >
    <!-- Header -->
    <div
      class="h-10 flex items-center px-3 shrink-0 text-sm font-medium"
      style="border-bottom: 1px solid var(--color-border); color: var(--semantic-text);"
    >
      <span v-if="headerName">{{ headerName }}</span>
      <span v-else style="color: var(--semantic-text-dim);">No folder</span>
    </div>

    <!-- Loading -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <svg class="animate-spin w-5 h-5" style="color: var(--color-aqua);" viewBox="0 0 24 24" fill="none">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
      </svg>
    </div>

    <!-- Error state -->
    <div
      v-else-if="loadError"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-2xl mb-2">⚠️</span>
      <p class="text-xs" style="color: var(--semantic-text-dim);">
        {{ loadError }}
      </p>
    </div>

    <!-- Empty state (no cwd) -->
    <div
      v-else-if="!hasInput"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-3xl mb-3">📂</span>
      <p class="text-xs" style="color: var(--semantic-text-dim);">
        Pass a cwd to browse files
      </p>
    </div>

    <!-- Empty folder -->
    <div
      v-else-if="flattenedEntries.length === 0 && !isLoading"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-2xl mb-2">📭</span>
      <p class="text-xs" style="color: var(--semantic-text-dim);">
        Empty folder
      </p>
    </div>

    <!-- File/Folder List -->
    <div v-else class="flex-1 overflow-y-auto py-1">
      <button
        v-for="{ entry, depth, path } in flattenedEntries"
        :key="path"
        @click="handleClick(entry)"
        class="w-full flex items-center gap-2 px-3 py-1.5 text-sm transition-colors hover:opacity-80"
        :style="{
          paddingLeft: `${0.75 + depth * 1.25}rem`,
          color: entry.is_directory ? 'var(--semantic-text)' : 'var(--semantic-text-muted)',
        }"
      >
        <!-- Expand icon for folders -->
        <span
          v-if="entry.is_directory"
          class="w-3 text-xs flex justify-center transition-transform duration-150"
          :style="{ transform: isExpanded(path) ? 'rotate(90deg)' : 'rotate(0deg)' }"
        >▶</span>
        <span v-else class="w-3"></span>

        <!-- Name -->
        <span class="truncate flex-1 text-left">{{ entry.name }}</span>
      </button>
    </div>

    <!-- Footer with path -->
    <div
      v-if="cwd"
      class="h-8 flex items-center px-3 shrink-0 text-xs truncate"
      style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim);"
      :title="cwd"
    >
      {{ cwd }}
    </div>
  </div>
</template>
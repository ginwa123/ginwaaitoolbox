<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { listFolder, type FolderEntry } from '../api'

const workspacesStore = useWorkspacesStore()

const activeItem = computed(() => workspacesStore.activeWorkspaceItem)
const isLoading = computed(() => activeItem.value?.isLoading ?? false)

// Nested folders state - using object instead of Map for reactivity
const nestedEntriesCache = ref<Record<string, FolderEntry[]>>({})

// Get current entries to display
const currentEntries = computed(() => {
  if (!activeItem.value) return []
  if (activeItem.value.entries) {
    return activeItem.value.entries
  }
  return []
})

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

// Check if folder has nested entries loaded
const hasNestedLoaded = (path: string) => !!nestedEntriesCache.value[path]

// Get nested entries
const getNestedEntries = (path: string): FolderEntry[] => {
  return nestedEntriesCache.value[path] || []
}

// Check if folder is expanded (has loaded children visible)
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
  
  addEntries(currentEntries.value, 0)
  return result
})

// Clear cache when active item changes
watch(() => workspacesStore.activeWorkspaceItemId, () => {
  nestedEntriesCache.value = {}
})

// Open folder on click (for files) or toggle (for folders)
const handleClick = (entry: FolderEntry) => {
  if (entry.is_directory) {
    toggleFolder(entry)
  }
}
</script>

<template>
  <div
    class="flex flex-col h-full"
    style="width: 260px; background-color: var(--semantic-sidebar-bg); border-right: 1px solid var(--color-border);"
  >
    <!-- Header -->
    <div
      class="h-10 flex items-center px-3 shrink-0 text-sm font-medium"
      style="border-bottom: 1px solid var(--color-border); color: var(--semantic-text);"
    >
      <span v-if="activeItem">{{ activeItem.name }}</span>
      <span v-else style="color: var(--semantic-text-dim);">No project selected</span>
    </div>
  
    <!-- Loading -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <svg class="animate-spin w-5 h-5" style="color: var(--color-aqua);" viewBox="0 0 24 24" fill="none">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
      </svg>
    </div>

    <!-- Empty state -->
    <div
      v-else-if="!activeItem"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-3xl mb-3">📂</span>
      <p class="text-xs" style="color: var(--semantic-text-dim);">
        Select a project from the sidebar to browse files
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
      v-if="activeItem?.path"
      class="h-8 flex items-center px-3 shrink-0 text-xs truncate"
      style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim);"
      :title="activeItem.path"
    >
      {{ activeItem.path }}
    </div>
  </div>
</template>
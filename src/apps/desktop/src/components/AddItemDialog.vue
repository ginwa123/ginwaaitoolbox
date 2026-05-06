<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'
import { getSystemFolder, listFolder, type FolderEntry } from '../api'

export interface FolderOption {
  name: string
  path: string
  is_directory: boolean
  is_symlink?: boolean
}

const props = defineProps<{
  show: boolean
}>()

const emit = defineEmits<{
  close: []
  create: [name: string, path: string]
}>()

const name = ref('')
const selectedPath = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const folderList = ref<FolderOption[]>([])
const loading = ref(false)
const error = ref<string | null>(null)
const currentPath = ref('')
const breadcrumbs = ref<{ name: string; path: string }[]>([])

// Navigate to a folder
const navigateToFolder = (folder: FolderOption) => {
  if (!folder.is_directory) return

  // Add current folder to breadcrumbs if not at root
  if (currentPath.value) {
    const currentFolder = folderList.value.find(f => f.path === currentPath.value)
    if (currentFolder) {
      breadcrumbs.value.push({ name: currentFolder.name, path: currentPath.value })
    }
  }

  currentPath.value = folder.path
  fetchFolders(folder.path)
}

// Navigate back one level
const goBack = () => {
  if (breadcrumbs.value.length > 0) {
    // Go to previous breadcrumb
    const prevCrumb = breadcrumbs.value[breadcrumbs.value.length - 1]
    if (prevCrumb) {
      currentPath.value = prevCrumb.path
      breadcrumbs.value = breadcrumbs.value.slice(0, -1)
    }
  } else {
    // Go to root
    currentPath.value = ''
  }
  fetchFolders(currentPath.value || undefined)
}

// Navigate back to a specific breadcrumb
const navigateToBreadcrumb = (index: number) => {
  if (index < 0) {
    // Go to root
    currentPath.value = ''
    breadcrumbs.value = []
  } else {
    const crumb = breadcrumbs.value[index]
    if (crumb) {
      currentPath.value = crumb.path
      breadcrumbs.value = breadcrumbs.value.slice(0, index)
    }
  }
  fetchFolders(currentPath.value || undefined)
}

// Fetch folder contents
const fetchFolders = async (path?: string) => {
  loading.value = true
  error.value = null

  try {
    const data = path ? await listFolder(path) : await getSystemFolder()
    const entries: FolderEntry[] = data.entries || []
    
    folderList.value = entries.map((entry: FolderEntry) => ({
      name: entry.name,
      path: entry.path,
      is_directory: entry.is_directory,
    }))
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Failed to load folders'
    folderList.value = []
  } finally {
    loading.value = false
  }
}

// Watch for show to fetch initial folders
watch(() => props.show, async (show) => {
  if (show) {
    name.value = ''
    selectedPath.value = ''
    currentPath.value = ''
    breadcrumbs.value = []
    folderList.value = []
    await nextTick()
    nameInput.value?.focus()
    fetchFolders()
  }
})

// Handle folder click - select item
const handleFolderClick = (folder: FolderOption) => {
  selectedPath.value = folder.path
}

// Handle folder double-click - navigate into folder
const handleFolderDoubleClick = (folder: FolderOption) => {
  if (folder.is_directory) {
    navigateToFolder(folder)
  }
}

// Navigate into selected folder
const openSelectedFolder = () => {
  if (selectedPath.value) {
    const folder = folderList.value.find(f => f.path === selectedPath.value)
    if (folder?.is_directory) {
      navigateToFolder(folder)
      selectedPath.value = ''
    }
  }
}

// Handle create
const handleCreate = () => {
  if (name.value.trim() && selectedPath.value) {
    emit('create', name.value.trim(), selectedPath.value)
    handleClose()
  }
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    handleClose()
  }
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
        @keydown="handleKeydown"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 bg-black/60 backdrop-blur-sm"
          @click="handleClose"
        />

        <!-- Dialog Content -->
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 70vh;"
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              class="text-base font-semibold"
              style="color: var(--semantic-text);"
            >
              Add Project
            </h3>
            <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Select a folder from the system
            </p>
          </div>

          <!-- Name Input -->
          <div class="px-5 pb-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Project Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="My Project"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            />
          </div>

          <!-- Breadcrumbs -->
          <div
            v-if="currentPath"
            class="px-5 pb-2 flex items-center gap-2 text-xs"
          >
            <button
              @click="goBack"
              class="flex items-center gap-1 px-2 py-1 rounded transition-opacity hover:opacity-80"
              style="background-color: var(--semantic-sidebar-bg); color: var(--color-aqua);"
            >
              <span>←</span>
              <span>Back</span>
            </button>
            <button
              @click="navigateToBreadcrumb(-1)"
              class="px-2 py-1 rounded hover:opacity-80 transition-opacity"
              style="color: var(--semantic-text-dim);"
            >
              /
            </button>
            <template v-for="(crumb, index) in breadcrumbs" :key="crumb.path">
              <span style="color: var(--semantic-text-dim);">/</span>
              <button
                @click="navigateToBreadcrumb(index)"
                class="px-2 py-1 rounded hover:opacity-80 transition-opacity"
                style="color: var(--color-aqua);"
              >
                {{ crumb.name }}
              </button>
            </template>
            <span style="color: var(--semantic-text);">/ {{ currentPath.split('/').pop() }}</span>
          </div>

          <!-- Folder List -->
          <div
            class="flex-1 overflow-y-auto px-5 pb-4"
            style="max-height: 300px;"
          >
            <div
              v-if="loading"
              class="flex items-center justify-center py-8"
            >
              <svg class="animate-spin w-5 h-5" style="color: var(--color-aqua);" viewBox="0 0 24 24" fill="none">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
              </svg>
            </div>

            <div v-else-if="error" class="text-center py-4 text-sm" style="color: var(--semantic-error);">
              {{ error }}
            </div>

            <div v-else class="space-y-0.5">
              <!-- Hint text -->
              <div class="text-xs text-center py-2 mb-2" style="color: var(--semantic-text-dim);">
                Click to select • Double-click folder to navigate
              </div>
              <button
                v-for="folder in folderList"
                :key="folder.path"
                @click="handleFolderClick(folder)"
                @dblclick="handleFolderDoubleClick(folder)"
                class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-200"
                :style="{
                  backgroundColor: selectedPath === folder.path ? 'var(--semantic-active-bg)' : 'transparent',
                  color: selectedPath === folder.path ? 'var(--semantic-active-text)' : 'var(--semantic-text-muted)',
                }"
              >
                <!-- Icon -->
                <span>{{ folder.is_directory ? '📁' : '📄' }}</span>

                <!-- Name -->
                <span class="flex-1 text-left truncate">{{ folder.name }}</span>

                <!-- Selected indicator -->
                <span
                  v-if="selectedPath === folder.path"
                  class="w-2 h-2 rounded-full"
                  style="background-color: var(--color-aqua);"
                />
              </button>

              <div v-if="folderList.length === 0" class="text-center py-4 text-sm" style="color: var(--semantic-text-dim);">
                No folders found
              </div>
            </div>
          </div>

          <!-- Selected Path Display -->
          <div
            v-if="selectedPath"
            class="px-5 py-2 text-xs rounded-lg mx-5 mb-3 flex items-center justify-between gap-2"
            style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-dim);"
          >
            <span class="truncate flex-1">{{ selectedPath }}</span>
            <button
              v-if="folderList.find(f => f.path === selectedPath)?.is_directory"
              @click="openSelectedFolder"
              class="px-2 py-0.5 rounded text-xs transition-opacity hover:opacity-80 shrink-0"
              style="background-color: var(--color-border); color: var(--semantic-text);"
            >
              Open →
            </button>
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              @click="handleClose"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
            >
              Cancel
            </button>
            <button
              @click="handleCreate"
              :disabled="!name.trim() || !selectedPath"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
            >
              Add
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal transitions */
.modal-enter-active,
.modal-leave-active {
  transition: all 0.2s ease-out;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95) translateY(10px);
}
</style>
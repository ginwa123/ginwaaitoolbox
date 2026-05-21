<script setup lang="ts">
import { ref, computed, watch } from 'vue'
import FolderExplorer from './FolderExplorer.vue'
import * as api from '../api'

const props = defineProps<{
  cwd?: string
}>()

const emit = defineEmits<{
  'file-click': [file: api.GitFileChange, staged: boolean]
}>()

// Tab state
const activeTab = ref<'explorer' | 'git'>('explorer')

// Git state
const isGitRepo = ref(false)
const branch = ref('')
const stagedFiles = ref<api.GitFileChange[]>([])
const unstagedFiles = ref<api.GitFileChange[]>([])
const untrackedFiles = ref<api.GitFileChange[]>([])
const isLoadingGit = ref(false)
const gitError = ref<string | null>(null)

// Computed
const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')
const hasChanges = computed(() => stagedFiles.value.length > 0 || unstagedFiles.value.length > 0 || untrackedFiles.value.length > 0)
const changesCount = computed(() => stagedFiles.value.length + unstagedFiles.value.length)

// Get status display helpers
const getStatusIcon = (status: string): string => {
  const icons: Record<string, string> = {
    'M': '📝',
    'A': '➕',
    'D': '🗑️',
    'R': '🔄',
    'C': '📋',
    '??': '❓',
  }
  return icons[status] || '📄'
}

const getStatusText = (status: string): string => {
  const texts: Record<string, string> = {
    'M': 'Modified',
    'A': 'Added',
    'D': 'Deleted',
    'R': 'Renamed',
    'C': 'Copied',
    '??': 'Untracked',
  }
  return texts[status] || 'Changed'
}

const getDisplayStatus = (file: api.GitFileChange): { icon: string; text: string } => {
  const indexStatus = file.index_status === ' ' ? '' : file.index_status
  const worktreeStatus = file.worktree_status === ' ' ? '' : file.worktree_status

  if (file.index_status === '??') {
    return { icon: '❓', text: 'Untracked' }
  }

  if (indexStatus) {
    return { icon: getStatusIcon(indexStatus), text: getStatusText(indexStatus) }
  }

  if (worktreeStatus) {
    return { icon: getStatusIcon(worktreeStatus), text: getStatusText(worktreeStatus) }
  }

  return { icon: '📄', text: 'Changed' }
}

// Load git status
const loadGitStatus = async () => {
  if (!props.cwd) {
    isGitRepo.value = false
    stagedFiles.value = []
    unstagedFiles.value = []
    untrackedFiles.value = []
    return
  }

  isLoadingGit.value = true
  gitError.value = null

  try {
    const data = await api.getGitChanges(props.cwd)

    isGitRepo.value = data.is_git_repo
    branch.value = data.branch || ''

    if (data.is_git_repo) {
      stagedFiles.value = data.staged_files || []
      unstagedFiles.value = data.modified_files || []
      untrackedFiles.value = data.untracked_files || []
    } else {
      stagedFiles.value = []
      unstagedFiles.value = []
      untrackedFiles.value = []
    }
  } catch (err) {
    console.error('Failed to load git status:', err)
    isGitRepo.value = false
    gitError.value = 'Failed to load git status'
  } finally {
    isLoadingGit.value = false
  }
}

// Watch for cwd changes
watch(() => props.cwd, (newCwd) => {
  if (newCwd) {
    loadGitStatus()
  } else {
    isGitRepo.value = false
    stagedFiles.value = []
    unstagedFiles.value = []
    untrackedFiles.value = []
  }
}, { immediate: true })

// Refresh git status
const refreshGitStatus = () => {
  loadGitStatus()
}

// Handle file click from git
const handleFileClick = (file: api.GitFileChange, staged: boolean) => {
  emit('file-click', file, staged)
}
</script>

<template>
  <div
    class="flex flex-col h-full"
    style="width: 280px; background-color: var(--semantic-sidebar-bg); border-left: 1px solid var(--color-border);"
  >
    <!-- Header with tabs -->
    <div
      class="h-10 flex items-center shrink-0"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <!-- Tab buttons -->
      <div class="flex flex-1">
        <button
          @click="activeTab = 'explorer'"
          class="flex-1 h-full px-3 text-sm font-medium transition-colors"
          :style="{
            color: activeTab === 'explorer' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
            backgroundColor: activeTab === 'explorer' ? 'var(--semantic-active-bg)' : 'transparent',
            borderBottom: activeTab === 'explorer' ? '2px solid var(--color-violet)' : '2px solid transparent'
          }"
        >
          Explorer
        </button>
        <button
          @click="activeTab = 'git'"
          class="flex-1 h-full px-3 text-sm font-medium transition-colors flex items-center justify-center gap-1"
          :style="{
            color: activeTab === 'git' ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
            backgroundColor: activeTab === 'git' ? 'var(--semantic-active-bg)' : 'transparent',
            borderBottom: activeTab === 'git' ? '2px solid var(--color-violet)' : '2px solid transparent'
          }"
        >
          Git
          <span
            v-if="hasChanges"
            class="px-1.5 py-0.5 rounded text-xs font-medium"
            style="background-color: var(--color-orange); color: var(--color-bg);"
          >
            {{ changesCount }}
          </span>
        </button>
      </div>
    </div>

    <!-- Content area -->
    <div class="flex-1 overflow-y-auto">
      <!-- Explorer tab -->
      <div v-if="activeTab === 'explorer'" class="h-full">
        <FolderExplorer :cwd="cwd" />
      </div>

      <!-- Git tab -->
      <div v-else-if="activeTab === 'git'" class="h-full flex flex-col">
        <!-- Loading -->
        <div v-if="isLoadingGit" class="flex-1 flex items-center justify-center">
          <svg class="animate-spin w-5 h-5" style="color: var(--color-aqua);" viewBox="0 0 24 24" fill="none">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
          </svg>
        </div>

        <!-- Error state -->
        <div
          v-else-if="gitError"
          class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-2xl mb-2">⚠️</span>
          <p class="text-xs" style="color: var(--semantic-text-dim);">
            {{ gitError }}
          </p>
        </div>

        <!-- Not a git repo -->
        <div
          v-else-if="!isGitRepo || !hasInput"
          class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-3xl mb-3">🌿</span>
          <p class="text-xs" style="color: var(--semantic-text-dim);">
            {{ !hasInput ? 'Select a workspace to view git status' : 'Not a git repository' }}
          </p>
        </div>

        <!-- No changes -->
        <div
          v-else-if="!hasChanges"
          class="flex-1 flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-3xl mb-3">✓</span>
          <p class="text-xs" style="color: var(--semantic-text-dim);">
            Working tree clean
          </p>
          <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
            Branch: {{ branch }}
          </p>
        </div>

        <!-- Git changes -->
        <div v-else class="flex-1 overflow-y-auto">
          <!-- Branch info -->
          <div
            class="px-3 py-2 text-xs flex items-center gap-2"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <span style="color: var(--semantic-text-muted);">🌿</span>
            <span style="color: var(--semantic-text);">{{ branch }}</span>
            <button
              @click="refreshGitStatus"
              class="ml-auto p-1 rounded hover:opacity-70 transition-opacity"
              title="Refresh"
            >
              <svg class="w-3 h-3" style="color: var(--semantic-text-dim);" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
              </svg>
            </button>
          </div>

          <!-- Staged Changes -->
          <div v-if="stagedFiles.length > 0" class="py-1">
            <div
              class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide"
              style="color: var(--color-green);"
            >
              Staged Changes ({{ stagedFiles.length }})
            </div>
            <button
              v-for="file in stagedFiles"
              :key="'staged-' + file.path"
              class="w-full flex items-center gap-2 px-3 py-1.5 text-sm transition-colors hover:opacity-80"
              @click="handleFileClick(file, true)"
            >
              <span class="text-base">{{ getDisplayStatus(file).icon }}</span>
              <span class="flex-1 truncate text-left" style="color: var(--semantic-text);">
                {{ file.path }}
              </span>
              <span
                class="text-xs px-1.5 py-0.5 rounded"
                style="background-color: rgba(34, 197, 94, 0.2); color: var(--color-green);"
              >
                {{ getDisplayStatus(file).text }}
              </span>
            </button>
          </div>

          <!-- Unstaged Changes -->
          <div v-if="unstagedFiles.length > 0" class="py-1">
            <div
              class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide"
              style="color: var(--color-orange);"
            >
              Changes ({{ unstagedFiles.length }})
            </div>
            <button
              v-for="file in unstagedFiles"
              :key="'unstaged-' + file.path"
              class="w-full flex items-center gap-2 px-3 py-1.5 text-sm transition-colors hover:opacity-80"
              @click="handleFileClick(file, false)"
            >
              <span class="text-base">{{ getDisplayStatus(file).icon }}</span>
              <span class="flex-1 truncate text-left" style="color: var(--semantic-text);">
                {{ file.path }}
              </span>
              <span
                class="text-xs px-1.5 py-0.5 rounded"
                style="background-color: rgba(245, 158, 11, 0.2); color: var(--color-orange);"
              >
                {{ getDisplayStatus(file).text }}
              </span>
            </button>
          </div>

          <!-- Untracked Files -->
          <div v-if="untrackedFiles.length > 0" class="py-1">
            <div
              class="px-3 py-1.5 text-xs font-semibold uppercase tracking-wide"
              style="color: var(--semantic-text-dim);"
            >
              Untracked ({{ untrackedFiles.length }})
            </div>
            <button
              v-for="file in untrackedFiles"
              :key="'untracked-' + file.path"
              class="w-full flex items-center gap-2 px-3 py-1.5 text-sm transition-colors hover:opacity-80"
            >
              <span class="text-base">❓</span>
              <span class="flex-1 truncate text-left" style="color: var(--semantic-text-muted);">
                {{ file.path }}
              </span>
              <span
                class="text-xs px-1.5 py-0.5 rounded"
                style="background-color: rgba(156, 163, 175, 0.2); color: var(--semantic-text-dim);"
              >
                Untracked
              </span>
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
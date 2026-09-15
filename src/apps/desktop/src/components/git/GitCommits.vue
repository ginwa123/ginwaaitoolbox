<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import * as api from '../../api'

const props = defineProps<{
  cwd?: string
}>()

const emit = defineEmits<{
  'commit-click': [commit: api.GitCommit]
}>()

const PAGE_SIZE = 100

const isGitRepo = ref(false)
const branch = ref('')
const totalCount = ref(0)
const commits = ref<api.GitCommit[]>([])
const isLoading = ref(false)
const isLoadingMore = ref(false)
const error = ref<string | null>(null)
const selectedSha = ref<string | null>(null)
const detailCache = ref<Record<string, api.GitCommitDetail>>({})
const detailLoading = ref<string | null>(null)
const hasMore = ref(false)

const hasInput = computed(() => !!props.cwd && props.cwd.trim() !== '')
const loadedCount = computed(() => commits.value.length)
const footerLabel = computed(() => {
  if (totalCount.value > 0) return `${loadedCount.value} of ${totalCount.value}`
  return `${loadedCount.value}`
})

const authorInitials = (name: string): string => {
  const parts = (name ?? '').trim().split(/\s+/).filter(Boolean)
  const first = parts[0] ?? ''
  if (parts.length <= 1) return first.slice(0, 2) || '?'
  const last = parts[parts.length - 1] ?? ''
  return ((first[0] ?? '') + (last[0] ?? '')).toUpperCase() || '?'
}

const formatDate = (ts: number): string => {
  if (!ts) return ''
  try {
    return new Date(ts * 1000).toLocaleDateString(undefined, {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    })
  } catch {
    return ''
  }
}

const loadCommits = async (append = false) => {
  if (!props.cwd) {
    isGitRepo.value = false
    commits.value = []
    return
  }
  if (append) isLoadingMore.value = true
  else {
    isLoading.value = true
    error.value = null
  }
  try {
    const skip = append ? commits.value.length : 0
    const data = await api.getGitCommits(props.cwd, PAGE_SIZE, skip)
    isGitRepo.value = data.is_git_repo
    branch.value = data.branch || ''
    totalCount.value = data.total_count || 0
    if (data.is_git_repo) {
      const rows = data.commits || []
      commits.value = append ? [...commits.value, ...rows] : rows
      // More pages remain when a full page came back and (when known)
      // we have not reached the total yet.
      hasMore.value =
        rows.length >= PAGE_SIZE &&
        (totalCount.value <= 0 || commits.value.length < totalCount.value)
    } else {
      if (!append) commits.value = []
      hasMore.value = false
    }
  } catch (err) {
    console.error('Failed to load git commits:', err)
    if (!append) {
      isGitRepo.value = false
      error.value = 'Failed to load commits'
    }
    hasMore.value = false
  } finally {
    isLoading.value = false
    isLoadingMore.value = false
  }
}

const onScroll = (event: Event) => {
  const el = event.target as HTMLElement
  if (!el || isLoadingMore.value || !hasMore.value) return
  // Prefetch the next page before the scroll reaches the bottom.
  if (el.scrollHeight - el.scrollTop - el.clientHeight < 400) {
    void loadCommits(true)
  }
}

const selectCommit = (commit: api.GitCommit) => {
  if (selectedSha.value === commit.sha) {
    selectedSha.value = null
    return
  }
  selectedSha.value = commit.sha
  emit('commit-click', commit)
  void ensureDetail(commit)
}

const ensureDetail = async (commit: api.GitCommit) => {
  if (!props.cwd || detailCache.value[commit.sha]) return
  detailLoading.value = commit.sha
  try {
    const detail = await api.getGitCommitDetail(props.cwd, commit.sha)
    if (detail) detailCache.value = { ...detailCache.value, [commit.sha]: detail }
  } finally {
    if (detailLoading.value === commit.sha) detailLoading.value = null
  }
}

const statusIcon = (status: string): string => {
  const icons: Record<string, string> = { M: '📝', A: '➕', D: '🗑️', R: '🔄', C: '📋' }
  return icons[status] ?? '📄'
}

watch(
  () => props.cwd,
  (newCwd) => {
    selectedSha.value = null
    if (newCwd) void loadCommits(false)
    else {
      isGitRepo.value = false
      commits.value = []
      hasMore.value = false
    }
  },
  { immediate: true },
)

const refresh = () => {
  selectedSha.value = null
  void loadCommits(false)
}

defineExpose({ refresh })
</script>

<template>
  <div class="flex flex-col h-full">
    <!-- Loading -->
    <div v-if="isLoading" class="flex-1 flex items-center justify-center">
      <svg
        class="animate-spin w-5 h-5"
        style="color: var(--color-aqua)"
        viewBox="0 0 24 24"
        fill="none"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path
          class="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
        />
      </svg>
    </div>

    <!-- Error -->
    <div v-else-if="error" class="flex-1 flex flex-col items-center justify-center p-4 text-center">
      <span class="text-2xl mb-2">⚠️</span>
      <p class="text-xs" style="color: var(--semantic-text-dim)">{{ error }}</p>
    </div>

    <!-- Not a git repo -->
    <div
      v-else-if="!isGitRepo || !hasInput"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-3xl mb-3">🌿</span>
      <p class="text-xs" style="color: var(--semantic-text-dim)">
        {{ !hasInput ? 'Select a workspace to view commits' : 'Not a git repository' }}
      </p>
    </div>

    <!-- Empty history -->
    <div
      v-else-if="commits.length === 0"
      class="flex-1 flex flex-col items-center justify-center p-4 text-center"
    >
      <span class="text-3xl mb-3">📭</span>
      <p class="text-xs" style="color: var(--semantic-text-dim)">No commits yet</p>
      <p v-if="branch" class="text-xs mt-1" style="color: var(--semantic-text-dim)">
        Branch: {{ branch }}
      </p>
    </div>

    <!-- Commit list -->
    <template v-else>
      <div
        class="px-3 py-2 text-xs flex items-center gap-2 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <span style="color: var(--semantic-text-muted)">🌿</span>
        <span class="truncate" style="color: var(--semantic-text)">{{ branch }}</span>
        <button
          class="ml-auto p-1 rounded hover:opacity-70 transition-opacity"
          title="Refresh"
          @click="refresh"
        >
          <svg
            class="w-3 h-3"
            style="color: var(--semantic-text-dim)"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
            />
          </svg>
        </button>
      </div>

      <div class="flex-1 overflow-y-auto" @scroll="onScroll">
        <template v-for="commit in commits" :key="commit.sha">
          <button
            class="w-full flex items-center gap-2 px-3 py-1.5 text-sm text-left transition-colors hover:bg-white/5"
            :style="{
              backgroundColor:
                selectedSha === commit.sha ? 'var(--semantic-active-bg)' : 'transparent',
            }"
            :title="`${commit.sha}\n${commit.author} — ${formatDate(commit.timestamp)}\n\n${commit.subject}`"
            @click="selectCommit(commit)"
          >
            <span class="shrink-0 font-mono text-xs" style="color: var(--color-green)">
              {{ commit.short_sha }}
            </span>
            <span
              class="shrink-0 text-xs font-medium"
              style="color: var(--color-violet)"
              :title="commit.author"
            >
              {{ authorInitials(commit.author) }}
            </span>
            <span
              class="shrink-0 w-2 h-2 rounded-full"
              style="background-color: var(--color-orange)"
            />
            <span class="flex-1 truncate" style="color: var(--semantic-text)">
              {{ commit.subject }}
            </span>
          </button>
          <div
            v-if="selectedSha === commit.sha"
            class="px-3 py-2 ml-4 mb-1 rounded"
            style="
              border-left: 2px solid var(--color-violet);
              background-color: rgba(255, 255, 255, 0.02);
            "
          >
            <div class="text-xs font-mono break-all" style="color: var(--color-green)">
              {{ commit.sha }}
            </div>
            <div class="text-xs mt-1" style="color: var(--semantic-text-dim)">
              {{ commit.author }} &lt;{{ commit.email }}&gt; · {{ formatDate(commit.timestamp) }}
            </div>
            <p
              v-if="detailCache[commit.sha]?.body"
              class="text-xs mt-1 whitespace-pre-wrap"
              style="color: var(--semantic-text)"
            >
              {{ detailCache[commit.sha]?.body }}
            </p>
            <div
              v-if="detailLoading === commit.sha"
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim)"
            >
              Loading files…
            </div>
            <div
              v-else-if="detailCache[commit.sha]?.files?.length"
              class="mt-1 flex flex-col gap-0.5"
            >
              <div
                v-for="file in detailCache[commit.sha]?.files ?? []"
                :key="file.path"
                class="flex items-center gap-2 text-xs"
              >
                <span>{{ statusIcon(file.status) }}</span>
                <span class="truncate" style="color: var(--semantic-text)" :title="file.path">
                  {{ file.path }}
                </span>
              </div>
            </div>
          </div>
        </template>

        <div v-if="isLoadingMore" class="flex items-center justify-center py-3">
          <svg
            class="animate-spin w-4 h-4"
            style="color: var(--color-aqua)"
            viewBox="0 0 24 24"
            fill="none"
          >
            <circle
              class="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              stroke-width="4"
            />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            />
          </svg>
        </div>
      </div>

      <div
        class="px-3 py-1.5 text-xs text-right shrink-0"
        style="border-top: 1px solid var(--color-border); color: var(--semantic-text-dim)"
      >
        {{ footerLabel }}
      </div>
    </template>
  </div>
</template>

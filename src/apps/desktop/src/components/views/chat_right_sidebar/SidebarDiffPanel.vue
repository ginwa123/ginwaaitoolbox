<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import * as api from '../../../api'
import { openInNewTab } from '../../../helpers/openInNewTab'
import { isBackgroundOpenEvent } from '../../../helpers/tabTarget'
import { useContextMenu } from '../../../composables/useContextMenu'
import OpenInNewTabMenu from '../../shell/OpenInNewTabMenu.vue'
import {
  parseUnifiedDiff,
  splitDiffByFile,
  type DiffSelection,
  type SplitDiffFile,
} from './parseUnifiedDiff'

const props = defineProps<{
  cwd: string
  /** Attached PR URL (set_pull_request tool). Non-empty switches the panel to PR mode. */
  prUrl?: string
  /** Effective provider for the attached PR (stored pr_provider). */
  prProvider?: string
}>()

const emit = defineEmits<{
  refresh: []
  /**
   * File-row click: host swaps the center column to the full diff.
   * `lines` travel by reference (no copy). `error` set when the
   * worktree fetch failed (PR mode parses inline — always clean).
   */
  'show-diff': [selection: DiffSelection]
}>()

const isGitRepo = ref(false)
const branch = ref('')
const stagedFiles = ref<api.GitFileChange[]>([])
const unstagedFiles = ref<api.GitFileChange[]>([])
const untrackedFiles = ref<api.GitFileChange[]>([])
const isLoadingGit = ref(false)
const gitError = ref<string | null>(null)
const isStaging = ref(false)

const selectedPath = ref<string | null>(null)
const selectedStaged = ref(false)

const changeCount = computed(
  () => stagedFiles.value.length + unstagedFiles.value.length + untrackedFiles.value.length,
)

const isPrMode = computed(() => (props.prUrl ?? '').trim().length > 0)
const prFiles = ref<SplitDiffFile[]>([])
const prBase = ref('')
const prHead = ref('')
const prTruncated = ref(false)
const isLoadingPr = ref(false)
const prError = ref<string | null>(null)

const prStatusIcon: Record<string, string> = { M: '📝', A: '➕', D: '🗑️', R: '🔄' }

const router = useRouter()

// Right-click "Open file in new tab" for a file row. Position state +
// dismiss wiring live in useContextMenu; the row payload (file path)
// lives here so the menu emit can target it (ChatsList pattern).
const { menuPos, openAt, close: closeContextMenu } = useContextMenu()
const contextMenuPath = ref<string | null>(null)

const codeEditorQuery = (path: string): Record<string, string> => ({
  view: 'code-editor',
  file: btoa(path),
  cwd: props.cwd,
})

const openFileInNewTab = (path: string) => {
  openInNewTab(router, { path: '/app', query: codeEditorQuery(path) })
}

const onFileRowContextMenu = (event: MouseEvent, path: string) => {
  contextMenuPath.value = path
  openAt(event)
}

const openMenuFileInBackground = () => {
  const path = contextMenuPath.value
  contextMenuPath.value = null
  closeContextMenu()
  if (!path) return
  openFileInNewTab(path)
}

// Ctrl/Cmd+click and middle-click open the code-editor URL in a real
// browser tab (the browser gesture); plain click keeps panel behavior.
const onFileRowClick = (event: MouseEvent, file: api.GitFileChange, staged: boolean) => {
  if (isBackgroundOpenEvent(event)) {
    openFileInNewTab(file.path)
    return
  }
  selectFile(file, staged)
}

const onPrFileRowClick = (event: MouseEvent, file: SplitDiffFile) => {
  if (isBackgroundOpenEvent(event)) {
    openFileInNewTab(file.path)
    return
  }
  selectPrFile(file)
}

const onFileRowAuxClick = (event: MouseEvent, path: string) => {
  if (event.button !== 1) return
  event.preventDefault()
  openFileInNewTab(path)
}

// Short label for the header: "#42" from /pull/42 or /merge_requests/42,
// else the URL host. Pure display helper (no network).
const prLabel = computed(() => {
  const url = props.prUrl ?? ''
  const m = url.match(/\/(?:pull|merge_requests)\/(\d+)/)
  if (m?.[1]) return `#${m[1]}`
  try {
    return new URL(url).host
  } catch {
    return 'PR'
  }
})

const loadPrDiff = async () => {
  if (!props.cwd || !isPrMode.value) {
    prFiles.value = []
    return
  }
  isLoadingPr.value = true
  prError.value = null
  try {
    const data = await api.getPrDiff(props.cwd, props.prUrl ?? '', {
      provider: props.prProvider || undefined,
    })
    prFiles.value = splitDiffByFile(data.diff_content)
    prBase.value = data.base || ''
    prHead.value = data.head || ''
    prTruncated.value = data.truncated
  } catch (err) {
    console.error('Failed to load PR diff:', err)
    prError.value = 'Failed to load PR diff'
    prFiles.value = []
  } finally {
    isLoadingPr.value = false
  }
}

const selectPrFile = (file: SplitDiffFile) => {
  selectedPath.value = file.path
  selectedStaged.value = false
  const parsed = parseUnifiedDiff(file.text)
  emit('show-diff', {
    path: file.path,
    staged: false,
    lines: parsed.lines,
    added: parsed.added,
    removed: parsed.removed,
  })
}

function displayStatus(file: api.GitFileChange): { icon: string; text: string } {
  if (file.index_status === '??') return { icon: '❓', text: 'Untracked' }
  const indexStatus = file.index_status === ' ' ? '' : file.index_status
  const worktreeStatus = file.worktree_status === ' ' ? '' : file.worktree_status
  const icons: Record<string, string> = { M: '📝', A: '➕', D: '🗑️', R: '🔄', C: '📋', '??': '❓' }
  const texts: Record<string, string> = {
    M: 'Modified',
    A: 'Added',
    D: 'Deleted',
    R: 'Renamed',
    C: 'Copied',
    '??': 'Untracked',
  }
  if (indexStatus)
    return { icon: icons[indexStatus] ?? '📄', text: texts[indexStatus] ?? 'Changed' }
  if (worktreeStatus)
    return { icon: icons[worktreeStatus] ?? '📄', text: texts[worktreeStatus] ?? 'Changed' }
  return { icon: '📄', text: 'Changed' }
}

const onRefreshClick = () => {
  // Tell ChatView to re-sync the worktree binding first (it may have
  // changed since mount); then reload this panel. ChatView also calls
  // back into loadGitStatus via the exposed refresh() when the binding
  // changed, so a stale-cwd click self-heals instead of re-showing
  // the old branch.
  emit('refresh')
  if (isPrMode.value) void loadPrDiff()
  else void loadGitStatus()
}

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

const loadDiff = async () => {
  // Worktree mode only: PR-mode diffs parse inline from the fetched
  // chunks (selectPrFile), so a center-view retry in PR mode is a no-op.
  if (isPrMode.value) return
  if (!props.cwd || !selectedPath.value) return
  try {
    const diff = await api.getGitFileDiff(props.cwd, selectedPath.value, selectedStaged.value)
    const parsed = parseUnifiedDiff(diff.diff_content)
    emit('show-diff', {
      path: selectedPath.value,
      staged: selectedStaged.value,
      lines: parsed.lines,
      added: parsed.added,
      removed: parsed.removed,
    })
  } catch (err) {
    console.error('Failed to load file diff:', err)
    emit('show-diff', {
      path: selectedPath.value,
      staged: selectedStaged.value,
      lines: [],
      added: 0,
      removed: 0,
      error: 'Failed to load file diff',
    })
  }
}

const selectFile = (file: api.GitFileChange, staged: boolean) => {
  selectedPath.value = file.path
  selectedStaged.value = staged
  void loadDiff()
}

const stageFile = async (file: api.GitFileChange) => {
  if (!props.cwd || isStaging.value) return
  isStaging.value = true
  try {
    await api.stageGitFiles(props.cwd, [file.path])
    await loadGitStatus()
    await loadDiff()
  } catch (err) {
    console.error('Failed to stage file:', err)
  } finally {
    isStaging.value = false
  }
}

const unstageFile = async (file: api.GitFileChange) => {
  if (!props.cwd || isStaging.value) return
  isStaging.value = true
  try {
    await api.unstageGitFiles(props.cwd, [file.path])
    await loadGitStatus()
    await loadDiff()
  } catch (err) {
    console.error('Failed to unstage file:', err)
  } finally {
    isStaging.value = false
  }
}

watch(
  () => [props.cwd, props.prUrl],
  () => {
    selectedPath.value = null
    if (isPrMode.value) void loadPrDiff()
    else void loadGitStatus()
  },
)

onMounted(() => {
  if (isPrMode.value) void loadPrDiff()
  else void loadGitStatus()
})

defineExpose({ loadGitStatus, loadPrDiff, loadDiff, changeCount })
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="sidebar-diff-panel">
    <div
      v-if="isPrMode"
      class="flex items-center gap-2 px-3 h-10 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <span class="text-sm">🔀</span>
      <a
        :href="prUrl"
        target="_blank"
        rel="noopener"
        class="text-sm font-medium truncate flex-1 hover:underline"
        style="color: var(--semantic-text)"
        :title="prUrl"
        data-testid="sidebar-pr-link"
      >
        {{ prLabel }}
      </a>
      <span
        v-if="prBase || prHead"
        class="text-xs truncate"
        style="color: var(--semantic-text-dim)"
        :title="`${prBase}...${prHead}`"
      >
        {{ prBase }}…{{ prHead }}
      </span>
      <span
        v-if="prFiles.length > 0"
        class="px-1.5 py-0.5 rounded text-xs font-medium"
        style="background-color: var(--color-violet); color: var(--color-bg)"
        data-testid="sidebar-pr-count"
      >
        {{ prFiles.length }}
      </span>
      <button
        type="button"
        class="text-xs px-2 py-1 rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Refresh PR diff"
        data-testid="sidebar-diff-refresh"
        @click="onRefreshClick"
      >
        ↻
      </button>
    </div>
    <div
      v-else
      class="flex items-center gap-2 px-3 h-10 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <span class="text-sm">🌿</span>
      <span
        class="text-sm font-medium truncate flex-1"
        style="color: var(--semantic-text)"
        data-testid="sidebar-diff-branch"
      >
        {{ branch || 'Git' }}
      </span>
      <span
        v-if="changeCount > 0"
        class="px-1.5 py-0.5 rounded text-xs font-medium"
        style="background-color: var(--color-orange); color: var(--color-bg)"
        data-testid="sidebar-diff-count"
      >
        {{ changeCount }}
      </span>
      <button
        type="button"
        class="text-xs px-2 py-1 rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Refresh git status"
        data-testid="sidebar-diff-refresh"
        @click="onRefreshClick"
      >
        ↻
      </button>
    </div>

    <div class="flex-1 overflow-y-auto min-h-0">
      <template v-if="isPrMode">
        <div v-if="isLoadingPr" class="flex items-center justify-center py-8">
          <svg
            class="animate-spin w-5 h-5"
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
        <div
          v-else-if="prError"
          class="flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-2xl mb-2">⚠️</span>
          <p class="text-xs" style="color: var(--semantic-error)">{{ prError }}</p>
          <button
            type="button"
            class="mt-3 px-3 py-1.5 text-sm rounded"
            style="background: var(--color-green); color: var(--color-bg)"
            data-testid="sidebar-pr-retry"
            @click="loadPrDiff"
          >
            Retry
          </button>
        </div>
        <div
          v-else-if="prFiles.length === 0"
          class="flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-3xl mb-3">🔀</span>
          <p class="text-xs" style="color: var(--semantic-text-dim)">No PR changes found</p>
        </div>
        <template v-else>
          <div
            v-if="prTruncated"
            class="px-3 py-1 text-xs"
            style="color: var(--semantic-text-dim)"
          >
            Diff truncated at 1MB — showing first files
          </div>
          <div class="py-1">
            <div
              class="px-3 py-1 text-xs font-semibold"
              style="color: var(--color-violet)"
            >
              PR files ({{ prFiles.length }})
            </div>
            <div
              v-for="file in prFiles"
              :key="'pr-' + file.path"
              class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:opacity-80"
              :style="{
                backgroundColor:
                  selectedPath === file.path
                    ? 'var(--semantic-active-bg)'
                    : 'transparent',
              }"
              :data-testid="`sidebar-pr-file-${file.path}`"
              @click="onPrFileRowClick($event, file)"
              @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
              @auxclick="onFileRowAuxClick($event, file.path)"
            >
              <span class="text-xs">{{ prStatusIcon[file.status] ?? '📄' }}</span>
              <span
                class="text-xs truncate flex-1"
                style="color: var(--semantic-text)"
                :title="file.path"
              >
                {{ file.path }}
              </span>
            </div>
          </div>
        </template>
      </template>
      <template v-else>
      <div v-if="isLoadingGit" class="flex items-center justify-center py-8">
        <svg
          class="animate-spin w-5 h-5"
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

      <div v-else-if="gitError" class="flex flex-col items-center justify-center p-4 text-center">
        <span class="text-2xl mb-2">⚠️</span>
        <p class="text-xs" style="color: var(--semantic-error)">{{ gitError }}</p>
        <button
          type="button"
          class="mt-3 px-3 py-1.5 text-sm rounded"
          style="background: var(--color-green); color: var(--color-bg)"
          data-testid="sidebar-diff-retry"
          @click="loadGitStatus"
        >
          Retry
        </button>
      </div>

      <div v-else-if="!isGitRepo" class="flex flex-col items-center justify-center p-4 text-center">
        <span class="text-3xl mb-3">🌿</span>
        <p class="text-xs" style="color: var(--semantic-text-dim)">
          {{ !cwd ? 'Select a workspace to view git status' : 'Not a git repository' }}
        </p>
      </div>

      <div
        v-else-if="changeCount === 0"
        class="flex flex-col items-center justify-center p-4 text-center"
      >
        <span class="text-3xl mb-3">✓</span>
        <p class="text-xs" style="color: var(--semantic-text-dim)">Working tree clean</p>
      </div>

      <template v-else>
        <div v-if="stagedFiles.length > 0" class="py-1">
          <div class="px-3 py-1 text-xs font-semibold" style="color: var(--color-green)">
            Staged Changes ({{ stagedFiles.length }})
          </div>
          <div
            v-for="file in stagedFiles"
            :key="'staged-' + file.path"
            class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:opacity-80"
            :style="{
              backgroundColor:
                selectedPath === file.path && selectedStaged
                  ? 'var(--semantic-active-bg)'
                  : 'transparent',
            }"
            :data-testid="`sidebar-diff-file-staged-${file.path}`"
            @click="onFileRowClick($event, file, true)"
            @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
            @auxclick="onFileRowAuxClick($event, file.path)"
          >
            <span class="text-xs">{{ displayStatus(file).icon }}</span>
            <span
              class="text-xs truncate flex-1"
              style="color: var(--semantic-text)"
              :title="file.path"
            >
              {{ file.path }}
            </span>
            <button
              type="button"
              class="text-xs px-1 rounded hover:opacity-70"
              style="color: var(--semantic-text-dim)"
              title="Unstage file"
              :disabled="isStaging"
              @click.stop="unstageFile(file)"
            >
              −
            </button>
          </div>
        </div>

        <div v-if="unstagedFiles.length > 0" class="py-1">
          <div class="px-3 py-1 text-xs font-semibold" style="color: var(--color-orange)">
            Changes ({{ unstagedFiles.length }})
          </div>
          <div
            v-for="file in unstagedFiles"
            :key="'unstaged-' + file.path"
            class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:opacity-80"
            :style="{
              backgroundColor:
                selectedPath === file.path && !selectedStaged
                  ? 'var(--semantic-active-bg)'
                  : 'transparent',
            }"
            :data-testid="`sidebar-diff-file-unstaged-${file.path}`"
            @click="onFileRowClick($event, file, false)"
            @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
            @auxclick="onFileRowAuxClick($event, file.path)"
          >
            <span class="text-xs">{{ displayStatus(file).icon }}</span>
            <span
              class="text-xs truncate flex-1"
              style="color: var(--semantic-text)"
              :title="file.path"
            >
              {{ file.path }}
            </span>
            <button
              type="button"
              class="text-xs px-1 rounded hover:opacity-70"
              style="color: var(--semantic-text-dim)"
              title="Stage file"
              :disabled="isStaging"
              @click.stop="stageFile(file)"
            >
              +
            </button>
          </div>
        </div>

        <div v-if="untrackedFiles.length > 0" class="py-1">
          <div class="px-3 py-1 text-xs font-semibold" style="color: var(--semantic-text-dim)">
            Untracked ({{ untrackedFiles.length }})
          </div>
          <div
            v-for="file in untrackedFiles"
            :key="'untracked-' + file.path"
            class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:opacity-80"
            :style="{
              backgroundColor:
                selectedPath === file.path && !selectedStaged
                  ? 'var(--semantic-active-bg)'
                  : 'transparent',
            }"
            :data-testid="`sidebar-diff-file-untracked-${file.path}`"
            @click="onFileRowClick($event, file, false)"
            @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
            @auxclick="onFileRowAuxClick($event, file.path)"
          >
            <span class="text-xs">❓</span>
            <span
              class="text-xs truncate flex-1"
              style="color: var(--semantic-text)"
              :title="file.path"
            >
              {{ file.path }}
            </span>
            <button
              type="button"
              class="text-xs px-1 rounded hover:opacity-70"
              style="color: var(--semantic-text-dim)"
              title="Stage file"
              :disabled="isStaging"
              @click.stop="stageFile(file)"
            >
              +
            </button>
          </div>
        </div>


      </template>
      </template>

    </div>

    <OpenInNewTabMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      :show-chat="false"
      show-file
      @open-file="openMenuFileInBackground"
    />

  </div>
</template>


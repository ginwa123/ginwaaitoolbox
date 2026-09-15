<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import * as api from '../../../api'
import FileInput from '../../file/FileInput.vue'
import {
  escapeDiffHtml,
  parseUnifiedDiff,
  splitDiffByFile,
  type ParsedDiffLine,
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
  'submit-review': [message: string]
  refresh: []
  /** File-row click (or header Open button): host opens the file in the code browser. */
  'open-file': [payload: { path: string; line?: number }]
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

const diffLoading = ref(false)
const diffError = ref<string | null>(null)
const diffLines = ref<ParsedDiffLine[]>([])
const diffAdded = ref(0)
const diffRemoved = ref(0)
const wordWrap = ref(false)

const showMiniChat = ref(false)
const miniChatPosition = ref({ x: 0, y: 0 })
const miniChatContent = ref('')
const miniChatFilePath = ref('')
const miniChatStartLine = ref(0)
const miniChatEndLine = ref(0)

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
  closeMiniChat()
  const parsed = parseUnifiedDiff(file.text)
  diffLines.value = parsed.lines
  diffAdded.value = parsed.added
  diffRemoved.value = parsed.removed
  emit('open-file', { path: file.path })
}

// Header Open button: navigate to the selected file, jumping to the
// first added line when the diff has one (else the editor opens at top).
const openSelectedFile = () => {
  if (!selectedPath.value) return
  const firstAdd = diffLines.value.find((l) => l.type === 'add')
  emit('open-file', { path: selectedPath.value, line: firstAdd?.newLineNum })
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
  if (!props.cwd || !selectedPath.value) return
  diffLoading.value = true
  diffError.value = null
  try {
    const diff = await api.getGitFileDiff(props.cwd, selectedPath.value, selectedStaged.value)
    const parsed = parseUnifiedDiff(diff.diff_content)
    diffLines.value = parsed.lines
    diffAdded.value = parsed.added
    diffRemoved.value = parsed.removed
  } catch (err) {
    console.error('Failed to load file diff:', err)
    diffError.value = 'Failed to load file diff'
  } finally {
    diffLoading.value = false
  }
}

const selectFile = (file: api.GitFileChange, staged: boolean) => {
  selectedPath.value = file.path
  selectedStaged.value = staged
  closeMiniChat()
  void loadDiff()
  // Plain click navigates to the code browser (host-owned); the inline
  // selection above keeps panel context.
  emit('open-file', { path: file.path })
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

const openMiniChat = (event: MouseEvent, line: ParsedDiffLine) => {
  if (line.type !== 'add' && line.type !== 'remove') return
  event.preventDefault()
  event.stopPropagation()
  miniChatPosition.value = { x: event.clientX, y: event.clientY }
  const lineIdx = diffLines.value.indexOf(line)
  const startIdx = Math.max(0, lineIdx - 3)
  const endIdx = Math.min(diffLines.value.length, lineIdx + 4)
  const contextLines = diffLines.value.slice(startIdx, endIdx)
  if (contextLines.length === 0) return
  miniChatFilePath.value = selectedPath.value ?? ''
  miniChatStartLine.value = contextLines[0]!.newLineNum || contextLines[0]!.oldLineNum || 0
  const last = contextLines[contextLines.length - 1]!
  miniChatEndLine.value = last.newLineNum || last.oldLineNum || 0
  miniChatContent.value = contextLines
    .map((l) => {
      const prefix = l.type === 'add' ? '+' : l.type === 'remove' ? '-' : ' '
      const lineNum = l.newLineNum || l.oldLineNum || ''
      return `${lineNum} ${prefix}${l.content}`
    })
    .join('\n')
  showMiniChat.value = true
}

const miniChatStyle = computed(() => {
  const vw = typeof globalThis.window !== 'undefined' ? globalThis.window.innerWidth : 1280
  const vh = typeof globalThis.window !== 'undefined' ? globalThis.window.innerHeight : 800
  return {
    left: Math.min(miniChatPosition.value.x, vw - 420) + 'px',
    top: Math.min(miniChatPosition.value.y, vh - 300) + 'px',
    width: '400px',
    backgroundColor: 'var(--semantic-card-bg)',
    border: '1px solid var(--color-border)',
  }
})

const closeMiniChat = () => {
  showMiniChat.value = false
  miniChatContent.value = ''
  miniChatFilePath.value = ''
  miniChatStartLine.value = 0
  miniChatEndLine.value = 0
}

const submitMiniChat = (message: string) => {
  const lineRange =
    miniChatStartLine.value === miniChatEndLine.value
      ? `Line ${miniChatStartLine.value}`
      : `Lines ${miniChatStartLine.value}-${miniChatEndLine.value}`
  emit(
    'submit-review',
    `## Code Review\n**File:** \`${miniChatFilePath.value}\`\n**${lineRange}**\n\n\`\`\`\n${miniChatContent.value}\n\`\`\`\n\n## Review Comment\n\n${message}`,
  )
  closeMiniChat()
}

watch(
  () => [props.cwd, props.prUrl],
  () => {
    selectedPath.value = null
    diffLines.value = []
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
              @click="selectPrFile(file)"
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
            @click="selectFile(file, true)"
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
            @click="selectFile(file, false)"
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
            @click="selectFile(file, false)"
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
      <div v-if="selectedPath" class="mt-2" style="border-top: 1px solid var(--color-border)">
        <div class="flex items-center gap-2 px-3 py-2" style="background: var(--color-bg-m2)">
          <span
            class="text-xs font-medium truncate flex-1"
            style="color: var(--semantic-text)"
            :title="selectedPath"
            data-testid="sidebar-diff-selected"
          >
            {{ selectedPath }}
          </span>
          <span
            v-if="selectedStaged"
            class="text-xs px-1.5 py-0.5 rounded"
            style="background: rgba(135, 169, 135, 0.15); color: var(--color-green)"
          >
            Staged
          </span>
          <span class="text-xs font-mono" style="color: var(--color-green)">
            +{{ diffAdded }}
          </span>
          <span class="text-xs font-mono" style="color: var(--color-red)">
            -{{ diffRemoved }}
          </span>
          <button
            type="button"
            class="px-2 py-1 text-xs rounded"
            :style="{
              backgroundColor: wordWrap ? 'var(--semantic-active-bg)' : 'transparent',
              color: wordWrap ? 'var(--semantic-text)' : 'var(--semantic-text-dim)',
            }"
            title="Toggle word wrap"
            @click="wordWrap = !wordWrap"
          >
            Wrap
          </button>
          <button
            type="button"
            class="px-2 py-1 text-xs rounded hover:opacity-70"
            style="color: var(--semantic-text-dim)"
            title="Open file in code browser"
            aria-label="Open file in code browser"
            data-testid="sidebar-diff-open-file"
            @click="openSelectedFile"
          >
            ⤴
          </button>
        </div>

        <div v-if="diffLoading" class="flex items-center justify-center py-6">
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

        <div v-else-if="diffError" class="flex flex-col items-center justify-center p-4">
          <span class="text-2xl mb-2">⚠️</span>
          <p class="text-xs" style="color: var(--semantic-error)">{{ diffError }}</p>
          <button
            type="button"
            class="mt-3 px-3 py-1.5 text-sm rounded"
            style="background: var(--color-green); color: var(--color-bg)"
            @click="loadDiff"
          >
            Retry
          </button>
        </div>

        <div
          v-else-if="diffLines.length === 0"
          class="flex flex-col items-center justify-center p-4"
        >
          <span class="text-2xl mb-2">📄</span>
          <p class="text-xs" style="color: var(--semantic-text-dim)">No changes detected</p>
        </div>

        <div
          v-else
          class="overflow-auto"
          :class="{ 'wrap-on': wordWrap }"
          :style="{
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
            maxHeight: '40vh',
          }"
        >
          <table class="w-full border-collapse" style="font-size: 12px; line-height: 20px">
            <tbody>
              <template v-for="(line, idx) in diffLines" :key="idx">
                <tr v-if="line.type === 'hunk'">
                  <td
                    colspan="3"
                    class="px-3 py-1"
                    style="background: rgba(139, 164, 176, 0.1); color: var(--color-blue)"
                  >
                    {{ line.content }}
                  </td>
                </tr>
                <tr
                  v-else-if="line.type === 'add'"
                  style="cursor: pointer"
                  @click="openMiniChat($event, line)"
                >
                  <td
                    class="w-10 px-2 text-right select-none"
                    style="color: var(--semantic-text-dim); user-select: none"
                  >
                    {{ line.newLineNum || '' }}
                  </td>
                  <td
                    class="w-10 px-2 text-right select-none"
                    style="color: var(--semantic-text-dim); user-select: none"
                  ></td>
                  <td
                    class="px-2"
                    style="
                      border-left: 3px solid var(--color-green);
                      background: rgba(135, 169, 135, 0.15);
                      color: var(--semantic-text);
                    "
                  >
                    <span style="color: var(--color-green); font-weight: bold">+</span>
                    <span v-html="escapeDiffHtml(line.content)"></span>
                  </td>
                </tr>
                <tr
                  v-else-if="line.type === 'remove'"
                  style="cursor: pointer"
                  @click="openMiniChat($event, line)"
                >
                  <td
                    class="w-10 px-2 text-right select-none"
                    style="color: var(--semantic-text-dim); user-select: none"
                  >
                    {{ line.oldLineNum || '' }}
                  </td>
                  <td
                    class="w-10 px-2 text-right select-none"
                    style="color: var(--semantic-text-dim); user-select: none"
                  ></td>
                  <td
                    class="px-2"
                    style="
                      border-left: 3px solid var(--color-red);
                      background: rgba(169, 135, 135, 0.15);
                      color: var(--semantic-text);
                    "
                  >
                    <span style="color: var(--color-red); font-weight: bold">−</span>
                    <span v-html="escapeDiffHtml(line.content)"></span>
                  </td>
                </tr>
                <tr v-else-if="line.type === 'context'">
                  <td
                    class="w-10 px-2 text-right select-none"
                    style="color: var(--semantic-text-dim); user-select: none"
                  >
                    {{ line.oldLineNum || '' }}
                  </td>
                  <td
                    class="w-10 px-2 text-right select-none"
                    style="color: var(--semantic-text-dim); user-select: none"
                  >
                    {{ line.newLineNum || '' }}
                  </td>
                  <td class="px-2" style="color: var(--semantic-text-dim)">
                    <span>&nbsp;</span>
                    <span v-html="escapeDiffHtml(line.content)"></span>
                  </td>
                </tr>
              </template>
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <Teleport to="body">
      <div
        v-if="showMiniChat"
        class="mini-chat-popup fixed z-50 rounded-lg shadow-lg p-3"
        :style="miniChatStyle"
      >
        <div class="text-xs mb-2 flex items-center gap-2" style="color: var(--semantic-text-dim)">
          <span class="flex-1">Review {{ miniChatFilePath }} ({{ miniChatStartLine }}–{{ miniChatEndLine }})</span>
          <button type="button" class="hover:opacity-70" title="Close review" @click="closeMiniChat">✕</button>
        </div>
        <FileInput :cwd="cwd" :review-mode="true" @submit="submitMiniChat" />
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.wrap-on td:last-child {
  white-space: pre-wrap;
  word-break: break-word;
}
</style>

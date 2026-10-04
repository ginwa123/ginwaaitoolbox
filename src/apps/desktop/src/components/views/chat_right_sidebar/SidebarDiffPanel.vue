<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import * as api from '../../../api'
import { openInNewTab } from '../../../helpers/openInNewTab'
import { conflictsUrl, forgeWording } from '../../../helpers/forgeWording'
import { isBackgroundOpenEvent } from '../../../helpers/tabTarget'
import { useContextMenu } from '../../../composables/useContextMenu'
import OpenInNewTabMenu from '../../shell/OpenInNewTabMenu.vue'
import GitCommits from '../../git/GitCommits.vue'
import PrChecksPanel from './PrChecksPanel.vue'
import SkillEvalsPanel from './SkillEvalsPanel.vue'
import {
  parseUnifiedDiff,
  splitDiffByFile,
  type DiffSelection,
  type SplitDiffFile,
} from './parseUnifiedDiff'

const props = defineProps<{
  cwd: string
  /** Branch from the bottom status bar (single source of truth, drilled
   * via ChatRightSidebar from ChatView's `sidebarBranch`). `undefined`
   * while the status bar is still loading — the panel falls back to its
   * own fetched branch. Kills the worktree-switch race where the panel's
   * independent getGitChanges resolved with the stale branch. */
  branch?: string
  /** Attached PR URL (set_pull_request tool). Non-empty switches the panel to PR mode. */
  prUrl?: string
  /** Effective provider for the attached PR (stored pr_provider). */
  prProvider?: string
  /** The session whose skill evals the Evals tab shows. Empty = every session. */
  sessionId?: string
}>()

const emit = defineEmits<{
  refresh: []
  /**
   * File-row click: host swaps the center column to the full diff.
   * `lines` travel by reference (no copy). `error` set when the
   * worktree fetch failed (PR mode parses inline — always clean).
   */
  'show-diff': [selection: DiffSelection]
  /**
   * Full ordered list after a list load (PR: parsed chunks; worktree:
   * parallel per-file fetch). ChatView stacks every file in the center
   * column; per-click `show-diff` stays instant and unchanged.
   */
  'show-diff-list': [files: DiffSelection[]]
}>()

const isGitRepo = ref(false)
const internalBranch = ref('')
// Displayed branch: the bottom status bar wins when it has a value.
// The panel keeps its own fetch as fallback (direct mounts, tests,
// status bar still loading).
const displayBranch = computed(() => props.branch ?? internalBranch.value)
const stagedFiles = ref<api.GitFileChange[]>([])
const unstagedFiles = ref<api.GitFileChange[]>([])
const untrackedFiles = ref<api.GitFileChange[]>([])
const isLoadingGit = ref(false)
const gitError = ref<string | null>(null)
const isStaging = ref(false)
let loadSeq = 0

const selectedPath = ref<string | null>(null)
const selectedStaged = ref(false)

const changeCount = computed(
  () => stagedFiles.value.length + unstagedFiles.value.length + untrackedFiles.value.length,
)

const router = useRouter()
const route = useRoute()

const readTabParam = (): 'files' | 'pr' | 'commits' | 'checks' | 'evals' | null => {
  const v = route.query.panel
  return v === 'files' || v === 'pr' || v === 'commits' || v === 'checks' || v === 'evals'
    ? v
    : null
}

const syncTabParam = (tab: 'files' | 'pr' | 'commits' | 'checks' | 'evals' | null) => {
  const query = { ...route.query }
  if (tab) query.panel = tab
  else delete query.panel
  router.replace({ path: route.path, query }).catch(() => {})
}

// "⚠ Conflicts only" filter. View state, so it lives in the URL next to
// ?panel= (refresh / Back / shared links restore the same panel) — a local
// ref would lose it on reload. Reuses the existing query object rather than
// inventing a second history entry; `replace`, not `push`, because toggling a
// filter is not a navigation.
const readConflictsParam = (): boolean => route.query.conflicts === '1'

const syncConflictsParam = (on: boolean) => {
  const query = { ...route.query }
  if (on) query.conflicts = '1'
  else delete query.conflicts
  router.replace({ path: route.path, query }).catch(() => {})
}

const isPrMode = computed(() => (props.prUrl ?? '').trim().length > 0)
// Every view switch lands in the URL (?panel=files|pr|commits|checks|evals)
// so refresh, Back/Forward, and shared links restore the same panel. The
// commits tab is valid with or without an attached PR; ?panel=pr without a
// prUrl still falls back to files (pre-commits behavior). Checks is reachable
// without a PR too — it says so rather than 404-ing a panel that is simply
// open. The evals tab is independent of PR mode — it shows the agent's
// self-eval verdicts.
// The route read is guarded: hosts like ChatRightSidebar mount this panel
// without a router (see ChatRightSidebar.spec.ts), where useRoute has no
// current route — mount must never crash there.
const initialTab = (): 'files' | 'pr' | 'commits' | 'checks' | 'evals' => {
  let param: 'files' | 'pr' | 'commits' | 'checks' | 'evals' | null = null
  try {
    param = readTabParam()
  } catch {
    // This catch exists ONLY for "mounted without a router" — hosts like
    // ChatRightSidebar mount this panel standalone (ChatRightSidebar.spec.ts),
    // and `useRoute()` injects nothing there, so `route.query` throws on a
    // null deref. It cannot reach the user: nothing was fetched, this runs at
    // mount before any data loads, and with no router there is no URL to keep
    // in sync. `files` is the documented default, so the fallback is correct
    // — but the condition is still logged rather than swallowed, because a
    // mount that silently lost its router is worth seeing in the console.
    console.warn('[SidebarDiffPanel] mounted without a router; defaulting ?panel to files')
    param = null
  }
  // Evals and checks are reachable regardless of PR mode.
  if (param === 'evals') return 'evals'
  if (param === 'checks') return 'checks'
  if (isPrMode.value) return param ?? 'pr'
  return param === 'commits' ? 'commits' : 'files'
}
const activeTab = ref<'files' | 'pr' | 'commits' | 'checks' | 'evals'>(initialTab())
const showCommits = computed(() => activeTab.value === 'commits')
const showChecks = computed(() => activeTab.value === 'checks')
const showEvals = computed(() => activeTab.value === 'evals')
// PrChecksPanel loads itself, so the sidebar's ↻ asks it directly rather
// than going through loadTab (which has nothing to fetch for this tab).
const checksRef = ref<InstanceType<typeof PrChecksPanel> | null>(null)
const showTabs = computed(() => isPrMode.value)
const showPr = computed(() => isPrMode.value && activeTab.value === 'pr')
const loadedTabs = ref(new Set<string>())
const prFiles = ref<SplitDiffFile[]>([])
const prBase = ref('')
const prHead = ref('')
const prTruncated = ref(false)
const isLoadingPr = ref(false)
const prError = ref<string | null>(null)
// Live merge state from GET /api/git/pr/status (`gh pr view`).
// Empty = unknown (fetch failed or not yet loaded) — badge hidden.
const prStatus = ref('')
const prStatusTitle = ref('')
// Conflict flag from the same payload (`mergeable`/`merge_state`).
// Quiet-when-clean: only CONFLICTING/DIRTY surfaces UI; every other
// value behaves exactly as before (no banner, no badge).
const prMergeable = ref('')
const prMergeState = ref('')
const hasPrConflict = computed(() => {
  const m = (prMergeable.value || '').toUpperCase()
  const s = (prMergeState.value || '').toUpperCase()
  // GitHub says CONFLICTING / DIRTY.
  if (m === 'CONFLICTING') return true
  if (s === 'DIRTY') return true
  // GitLab's `detailed_merge_status` has its own vocabulary. Without
  // these rows a conflicted MR renders as mergeable, which is the worst
  // direction to be wrong in — the user is told to merge something that
  // cannot merge.
  if (m === 'CONFLICTED') return true
  if (m === 'NOT_MERGEABLE') return true
  return false
})
// GitHub renders conflict resolution at <pr-url>/conflicts. GitLab has no
// such route, so this returns '' there and the notice renders as plain
// text rather than as a link to a guaranteed 404.
const prConflictsUrl = computed(() => conflictsUrl(props.prProvider, props.prUrl ?? ''))

// Provider-aware vocabulary: "pull request"/"PR"/"GitHub" on GitHub,
// "merge request"/"MR"/"GitLab" on GitLab.
const forge = computed(() => forgeWording(props.prProvider))
// Last GET /api/git/pr/status failure, parsed from the server's
// `{"error": ...}` body. Empty = unknown yet or last fetch worked.
// Shown inline (the status fetch is silent:true, so no toast) so a
// `gh` auth / bad-PR-number failure explains itself instead of just
// hiding the badge.
const prStatusError = ref('')
let prSeq = 0
let prPollTimer: number | undefined

// Which files the local three-way merge refuses to resolve. Fetched ONLY
// while `hasPrConflict` is true — a clean PR must cost zero extra spawns and
// must render byte-identically to before this feature existed.
// Three states, and the difference matters:
//   loaded=false            → not asked yet / never applicable
//   error='' + files.length → the answer
//   error!=''               → could not be determined (git < 2.38, base ref
//                             missing locally, repo not reachable); the UI says
//                             so rather than implying "nothing conflicts".
const prConflictLoaded = ref(false)
const prConflictFiles = ref<string[]>([])
const prConflictError = ref('')
const prConflictBase = ref('')
const prConflictTruncated = ref(false)
let prConflictSeq = 0
// The in-flight PR diff load, so loadPrConflicts can wait for the base/head
// it wants to reuse rather than racing that read to empty. Without it, a
// status response that beats a 1MB diff response silently downgrades the
// conflicts call from "these exact two refs" to the backend's ref ladder.
let prDiffInFlight: Promise<void> | null = null

// Restored from ?conflicts=1 on mount, so a reload or a shared link comes
// back showing only the conflicts. Guarded like readTabParam: hosts like
// ChatRightSidebar mount this panel without a router.
const conflictsOnly = ref(
  (() => {
    try {
      return readConflictsParam()
    } catch {
      // Same guard and same reason as initialTab: no router means
      // `route.query` throws, nothing was fetched, and there is no URL to
      // keep in sync. `false` = show the full PR file list, this panel's
      // pre-router default — logged rather than swallowed for the same
      // reason.
      console.warn('[SidebarDiffPanel] mounted without a router; defaulting ?conflicts to off')
      return false
    }
  })(),
)

const setConflictsOnly = (on: boolean) => {
  conflictsOnly.value = on
  syncConflictsParam(on)
}

// PR file list, narrowed to the conflicting ones when the filter is on.
// An empty filter result is a real state (the section says so) — never
// silently fall back to the full list, which would look like the filter
// did nothing.
const conflictPathSet = computed(() => new Set(prConflictFiles.value))
const visiblePrFiles = computed(() =>
  conflictsOnly.value
    ? prFiles.value.filter((f) => conflictPathSet.value.has(f.path))
    : prFiles.value,
)

// Clicking a conflicting file: if the PR diff has it, select it exactly like
// a normal row (the centre column then shows that file's hunks). A conflict
// on a file the PR diff does not carry (added on the base side, deleted
// here, …) has no hunks to show, so open it in the code editor instead —
// "nothing happens" would be the wrong answer for a file the user was just
// told is blocking their merge.
const onConflictFileClick = (path: string) => {
  const file = prFiles.value.find((f) => f.path === path)
  if (file) {
    selectPrFile(file)
    return
  }
  openFileInNewTab(path)
}

const prStatusIcon: Record<string, string> = { M: '📝', A: '➕', D: '🗑️', R: '🔄' }

// Extract the server's `{"error": "..."}` message from an ApiError
// (apiFetch throws ApiError with the raw body). Falls back to the
// generic Error message when the body isn't JSON — so callers always
// show WHY the backend failed instead of a canned string.
const serverErrorMessage = (err: unknown, fallback: string): string => {
  if (err instanceof api.ApiError && err.body) {
    try {
      const obj = JSON.parse(err.body) as { error?: unknown }
      if (obj && typeof obj.error === 'string' && obj.error.trim()) return obj.error
    } catch {
      /* non-JSON body — fall through to fallback */
    }
  }
  if (err instanceof Error && err.message) return err.message
  return fallback
}

// Right-click "Open file in new tab" for a file row. Position state +
// dismiss wiring live in useContextMenu; the row payload (file path)
// lives here so the menu emit can target it (ChatsList pattern).
const { menuPos, openAt, close: closeContextMenu } = useContextMenu()
const contextMenuPath = ref<string | null>(null)

const codeEditorQuery = (path: string): Record<string, string> => ({
  view: 'code-editor',
  file: path,
})

const openFileInNewTab = (path: string) => {
  // New tabs boot cold, so they resolve the cwd from the workspace
  // path context — keep the current path instead of dropping to /app.
  openInNewTab(router, { path: route.path, query: codeEditorQuery(path) })
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
    return forgeWording(props.prProvider).short
  }
})

// Badge text/color for the live merge state. Unknown state hides it.
const prStatusLabel = computed(() => {
  if (prStatus.value === 'merged') return 'Merged'
  if (prStatus.value === 'closed') return 'Closed'
  if (prStatus.value === 'open') return 'Open'
  return ''
})

const prStatusStyle = computed(() => {
  if (prStatus.value === 'merged')
    return { backgroundColor: 'var(--color-violet)', color: 'var(--color-bg)' }
  if (prStatus.value === 'closed')
    return { backgroundColor: 'var(--semantic-error)', color: 'var(--color-bg)' }
  return { backgroundColor: 'var(--color-green)', color: 'var(--color-bg)' }
})

const loadPrDiff = async () => {
  if (!props.cwd || !isPrMode.value) {
    prFiles.value = []
    return
  }
  isLoadingPr.value = true
  prError.value = null
  // Published so loadPrConflicts can wait for base/head instead of racing it
  // (see PR_IN_FLIGHT note there). Tab load runs diff + status in parallel;
  // serialising them would add a full diff round-trip to tab-open latency.
  const run = (async () => {
    try {
      const data = await api.getPrDiff(props.cwd, props.prUrl ?? '', {
        provider: props.prProvider || undefined,
      })
      prFiles.value = splitDiffByFile(data.diff_content)
      prBase.value = data.base || ''
      prHead.value = data.head || ''
      prTruncated.value = data.truncated
      // Stacked center view: every chunk parses synchronously — no
      // per-file fetch needed, the full diff text is already in hand.
      const list: DiffSelection[] = prFiles.value.map((file) => {
        const parsed = parseUnifiedDiff(file.text)
        return {
          path: file.path,
          staged: false,
          lines: parsed.lines,
          added: parsed.added,
          removed: parsed.removed,
        }
      })
      emit('show-diff-list', list)
    } catch (err) {
      console.error('Failed to load PR diff:', err)
      prError.value = serverErrorMessage(err, 'Failed to load PR diff')
      prFiles.value = []
    }
  })()
  prDiffInFlight = run
  try {
    await run
  } finally {
    if (prDiffInFlight === run) prDiffInFlight = null
    isLoadingPr.value = false
  }
}

// Merge-state sync: `gh pr view` via GET /api/git/pr/status. Runs
// alongside loadPrDiff on every PR-tab load and on a 30s poll while
// the PR tab is visible, so a GitHub merge flips the badge without
// a manual refresh. Status failures no longer vanish silently: the
// server's `error` body lands in prStatusError and renders inline,
// while the badge stays hidden (unknown state).
const loadPrStatus = async () => {
  if (!props.cwd || !isPrMode.value) {
    prStatus.value = ''
    prStatusTitle.value = ''
    prMergeable.value = ''
    prMergeState.value = ''
    prStatusError.value = ''
    return
  }
  const seq = ++prSeq
  try {
    const data = await api.getPrStatus(props.cwd, props.prUrl ?? '', {
      provider: props.prProvider || undefined,
    })
    if (seq !== prSeq) return
    prStatus.value = (data.status || data.state || '').toLowerCase()
    prStatusTitle.value = data.title || ''
    prMergeable.value = data.mergeable || ''
    prMergeState.value = data.merge_state || ''
    prStatusError.value = ''
    // The conflict badge just turned on or off — re-derive the file list in
    // the same turn so the section never lags the badge by a render.
    await loadPrConflicts()
  } catch (err) {
    if (seq !== prSeq) return
    prStatus.value = ''
    prStatusTitle.value = ''
    prMergeable.value = ''
    prMergeState.value = ''
    prStatusError.value = serverErrorMessage(err, 'Failed to load PR status')
    await loadPrConflicts()
  }
}

const retryPr = () => {
  void loadPrDiff()
  void loadPrStatus()
}

// Which files conflict, per `git merge-tree` on the local refs. Called
// right after loadPrStatus resolves a conflict, and again whenever the merge
// state flips — never speculatively, so the clean-PR path is unchanged.
const loadPrConflicts = async () => {
  if (!props.cwd || !isPrMode.value || !hasPrConflict.value) {
    // Clear too: the PR may have just been merged/rebased clean, and a stale
    // list under a badge that vanished would be a lie in the other direction.
    prConflictLoaded.value = false
    prConflictFiles.value = []
    prConflictError.value = ''
    prConflictBase.value = ''
    prConflictTruncated.value = false
    return
  }
  const seq = ++prConflictSeq
  // Wait for the diff load so base/head below are the exact refs the file
  // list above was computed from. loadPrDiff already renders its own error.
  const pendingDiff = prDiffInFlight
  if (pendingDiff) {
    try {
      await pendingDiff
    } catch {
      /* diff error is shown by the PR tab itself */
    }
    if (seq !== prConflictSeq) return
  }
  try {
    const data = await api.getPrConflicts(props.cwd, props.prUrl ?? '', {
      provider: props.prProvider || undefined,
      base: prBase.value || undefined,
      head: prHead.value || undefined,
    })
    if (seq !== prConflictSeq) return
    prConflictFiles.value = data.conflicting_files || []
    prConflictBase.value = data.base_ref || ''
    prConflictTruncated.value = !!data.truncated
    prConflictError.value = ''
    prConflictLoaded.value = true
  } catch (err) {
    if (seq !== prConflictSeq) return
    prConflictFiles.value = []
    prConflictBase.value = ''
    prConflictTruncated.value = false
    prConflictError.value = serverErrorMessage(err, 'Failed to compute conflicting files')
    prConflictLoaded.value = true
  }
}

// The forge says CONFLICTING but our local merge came back clean. Almost
// always a stale local base ref (we deliberately never `git fetch`). Showing
// an empty list next to a red badge would read as "nothing to do", so say so
// instead and point at the ref the answer was computed from.
const prConflictUnreproduced = computed(
  () => prConflictLoaded.value && !prConflictError.value && prConflictFiles.value.length === 0,
)

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
  void refreshCurrentTab()
}

const loadGitStatus = async () => {
  if (!props.cwd) {
    isGitRepo.value = false
    stagedFiles.value = []
    unstagedFiles.value = []
    untrackedFiles.value = []
    return
  }
  // Stale-response guard: rapid cwd flips (session → worktree A → B)
  // resolve out of order without this — the slower fetch wins and the
  // panel shows the wrong branch + file list.
  const seq = ++loadSeq
  const cwd = props.cwd
  isLoadingGit.value = true
  gitError.value = null
  try {
    const data = await api.getGitChanges(cwd)
    if (seq !== loadSeq) return
    isGitRepo.value = data.is_git_repo
    internalBranch.value = data.branch || ''
    if (data.is_git_repo) {
      stagedFiles.value = data.staged_files || []
      unstagedFiles.value = data.modified_files || []
      untrackedFiles.value = data.untracked_files || []
      await loadFullList(cwd)
    } else {
      stagedFiles.value = []
      unstagedFiles.value = []
      untrackedFiles.value = []
      emit('show-diff-list', [])
    }
  } catch (err) {
    if (seq !== loadSeq) return
    console.error('Failed to load git status:', err)
    isGitRepo.value = false
    gitError.value = 'Failed to load git status'
  } finally {
    if (seq === loadSeq) isLoadingGit.value = false
  }
}

// Stacked center view: fetch every changed file so the center column
// renders all diffs without per-click round-trips. Uses the batch
// endpoint (POST /git/file/diffs, <=2 git spawns) instead of N parallel
// GET /git/file/diff — the old fan-out held N Io workers for 6-10s each
// and starved cheap routes like queue_messages. Falls back to a
// concurrency-limited per-file fetch (pool of 4) on older servers.
const DIFF_BATCH_CONCURRENCY = 4
const loadFullList = async (cwd: string = props.cwd) => {
  if (!cwd) return
  const seq = loadSeq
  const targets: { path: string; staged: boolean }[] = [
    ...stagedFiles.value.map((f) => ({ path: f.path, staged: true })),
    ...unstagedFiles.value.map((f) => ({ path: f.path, staged: false })),
    ...untrackedFiles.value.map((f) => ({ path: f.path, staged: false })),
  ]
  if (targets.length === 0) {
    if (seq === loadSeq) emit('show-diff-list', [])
    return
  }
  const toSelection = (
    t: { path: string; staged: boolean },
    diff_content: string,
  ): DiffSelection => {
    const parsed = parseUnifiedDiff(diff_content)
    return {
      path: t.path,
      staged: t.staged,
      lines: parsed.lines,
      added: parsed.added,
      removed: parsed.removed,
    }
  }
  const toError = (t: { path: string; staged: boolean }): DiffSelection => ({
    path: t.path,
    staged: t.staged,
    lines: [],
    added: 0,
    removed: 0,
    error: 'Failed to load file diff',
  })
  try {
    const batch = await api.getGitFileDiffs(
      cwd,
      targets.map((t) => ({ file: t.path, staged: t.staged })),
    )
    if (seq !== loadSeq) return
    const byKey = new Map(batch.diffs.map((d) => [`${d.staged ? 1 : 0}:${d.path}`, d.diff_content]))
    const list: DiffSelection[] = targets.map((t) => {
      const content = byKey.get(`${t.staged ? 1 : 0}:${t.path}`)
      if (content !== undefined) return toSelection(t, content)
      return toError(t)
    })
    emit('show-diff-list', list)
    return
  } catch {
    // Older server without the batch route — fall through to limited fetch.
  }
  if (seq !== loadSeq) return
  const results: ({ status: 'fulfilled'; value: api.GitFileDiff } | { status: 'rejected' })[] =
    Array.from({ length: targets.length }) as (
      | {
          status: 'fulfilled'
          value: api.GitFileDiff
        }
      | { status: 'rejected' }
    )[]
  for (let i = 0; i < targets.length; i += DIFF_BATCH_CONCURRENCY) {
    if (seq !== loadSeq) return
    const chunk = targets.slice(i, i + DIFF_BATCH_CONCURRENCY)
    const settled = await Promise.allSettled(
      chunk.map((t) => api.getGitFileDiff(cwd, t.path, t.staged)),
    )
    settled.forEach((r, j) => {
      results[i + j] =
        r.status === 'fulfilled' ? { status: 'fulfilled', value: r.value } : { status: 'rejected' }
    })
  }
  if (seq !== loadSeq) return
  const list: DiffSelection[] = targets.map((t, i) => {
    const r = results[i]
    if (r && r.status === 'fulfilled') return toSelection(t, r.value.diff_content)
    return toError(t)
  })
  emit('show-diff-list', list)
}

// Per-tab lazy load: each side fetches once until cwd/prUrl changes.
// The commits tab needs no panel-level fetch — GitCommits.vue loads
// (and paginates) itself when it mounts, and so does PrChecksPanel.vue.
const loadTab = async (tab: 'files' | 'pr' | 'commits' | 'checks' | 'evals', force = false) => {
  if (!force && loadedTabs.value.has(tab)) return
  if (tab === 'pr') await Promise.all([loadPrDiff(), loadPrStatus()])
  else if (tab === 'files') await loadGitStatus()
  loadedTabs.value.add(tab)
}

// Current-tab reload for the sidebar ↻ path (ChatRightSidebar.refresh
// delegates here). Unlike loadGitStatus-only refresh, this also
// re-syncs PR merge state when the PR tab is visible.
const refreshCurrentTab = async () => {
  if (showPr.value) await loadTab('pr', true)
  else if (showCommits.value) await loadTab('commits', true)
  else if (showChecks.value) checksRef.value?.reload()
  else await loadTab('files', true)
}

const setActiveTab = (tab: 'files' | 'pr' | 'commits' | 'checks' | 'evals') => {
  activeTab.value = tab
  syncTabParam(tab)
  void loadTab(tab)
}

const loadDiff = async () => {
  // PR list parses inline (selectPrFile); a center retry there is a no-op.
  if (showPr.value) return
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

// Commit-history file click (GitCommits with inline-file-diff=false):
// fetch the file's unified diff at that commit and show it in ChatView's
// center column — the same show-diff flow as worktree/PR file rows.
// Rename rows carry "old -> new"; the diff is fetched for the new side.
const onCommitFileClick = async (payload: { commit: api.GitCommit; file: api.GitCommitFile }) => {
  if (!props.cwd) return
  const rawPath = payload.file.path
  const diffPath = rawPath.includes(' -> ') ? (rawPath.split(' -> ').pop() ?? rawPath) : rawPath
  selectedPath.value = diffPath
  selectedStaged.value = false
  try {
    const diff = await api.getGitCommitFileDiff(props.cwd, payload.commit.sha, diffPath)
    if (!diff) throw new Error('empty diff')
    const parsed = parseUnifiedDiff(diff.diff_content)
    emit('show-diff', {
      path: diffPath,
      staged: false,
      lines: parsed.lines,
      added: parsed.added,
      removed: parsed.removed,
    })
  } catch (err) {
    console.error('Failed to load commit file diff:', err)
    emit('show-diff', {
      path: diffPath,
      staged: false,
      lines: [],
      added: 0,
      removed: 0,
      error: 'Failed to load commit file diff',
    })
  }
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
  () => [props.cwd, props.prUrl] as const,
  ([, url], [, prevUrl]) => {
    const had = (prevUrl ?? '').trim().length > 0
    const has = (url ?? '').trim().length > 0
    if (had !== has) {
      if (has) activeTab.value = readTabParam() ?? 'pr'
      else if (activeTab.value === 'pr') {
        // Leaving PR mode drops back to files and clears the param;
        // a commits tab survives (it needs no PR).
        activeTab.value = 'files'
        syncTabParam(null)
      }
      // The conflicts-only filter is a PR-tab view, so it must not outlive
      // the PR it filtered — clear it and its query param with the binding.
      conflictsOnly.value = false
      syncConflictsParam(false)
      prConflictSeq++
      prConflictLoaded.value = false
      prConflictFiles.value = []
      prConflictError.value = ''
      prConflictBase.value = ''
      prConflictTruncated.value = false
    }
    selectedPath.value = null
    loadedTabs.value.clear()
    void loadTab(activeTab.value, true)
  },
)

onMounted(() => {
  void loadTab(activeTab.value, true)
  // Poll merge state while the PR tab is visible so a GitHub merge
  // flips the badge without a manual refresh. Status-only (cheap
  // `gh pr view`); the heavier diff refetches on explicit refresh.
  prPollTimer = window.setInterval(() => {
    if (showPr.value) void loadPrStatus()
  }, 30000)
})

onUnmounted(() => {
  if (prPollTimer !== undefined) window.clearInterval(prPollTimer)
})

defineExpose({
  loadGitStatus,
  loadPrDiff,
  loadPrStatus,
  loadPrConflicts,
  loadDiff,
  refresh: refreshCurrentTab,
  changeCount,
})
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="sidebar-diff-panel">
    <div
      v-if="showTabs || showEvals || showChecks || !isPrMode"
      class="flex items-center gap-1 px-3 h-9 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
      role="tablist"
    >
      <button
        v-if="isPrMode"
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-80"
        data-testid="sidebar-tab-files"
        role="tab"
        :aria-selected="activeTab === 'files'"
        :style="
          activeTab === 'files'
            ? {
                color: 'var(--semantic-text)',
                fontWeight: 600,
                boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
              }
            : { color: 'var(--semantic-text)', opacity: '0.6' }
        "
        @click="setActiveTab('files')"
      >
        Files changed{{ changeCount > 0 ? ` (${changeCount})` : '' }}
      </button>
      <button
        v-if="isPrMode"
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-80"
        data-testid="sidebar-tab-pr"
        role="tab"
        :aria-selected="activeTab === 'pr'"
        :style="
          activeTab === 'pr'
            ? {
                color: 'var(--semantic-text)',
                fontWeight: 600,
                boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
              }
            : { color: 'var(--semantic-text)', opacity: '0.6' }
        "
        @click="setActiveTab('pr')"
      >
        {{ forge.label }}{{ prFiles.length > 0 ? ` (${prFiles.length})` : '' }}
      </button>
      <button
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-80"
        data-testid="sidebar-tab-commits"
        role="tab"
        :aria-selected="activeTab === 'commits'"
        :style="
          activeTab === 'commits'
            ? {
                color: 'var(--semantic-text)',
                fontWeight: 600,
                boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
              }
            : { color: 'var(--semantic-text)', opacity: '0.6' }
        "
        @click="setActiveTab('commits')"
      >
        Commits
      </button>
      <button
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-80"
        data-testid="sidebar-tab-checks"
        role="tab"
        :aria-selected="activeTab === 'checks'"
        :style="
          activeTab === 'checks'
            ? {
                color: 'var(--semantic-text)',
                fontWeight: 600,
                boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
              }
            : { color: 'var(--semantic-text)', opacity: '0.6' }
        "
        @click="setActiveTab('checks')"
      >
        Checks
      </button>
      <button
        type="button"
        class="text-xs px-2 py-1 rounded hover:opacity-80"
        data-testid="sidebar-tab-evals"
        role="tab"
        :aria-selected="activeTab === 'evals'"
        :style="
          activeTab === 'evals'
            ? {
                color: 'var(--semantic-text)',
                fontWeight: 600,
                boxShadow: 'inset 0 -2px 0 0 var(--color-violet)',
              }
            : { color: 'var(--semantic-text)', opacity: '0.6' }
        "
        @click="setActiveTab('evals')"
      >
        Evals
      </button>
    </div>
    <div
      v-if="showPr"
      class="flex items-center gap-2 px-3 h-10 shrink-0"
      style="border-bottom: 1px solid var(--color-border)"
    >
      <span class="text-body">🔀</span>
      <a
        :href="prUrl"
        target="_blank"
        rel="noopener"
        class="text-body font-medium truncate flex-1 hover:underline"
        style="color: var(--semantic-text)"
        :title="prUrl"
        data-testid="sidebar-pr-link"
      >
        {{ prLabel }}
      </a>
      <span
        v-if="prStatusLabel"
        class="px-1.5 py-0.5 rounded text-dense font-medium shrink-0"
        :style="prStatusStyle"
        :title="prStatusTitle || prStatusLabel"
        data-testid="sidebar-pr-status"
      >
        {{ prStatusLabel }}
      </span>
      <span
        v-if="hasPrConflict"
        class="px-1.5 py-0.5 rounded text-dense font-medium shrink-0"
        style="background-color: var(--semantic-error); color: var(--color-bg)"
        :title="
          prConflictFiles.length > 0
            ? `This ${forge.noun} has merge conflicts in ${prConflictFiles.length} file(s)`
            : `This ${forge.noun} has merge conflicts that must be resolved`
        "
        data-testid="sidebar-pr-conflict-badge"
      >
        ⚠ Merge conflicts<span v-if="prConflictFiles.length > 0">
          ({{ prConflictFiles.length }})</span
        >
      </span>
      <span
        v-if="prBase || prHead"
        class="text-dense truncate"
        style="color: var(--semantic-text-dim)"
        :title="`${prBase}...${prHead}`"
      >
        {{ prBase }}…{{ prHead }}
      </span>
      <span
        v-if="prFiles.length > 0"
        class="px-1.5 py-0.5 rounded text-dense font-medium"
        style="background-color: var(--color-violet); color: var(--color-bg)"
        data-testid="sidebar-pr-count"
      >
        {{ prFiles.length }}
      </span>
      <button
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        :title="`Refresh ${forge.short} diff`"
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
      <span class="text-body">🌿</span>
      <span
        class="text-body font-medium truncate flex-1"
        style="color: var(--semantic-text)"
        data-testid="sidebar-diff-branch"
      >
        {{ displayBranch || 'Git' }}
      </span>
      <span
        v-if="changeCount > 0"
        class="px-1.5 py-0.5 rounded text-dense font-medium"
        style="background-color: var(--color-orange); color: var(--color-bg)"
        data-testid="sidebar-diff-count"
      >
        {{ changeCount }}
      </span>
      <button
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        :title="showCommits ? 'Show changed files' : 'Show commit history'"
        data-testid="sidebar-diff-commits-toggle"
        @click="setActiveTab(showCommits ? 'files' : 'commits')"
      >
        {{ showCommits ? 'Files' : 'Commits' }}
      </button>
      <button
        type="button"
        class="text-dense px-2 py-1 rounded hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Refresh git status"
        data-testid="sidebar-diff-refresh"
        @click="onRefreshClick"
      >
        ↻
      </button>
    </div>

    <div v-if="showChecks" class="flex-1 min-h-0">
      <PrChecksPanel ref="checksRef" :cwd="cwd" :pr-url="prUrl" :pr-provider="prProvider" />
    </div>
    <div v-else-if="showEvals" class="flex-1 min-h-0">
      <SkillEvalsPanel :session-id="sessionId" />
    </div>
    <div v-else-if="showCommits && !showPr" class="flex-1 min-h-0">
      <GitCommits :cwd="cwd" :inline-file-diff="false" @commit-file-click="onCommitFileClick" />
    </div>
    <div v-else class="flex-1 overflow-y-auto min-h-0">
      <template v-if="showPr">
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
        <div v-else-if="prError" class="flex flex-col items-center justify-center p-4 text-center">
          <span class="text-title-lg mb-2">⚠️</span>
          <p
            class="text-dense break-words"
            style="color: var(--semantic-error); white-space: pre-wrap"
            data-testid="sidebar-pr-error"
          >
            {{ prError }}
          </p>
          <button
            type="button"
            class="mt-3 px-3 py-1.5 text-body rounded"
            style="background: var(--color-green); color: var(--color-bg)"
            data-testid="sidebar-pr-retry"
            @click="retryPr"
          >
            Retry
          </button>
        </div>
        <div
          v-else-if="prFiles.length === 0"
          class="flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-display mb-3">🔀</span>
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            No {{ forge.short }} changes found
          </p>
          <p
            v-if="prStatusError"
            class="text-dense break-words mt-2"
            style="color: var(--semantic-error); white-space: pre-wrap"
            :title="prStatusError"
            data-testid="sidebar-pr-status-error"
          >
            {{ forge.short }} status unavailable — {{ prStatusError }}
          </p>
        </div>
        <template v-else>
          <div
            v-if="hasPrConflict"
            class="mx-3 mt-2 px-2 py-1.5 rounded text-dense"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            data-testid="sidebar-pr-conflict-notice"
          >
            ⚠ This branch has conflicts that must be resolved. Use the
            <a
              v-if="prConflictsUrl"
              :href="prConflictsUrl"
              target="_blank"
              rel="noopener"
              class="hover:underline"
              >web editor</a
            ><span v-else>web editor</span>
            or the command line to resolve conflicts before continuing.
          </div>
          <!-- Which files, not just "there is a conflict". Computed locally by
               `git merge-tree` over the same base ref the PR diff used, so it
               works for GitHub, GitLab and generic providers alike. Rendered
               only under the badge above, so a clean PR is byte-identical to
               before this feature existed. -->
          <div
            v-if="
              hasPrConflict && prConflictLoaded && !prConflictError && prConflictFiles.length > 0
            "
            data-testid="sidebar-pr-conflict-files"
          >
            <div class="flex items-center gap-2 px-3 pt-2 pb-1">
              <span class="text-dense font-semibold" style="color: var(--semantic-error)">
                Conflicting files ({{ prConflictFiles.length }})
              </span>
              <button
                type="button"
                class="text-dense px-1.5 py-0.5 rounded hover:opacity-80 shrink-0"
                :style="
                  conflictsOnly
                    ? { backgroundColor: 'var(--color-violet)', color: 'var(--color-bg)' }
                    : { color: 'var(--semantic-text-dim)' }
                "
                :aria-pressed="conflictsOnly"
                :title="conflictsOnly ? 'Show all changed files' : 'Show only conflicting files'"
                data-testid="sidebar-pr-conflicts-only"
                @click="setConflictsOnly(!conflictsOnly)"
              >
                {{ conflictsOnly ? '⚠ Conflicts only ✓' : '⚠ Conflicts only' }}
              </button>
            </div>
            <div
              v-for="path in prConflictFiles"
              :key="'pr-conflict-' + path"
              class="flex items-center gap-2 px-3 py-1 cursor-pointer hover:opacity-80"
              :style="{
                backgroundColor:
                  selectedPath === path ? 'var(--semantic-active-bg)' : 'transparent',
              }"
              :data-testid="`sidebar-pr-conflict-file-${path}`"
              :title="path"
              @click="onConflictFileClick(path)"
              @contextmenu.prevent="onFileRowContextMenu($event, path)"
            >
              <span class="text-dense">⚠</span>
              <span class="text-dense truncate flex-1" style="color: var(--semantic-text)">
                {{ path }}
              </span>
            </div>
            <div
              v-if="prConflictTruncated"
              class="px-3 py-1 text-dense"
              style="color: var(--semantic-text-dim)"
              data-testid="sidebar-pr-conflict-files-truncated"
            >
              List truncated — some conflicting files are not shown
            </div>
            <div
              v-if="prConflictBase"
              class="px-3 py-1 text-dense"
              style="color: var(--semantic-text-dim)"
              data-testid="sidebar-pr-conflict-base"
            >
              Computed from your local {{ prConflictBase }}
            </div>
          </div>
          <!-- Forge says CONFLICTING, our local merge says clean. Almost
               always a stale local base ref — say so instead of showing an
               empty list beside a red badge. -->
          <div
            v-if="prConflictUnreproduced"
            class="mx-3 mt-2 px-2 py-1.5 rounded text-dense"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            data-testid="sidebar-pr-conflict-unreproduced"
          >
            Could not reproduce these conflicts locally<span v-if="prConflictBase">
              from {{ prConflictBase }}</span
            >. Run <code>git fetch</code> and refresh — the forge may be comparing against a newer
            base branch.
          </div>
          <div
            v-else-if="hasPrConflict && prConflictError"
            class="mx-3 mt-2 px-2 py-1.5 rounded text-dense break-words"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
              white-space: pre-wrap;
            "
            :title="prConflictError"
            data-testid="sidebar-pr-conflict-error"
          >
            Could not list conflicting files — {{ prConflictError }}
          </div>
          <div
            v-if="!prStatusLabel && prStatusError"
            class="mx-3 mt-2 px-2 py-1.5 rounded text-dense break-words"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
              white-space: pre-wrap;
            "
            :title="prStatusError"
            data-testid="sidebar-pr-status-error"
          >
            {{ forge.short }} status unavailable — {{ prStatusError }}
          </div>
          <div
            v-if="prStatus === 'merged'"
            class="mx-3 mt-2 px-2 py-1.5 rounded text-dense"
            style="
              background-color: color-mix(in srgb, var(--color-violet) 15%, transparent);
              color: var(--semantic-text);
            "
            data-testid="sidebar-pr-merged-notice"
          >
            Merged — this {{ forge.short }} was merged on {{ forge.forge }}. The diff below is the
            final state.
          </div>
          <div
            v-else-if="prStatus === 'closed'"
            class="mx-3 mt-2 px-2 py-1.5 rounded text-dense"
            style="
              background-color: color-mix(in srgb, var(--semantic-error) 12%, transparent);
              color: var(--semantic-text);
            "
            data-testid="sidebar-pr-closed-notice"
          >
            Closed — this {{ forge.short }} was closed on {{ forge.forge }} without merging.
          </div>
          <div
            v-if="prTruncated"
            class="px-3 py-1 text-dense"
            style="color: var(--semantic-text-dim)"
          >
            Diff truncated at 1MB — showing first files
          </div>
          <div class="py-1">
            <div class="px-3 py-1 text-dense font-semibold" style="color: var(--color-violet)">
              {{ forge.short }} files ({{ visiblePrFiles.length
              }}<template v-if="conflictsOnly"> of {{ prFiles.length }}</template
              >)
            </div>
            <div
              v-for="file in visiblePrFiles"
              :key="'pr-' + file.path"
              class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:opacity-80"
              :style="{
                backgroundColor:
                  selectedPath === file.path ? 'var(--semantic-active-bg)' : 'transparent',
              }"
              :data-testid="`sidebar-pr-file-${file.path}`"
              @click="onPrFileRowClick($event, file)"
              @contextmenu.prevent="onFileRowContextMenu($event, file.path)"
              @auxclick="onFileRowAuxClick($event, file.path)"
            >
              <span class="text-dense">{{ prStatusIcon[file.status] ?? '📄' }}</span>
              <span
                class="text-dense truncate flex-1"
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
          <span class="text-title-lg mb-2">⚠️</span>
          <p class="text-dense" style="color: var(--semantic-error)">{{ gitError }}</p>
          <button
            type="button"
            class="mt-3 px-3 py-1.5 text-body rounded"
            style="background: var(--color-green); color: var(--color-bg)"
            data-testid="sidebar-diff-retry"
            @click="loadGitStatus"
          >
            Retry
          </button>
        </div>

        <div
          v-else-if="!isGitRepo"
          class="flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-display mb-3">🌿</span>
          <p class="text-dense" style="color: var(--semantic-text-dim)">
            {{ !cwd ? 'Select a workspace to view git status' : 'Not a git repository' }}
          </p>
        </div>

        <div
          v-else-if="changeCount === 0"
          class="flex flex-col items-center justify-center p-4 text-center"
        >
          <span class="text-display mb-3">✓</span>
          <p class="text-dense" style="color: var(--semantic-text-dim)">Working tree clean</p>
        </div>

        <template v-else>
          <div v-if="stagedFiles.length > 0" class="py-1">
            <div class="px-3 py-1 text-dense font-semibold" style="color: var(--color-green)">
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
              <span class="text-dense">{{ displayStatus(file).icon }}</span>
              <span
                class="text-dense truncate flex-1"
                style="color: var(--semantic-text)"
                :title="file.path"
              >
                {{ file.path }}
              </span>
              <button
                type="button"
                class="text-dense px-1 rounded hover:opacity-70"
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
            <div class="px-3 py-1 text-dense font-semibold" style="color: var(--color-orange)">
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
              <span class="text-dense">{{ displayStatus(file).icon }}</span>
              <span
                class="text-dense truncate flex-1"
                style="color: var(--semantic-text)"
                :title="file.path"
              >
                {{ file.path }}
              </span>
              <button
                type="button"
                class="text-dense px-1 rounded hover:opacity-70"
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
            <div class="px-3 py-1 text-dense font-semibold" style="color: var(--semantic-text-dim)">
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
              <span class="text-dense">❓</span>
              <span
                class="text-dense truncate flex-1"
                style="color: var(--semantic-text)"
                :title="file.path"
              >
                {{ file.path }}
              </span>
              <button
                type="button"
                class="text-dense px-1 rounded hover:opacity-70"
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

<!--
  KanbanTaskDetailDialog — focused, edit-in-place task detail view.

  Layout (top → bottom):
    1. Header — "Task details" title + close button.
    2. Task name — large, editable input. Full width.
    3. Metadata strip (read-only) — column name, task type, pinned
       indicator, timestamps. Hidden when no metadata is available.
    4. Description label.
    5. Description textarea — large (rows=10 vs AddTaskDialog's 3),
       full width, monospace-friendly font (matches the existing
       AddTaskDialog / AddKanbanDialog description textarea).
    6. Save / Cancel buttons at the bottom right. Save is disabled
       when the form is clean (no changes) or the name is empty
       after trim.

  Unattended-mode toggle (edit mode only, below the description):
    A right-aligned switch that flips the session's
    `is_auto_retry_until_stop` flag (which lives on the sessions
    table, not workspace_item_tasks, so the host must call
    `api.updateSession` to persist it). The flag persists IMMEDIATELY
    on flip — independent of the Save button — matching iOS-style
    toggle UX (a switch should not need an explicit Save click to
    take effect). On toggle, the dialog emits `update-unattended`
    with the new value ('0' or '1') and the host persists via
    `api.updateSession(task.id, { isAutoRetryUntilStop })`. On
    toggle failure, the dialog rolls back its local state to the
    previous value (passed back via `update-unattended-error`) and
    shows a short-lived errorMessage.

  ▶ Start agent button (edit mode only, in the actions row):
    Outlined secondary button between Cancel and Save. Mirrors the
    create-mode ▶ Create task & run agent button. Clicking triggers
    the LLM worker on the existing session via the new
    POST /api/.../tasks/:task_id/start_agent endpoint — no
    queue_message is sent. Disabled when a worker is already
    running for this task's session (the frontend's best-effort
    check; the backend's atomic DB lookup is the source of truth).
    Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md

  Public API:
    props:
      show          boolean
      mode          'edit' | 'create'  (default: 'edit')
      task          Task | null
                              edit mode: required (the task to edit)
                              create mode: ignored — form starts empty
      column        KanbanColumn | null  (optional — shown in metadata strip;
                              required in create mode so the parent knows
                              where to place the new task)
      errorMessage  string | null  (optional — shows a red banner in the
                              body when set; typically bound to a save
                              handler's catch-block error)
    emits:
      close      []
      save       [{ mode: 'edit', name, description }]
                Emitted when the user clicks Save in edit mode. The host
                calls workspacesStore.updateTaskDetails(...) and closes
                the dialog on success.
      create     [{ mode: 'create', name, description }]
                Emitted when the user clicks Create task in create mode.
                The host calls workspacesStore.addTask(...) +
                moveTaskToColumn(...) to persist the new task.
      update-unattended     [{ value: '0' | '1' }]
                Emitted in edit mode when the user flips the
                unattended-mode toggle. Host persists via
                `api.updateSession(task.id, { isAutoRetryUntilStop })`.
      update-unattended-error  [{ value: '0' | '1', error: Error }]
                Optional: if the host wants the dialog to roll back to
                a known-good value on PUT failure, it can re-bind the
                prop / emit back through the same component (we do not
                handle rollback internally — the host owns it).

  This dialog is purely presentational — no API calls, no store
  reads. The host (AppLayout / KanbanView) owns the "open + for which
  task / in which column" state and wires the emits to store actions.

  Pattern source: KanbanSettingsDialog.vue — Teleport to body,
  max-height 70vh, transition + backdrop, semantic CSS variables
  for theme compatibility.
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick, onMounted, onUnmounted, inject } from 'vue'
import type { Task, KanbanColumn } from '../../stores/workspaces'
import { useKanbanTagSuggestions } from '../../composables/useKanbanTagSuggestions'
import KanbanDescriptionEditor from './KanbanDescriptionEditor.vue'
import type { PreviewFile } from '../file/FilePreview.vue'
import KanbanTagsInput from './KanbanTagsInput.vue'
import FilePreviewModal from './FilePreviewModal.vue'
import * as api from '../../api'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import FilePickerDialog from '../FilePickerDialog.vue'

const props = withDefaults(
  defineProps<{
    show: boolean
    mode?: 'edit' | 'create'
    task: Task | null
    column?: KanbanColumn | null  // optional — shown in metadata strip
    errorMessage?: string | null  // optional — red banner in body
    // Absolute path used as the root for the `@`-trigger file picker
    // in <KanbanDescriptionEditor>. Falls back to '' (no picker
    // results) for legacy kanbans that don't have a path set.
    cwd?: string
    // NEW (plan: kanban-task-tags-autocomplete.md, Task 2.7):
    // Workspace id required by the tag-suggestions composable.
    // Empty string = no fetch attempted (legacy callers + tests
    // that don't care about suggestions).
    workspaceId?: string
    // NEW (plan: 2026-08-06-kanban-add-task-button-placement). The
    // available columns for the create-mode column dropdown. Empty
    // array = no dropdown rendered (legacy callers, edit mode, or
    // kanbans that haven't loaded columns yet). Edit mode passes
    // empty. The host (KanbanView) passes `sortedColumns` from the
    // active kanban.
    availableColumns?: KanbanColumn[]
  }>(),
  {
    mode: 'edit',
    column: null,
    errorMessage: null,
    cwd: '',
    workspaceId: '',
    availableColumns: (): KanbanColumn[] => [],
  },
)

// ─── Tag suggestions composable (Task 2.7) ─────────────────────────────
// Lazily fetches distinct tags from other tasks on this kanban for
// the autocomplete dropdown in <KanbanTagsInput>. The composable's
// internal `loaded`/`hasMore`/`loading` refs drive the dropdown
// gating — calls to ensureLoaded() on dialog open, and loadNextPage()
// from the IntersectionObserver on the input's scroll sentinel.
// The composable handles empty workspaceId / empty itemId gracefully
// (no fetch attempted), so we can pass the fallbacks unconditionally
// without conditional wiring. We source the item id from the column
// prop (which carries the parent kanban's workspace_item_id) —
// Task itself doesn't carry workspace_item_id, but every active task
// in the kanban is reachable via column.workspace_item_id. Pass
// refs (not raw strings) so the composable can react when the
// column becomes available — earlier we passed raw strings and
// the composable was permanently bound to empty IDs when the
// dialog opened before column was resolved.
const tagSuggestions = useKanbanTagSuggestions(
  computed(() => props.workspaceId ?? ''),
  computed(() => props.column?.workspace_item_id ?? ''),
)

const emit = defineEmits<{
  // v-model:show two-way binding — emits `false` when the dialog
  // wants to close (X button, Cancel button, backdrop click, Escape
  // key). Parent uses `v-model:show` so this is what makes the
  // dialog actually close.
  'update:show': [value: boolean]
  // Explicit close event for parents that bind `:show` (one-way)
  // and listen for `@close` to flip their own ref. Kept for
  // backward compatibility with the existing test suite and for
  // the KanbanSettingsDialog-style pattern.
  close: []
  save: [payload: { mode: 'edit'; name: string; description: string; tags: string[] }]
  // Create-mode counterpart. Host wires this to workspacesStore.addTask
  // + moveTaskToColumn. Same payload shape as `save` but with
  // mode='create' so the parent handler can switch on it.
  create: [
    payload: {
      mode: 'create'
      name: string
      description: string
      // Auto-retry-until-stop (Option A): the toggle's live value
      // at the moment of Create. `'0'` (default — feature off)
      // is forwarded too so the host can pass it through to
      // api.createTask; the helper filters out `'0'` so the backend
      // only inserts a sessions row when the user actually opted in.
      is_auto_retry_until_stop: '0' | '1'
      // NEW (kanban task tags, Migration 067): array of free-form
      // tag strings. Empty array = no tags. Host forwards via
      // api.createTask's `tags` param; backend validates + persists.
      tags: string[]
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). Selected
      // profile-model name (empty string = backend default / top-level
      // config). Forwarded to the host for both `create` and
      // `create-and-run`; Path A only threads it through to the
      // backend when the user clicks "Create task & run agent".
      selectedProfile: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Files the
      // dialog's editor staged in create mode (no base64 ever written
      // into `description`). Always present — empty array when no
      // images were pasted/picked. Host uploads each via
      // `api.uploadTaskAttachment(taskId, file)` AFTER addTask
      // returns the new taskId, then patches the description with
      // `![name](<url>)` markdown via `updateTaskDetails`.
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      // Per-task cwd override. Absolute path on disk or '' for
      // cwd-less. Empty string is the canonical "no per-task cwd"
      // sentinel — the backend stores '' and the session_create
      // 3-level fallback chain falls back to the kanban's path +
      // the per-session sandbox. The dialog's folder picker
      // (NEW) populates this field; skipped / picker-canceled
      // leaves it as ''. Plan:
      // docs/superpowers/plans/2026-08-06-kanban-cwd-session-optional.md
      cwdSession?: string
    },
  ]
  // Emitted in edit mode when the user flips the unattended toggle.
  // The host persists via api.updateSession(task.id, { isAutoRetryUntilStop }).
  // value is '1' when toggled ON, '0' when toggled OFF. Emitted
  // BEFORE the optimistic UI flip so the host can capture the
  // pre-toggle value (in case it needs to roll back on PUT failure).
  'update-unattended': [payload: { value: '0' | '1'; previous: '0' | '1' }]
  // NEW (plan: 2026-08-06-kanban-create-task-run-agent). Emitted
  // when the user clicks "Create task & run agent" in create mode.
  // Same payload shape as `create` but with mode='create_and_run'
  // so the host can branch on it. The host (KanbanView) handles
  // the create + move + run + navigate dance.
  'create-and-run': [
    payload: {
      mode: 'create_and_run'
      name: string
      description: string
      is_auto_retry_until_stop: '0' | '1'
      tags: string[]
      // NEW (plan: 2026-08-06-kanban-task-profile-selector). See
      // note on the `create` emit above. Threaded through to
      // runAgentOnNewTask so the agent runs with the chosen
      // profile.
      selectedProfile: string
      // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Mirror of
      // the `pendingFiles` field on the `create` emit above.
      pendingFiles: PreviewFile[]
      // NEW (Migration 070 — kanban-cwd-session-optional plan).
      // Mirror of the `cwdSession` field on the `create` emit
      // above. The dialog's folder picker populates this in both
      // create and create-and-run modes; the host threads it into
      // runAgentOnNewTask's `cwd` (overriding the kanban-level path
      // + sandbox fallback).
      cwdSession?: string
    },
  ]
  // NEW (plan: 2026-08-06-kanban-add-task-button-placement). Create
  // mode only. Fires when the user picks a different column from the
  // create-mode dropdown. The parent (KanbanView) updates its
  // `activeCreateColumnId` so the final `moveTaskToColumn` on submit
  // puts the new task in the chosen column. Edit mode does not emit
  // this event — the task is already in a column, and migrating an
  // existing task to a new column is out of scope.
  'column-change': [columnId: string]
  // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Edit mode
  // only. Fires when the user picks a different cwd from the picker
  // in edit mode. The host persists immediately via
  // `api.updateTaskSimple(task.id, { cwd })`, matching the
  // `update-unattended` immediate-save UX (iOS-style — no Save click
  // required). In create mode the cwd selection is forwarded via the
  // `create` / `create-and-run` emit's `cwdSession` field instead, so
  // this emit is only meaningful in edit mode.
  'update-cwd': [payload: { cwd: string }]
  // NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Edit
  // mode only. Fires when the user clicks the ▶ Start agent
  // button. The host calls `workspacesStore.startAgentOnTask(...)`
  // which POSTs to the new backend endpoint; the agent runs on the
  // existing chat history without queueing a new user message.
  // The button is `:disabled` while `processingState[task.id]`
  // is true, so this emit only fires when no worker is in flight.
  'start-agent': [payload: { taskId: string }]
}>()

// ─── Form state ──────────────────────────────────────────────────────────

const name = ref('')
const description = ref('')
const unattended = ref<'0' | '1'>('0')
const tags = ref<string[]>([])
// Template ref for the chip input — handleSave calls commitDraft()
// imperatively before reading `tags.value` so a draft tag typed but
// not yet committed (Enter/comma not pressed) isn't dropped on Save.
// The component's @blur handler covers the normal case; this is the
// explicit "click Save without leaving the field" safety net.
const tagsInputRef = ref<{ commitDraft: () => void } | null>(null)
// Template ref for the description editor — used in CREATE MODE to
// read the staged image files (pendingFiles) so the dialog can hand
// them to the host's create-then-upload orchestrator. The editor
// exposes pendingFiles via defineExpose; see
// KanbanDescriptionEditor.vue for the contract.
const descriptionEditorRef = ref<{ pendingFiles: PreviewFile[] } | null>(null)
const nameInput = ref<HTMLInputElement | null>(null)
const DESCRIPTION_MAX = 5000
// The description is ALWAYS shown as the editor (textarea + paperclip +
// char counter). A "Preview" toggle used to flip to <MarkdownDescription>
// for a rendered view, but the toggle was removed per user feedback —
// the dialog stays focused on the editor. Image/file-paths in the
// description still render correctly when the task is viewed elsewhere
// (e.g. <WorkspaceItemTaskCard> on the kanban board, the chat view's
// task description render).
//
// (plan: 2026-08-06-kanban-no-base64-in-desc) — see also.

// NEW (plan: 2026-08-06-kanban-task-profile-selector). Profile-model
// picker state (create mode only). selectedProfile='' = backend
// default / "Default (top-level config)". Loaded from LlmConfig
// profiles; mirrors ChatView's picker pattern.
interface ProfileEntry {
  name: string
  model: string
  base_url: string
}
const selectedProfile = ref('')
const isProfilePickerOpen = ref(false)
const profilePickerRef = ref<HTMLElement | null>(null)
const availableProfiles = ref<ProfileEntry[]>([])
const profilesLoading = ref(false)

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Column
// dropdown state (create mode only). selectedColumnId mirrors the
// parent's `column` prop on dialog open; the picker emits
// `column-change` so the host updates its activeCreateColumnId in
// real-time. Click outside the picker closes it (mirrors the profile
// picker behaviour).
const selectedColumnId = ref<string | null>(props.column?.id ?? null)
const isColumnPickerOpen = ref(false)
const columnPickerRef = ref<HTMLElement | null>(null)
const toggleColumnPicker = () => {
  isColumnPickerOpen.value = !isColumnPickerOpen.value
}
const selectColumn = (id: string) => {
  selectedColumnId.value = id
  isColumnPickerOpen.value = false
  emit('column-change', id)
}

// NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task
// cwd picker state (create mode only). Default: when the parent
// kanban has a path, pre-populate the picker with that path (the
// kanban's project root becomes the new task's per-task cwd by
// default; the user can change or skip). When the parent kanban is
// cwd-less, the picker starts empty.
//
// `cwdSession` is the per-task cwd we emit to the parent. Empty
// string = "no per-task cwd" (falls back to kanban-level path +
// sandbox). The picker writes the absolute path; the picker dialog's
// "cancel" / backdrop-close leaves it empty.
//
// Starts empty — populated lazily by the broader
// `props.show, props.task?.id, props.mode` watcher below on dialog
// open (with `immediate: true`). Initializing from the ref literal
// (`ref<string>(props.cwd ?? '')`) used to work, but broke when the
// parent re-mounted the dialog with a different cwd (the ref would
// keep its first-mount value). The watcher handles BOTH initial
// mount AND re-mount correctly. Plan:
// docs/superpowers/plans/2026-08-14-kanban-task-detail-edit-cwd.md
const cwdSession = ref<string>('')
const isCwdPickerOpen = ref(false)
const cwdPickerRef = ref<HTMLElement | null>(null)
// Pre-populate from the parent kanban's `cwd` prop on dialog open.
// The parent (KanbanView) passes the kanban's `path` (kanban-level
// cwd) as this prop — when set, the new task's per-task cwd defaults
// to it (the user can change or skip). When the parent kanban is
// cwd-less, the picker starts empty.
//
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd): in edit
// mode, pre-populate from `props.task?.cwd` instead — the task's
// persisted per-task cwd takes precedence over the kanban-level
// fallback so the picker reflects "where does THIS task run"
// rather than the kanban's project root.
//
// Initialized from the prop (NOT via the watcher below) so the picker
// has the right value on the very first render — without the
// initial-value read, the watcher needed `show` to flip false→true to
// fire, which leaves the picker empty if the parent mounts the dialog
// with `show=true` on the first tick (same pattern as
// `selectedColumnId` above, which also initializes from its prop).
//
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Edit mode
// initializer: when the dialog opens in edit mode, sync `cwdSession`
// from the task's persisted `cwd` field (empty string for
// cwd-less tasks, path for tasks with a per-task cwd set). Mirrors
// the create-mode pre-population from `props.cwd` (the parent
// kanban's path). Without this branch the picker would render the
// empty-state placeholder on every edit-mode dialog open, making
// "where does this task run?" an unanswerable question until the user
// clicked the picker.
//
// Implementation note: the broader watcher below
// (`props.show, props.task?.id, props.mode` with `immediate: true`)
// handles the initial sync AND the rare "user clicks task A then
// task B with the dialog already open" re-sync — cwd re-syncs
// whenever show flips true OR the target task swaps.
// This dedicated `props.show`-only watcher remains here for
// defensiveness (the broader watcher runs on the same tick as
// the dialog mount; the explicit show-watcher documents intent).
watch(
  () => props.show,
  (show) => {
    if (!show) return
    if (isCreateMode.value) {
      cwdSession.value = props.cwd ?? ''
    } else {
      // `task?.cwd ?? ''` coerces legacy tasks whose `cwd` field is
      // `undefined` (predates Migration 070) to the empty-state
      // placeholder, matching what the read-only strip showed
      // before this fix.
      cwdSession.value = props.task?.cwd ?? ''
    }
  },
)
const toggleCwdPicker = () => {
  isCwdPickerOpen.value = !isCwdPickerOpen.value
}
// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). In edit mode
// the picker fires `update-cwd` so the host persists immediately
// (same iOS-style immediate-save UX as the unattended toggle). In
// create mode the cwd selection is captured in `cwdSession` and
// forwarded via the `create` / `create-and-run` emit's
// `cwdSession` field on Save — `update-cwd` is a no-op there
// because the task doesn't exist yet (no row to PATCH).
const selectCwd = (path: string) => {
  cwdSession.value = path
  isCwdPickerOpen.value = false
  if (!isCreateMode.value) {
    emit('update-cwd', { cwd: path })
  }
}
const handleDocumentClickCwd = (event: MouseEvent) => {
  if (!isCwdPickerOpen.value) return
  const target = event.target as Node | null
  if (
    cwdPickerRef.value &&
    target &&
    // Allow the FilePickerDialog dropdown contents to escape the
    // ref's containment check. The picker teleports to <body> so
    // it isn't a DOM descendant of cwdPickerRef — without this
    // allow-list, any click inside the picker (including the Browse
    // tab and the search input) closes the dropdown immediately,
    // forcing the user to re-click the picker trigger to reopen
    // it. Plan: docs/superpowers/plans/2026-08-14-kanban-task-detail-edit-cwd.md
    !cwdPickerRef.value.contains(target) &&
    // Walk up from the click target to see if any ancestor is the
    // teleported FilePickerDialog root. The dialog root carries the
    // `data-testid="file-picker-dialog"` testid, so we can match it
    // (and its Teleport-portal descendants) without touching the
    // picker ref.
    !(target as Element | null)?.closest?.('[data-testid="file-picker-dialog"]')
  ) {
    // User intent: clicking outside the picker should NOT close it
    // by accident — the picker has explicit Cancel and Select affordances
    // for closing. The legacy close-on-outside-click behaviour caught
    // false positives every time the user clicked on the kanban column
    // body, another card, the dialog backdrop, etc. while the picker
    // was open (e.g. moving the mouse over to read context), forcing
    // them to reopen it. The new contract: once open, the picker stays
    // open until the user clicks the picker trigger again, selects a
    // folder, or presses Cancel/Select inside the FilePickerDialog.
    // (Backdrop click on the KanbanTaskDetailDialog itself still closes
    // the whole dialog, but that's a different handler at the dialog
    // root — see `@click.self="handleClose"` on the modal container.)
    // Plan: docs/superpowers/plans/2026-08-14-kanban-task-detail-edit-cwd.md
    return // no-op: explicitly do NOT close the picker on outside click
  }
}

// NEW (plan: 2026-08-06-kanban-folder-picker-style). Computed
// style object for the cwd picker button. The previous version used
// a static `style="..."` attribute with template expressions
// (`cwdSession ? ... : ...`) inline — Vue does NOT evaluate
// expressions inside static style attributes, so the resulting CSS
// was syntactically invalid and the browser silently dropped the
// `color` and `background-color` properties. The picker looked
// identical regardless of whether cwd was set. This computed is
// the proper `:style` binding so the conditional resolves correctly
// at render time. When cwd is set: bright text on the active-bg
// (clearly reads as "you picked something"). When cwd is empty:
// dim text on the sidebar-bg (clearly reads as "skip / optional").
const cwdPickerStyle = computed<Record<string, string>>(() => ({
  backgroundColor: cwdSession.value
    ? 'var(--semantic-active-bg)'
    : 'var(--semantic-sidebar-bg)',
  border: '1px solid var(--color-border)',
  color: cwdSession.value
    ? 'var(--semantic-text)'
    : 'var(--semantic-text-dim)',
}))
// FilePickerDialog data adapter — same `path: string => Promise<T[]>`
// contract used by AddKanbanDialog. Mirrors its loadItemsForPicker
// helper (kept duplicated, not extracted, per the AddKanbanDialog
// comment).
const loadFoldersForCwdPicker = async (
  path: string,
): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
}
const handleDocumentClickColumn = (event: MouseEvent) => {
  if (!isColumnPickerOpen.value) return
  const target = event.target as Node | null
  if (
    columnPickerRef.value &&
    target &&
    !columnPickerRef.value.contains(target)
  ) {
    isColumnPickerOpen.value = false
  }
}

// File preview modal state. Opened when the user clicks a file-path
// chip in either the inline MarkdownDescription (display mode) or the
// editor's preview.
const previewFilePath = ref<string | null>(null)
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const _openFilePreview = (path: string) => {
  previewFilePath.value = path
}
const closeFilePreview = () => {
  previewFilePath.value = null
}

// True when the dialog is rendering the create flow (rather than
// edit-in-place). Drives header copy / icon, save-button text, the
// form-state reset rule, and which emit fires on submit.
const isCreateMode = computed<boolean>(() => props.mode === 'create')

// Reset form whenever the dialog opens OR the target task changes.
// In create mode we always start blank (regardless of `task`). In
// edit mode we prefill from `task` (today's behavior).
watch(
  () => [props.show, props.task?.id, props.mode] as const,
  async ([show]) => {
    if (!show) return
    if (isCreateMode.value) {
      name.value = ''
      description.value = ''
      unattended.value = '0'
      tags.value = []  // NEW: start with empty tags in create mode
      selectedProfile.value = ''  // NEW: profile selector defaults to backend default
      // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Sync
      // cwdSession from the parent kanban's path on dialog open so
      // the picker shows the kanban-level fallback by default.
      // The legacy code initialized from the ref literal (`ref<string>(props.cwd ?? '')`)
      // which silently broke when the parent passed a different
      // cwd on a subsequent open with the same dialog instance.
      cwdSession.value = props.cwd ?? ''
    } else if (props.task) {
      name.value = props.task.name
      description.value = props.task.description ?? ''
      unattended.value = props.task.is_auto_retry_until_stop === '1' ? '1' : '0'
      // Migration 067 — prefill tags from the loaded task. tags?
      // is optional (legacy tasks may lack it); fallback to [].
      tags.value = props.task.tags ?? []
      // NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd).
      // Sync the per-task cwd picker with the task's persisted cwd
      // in edit mode. Equivalent to the create-mode
      // `cwdSession.value = props.cwd ?? ''` for create, but reads
      // the task row. `task?.cwd ?? ''` coerces legacy
      // pre-Migration-070 tasks (whose `cwd` is undefined) to the
      // empty-state placeholder — same UX as the read-only strip
      // that lived in the metadata strip pre-fix. This branch
      // also covers the rare "user clicks task A then task B with
      // the dialog already open" case via the watcher source's
      // `props.task?.id` dependency.
      cwdSession.value = props.task.cwd ?? ''
      // Migration 069 — image_urls are loaded via the store's
      // normalizeTaskTags (which splits the `||`-joined wire
      // string into a `string[]`). imageUrls is a computed that
      // tracks `props.task.imageUrls` so any PATCH that updates the
      // task row optimistically (the host flow's
      // `updateTaskDetails({ imageUrls })`) is reflected in the
      // gallery without a re-open.
    }
    await nextTick()
    nameInput.value?.focus()
    // Selecting the text is only useful in edit mode (so a rename
    // is a single keystroke). In create mode the input is empty —
    // `select()` is a no-op but skipping it removes a code-smell.
    if (!isCreateMode.value) nameInput.value?.select()
    // NEW (Task 2.7): reset the suggestions composable + start a
    // lazy load. Reset clears any state from the previous dialog
    // session so a different kanban (or a fresh open of the same one)
    // doesn't see stale suggestions from the previous task.
    tagSuggestions.reset()
    // Don't await — let the fetch happen in the background. The
    // dropdown only opens when the user focuses the input, which is
    // itself a separate trigger; awaiting here would block the
    // focus call on a network round-trip for no benefit.
    // NEW (plan: 2026-08-06-kanban-tags-autocomplete-in-create-mode):
    // Removed `props.task` from the guard. The fetch needs only the
    // kanban's workspace_item_id (from column.workspace_item_id),
    // which is available in BOTH edit and create modes via the host
    // bindings. The composable's fetchPage already short-circuits on
    // empty item_id (useKanbanTagSuggestions.ts:73-76), so the gate
    // was redundant AND was the reason the existing-tag dropdown never
    // appeared in the "+ Add task" dialog.
    if (props.workspaceId) {
      void tagSuggestions.ensureLoaded()
    }
    // NEW (plan: 2026-08-06-kanban-task-profile-selector). Fetch
    // profiles for the picker in create mode. Same fire-and-forget
    // pattern as tagSuggestions — the dropdown only opens when the
    // user clicks it.
    if (isCreateMode.value) {
      void loadProfiles()
    }
  },
  { immediate: true },
)

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Sync
// selectedColumnId from the parent's `column` prop. Two scenarios:
//   (a) Dialog opens — props.show flips false→true, parent passes
//       the latest column via `props.column`, selectedColumnId
//       re-syncs to match.
//   (b) User changes the column in the dropdown — emit `column-change`,
//       host updates activeCreateColumnId, the parent's computed
//       `activeCreateColumn` re-flows, `props.column?.id` re-emits,
//       this watcher fires with the SAME id (no infinite loop —
//       re-assigning selectedColumnId to its current value is a no-op).
watch(
  () => [props.show, props.column?.id] as const,
  ([show, columnId]) => {
    if (show && isCreateMode.value) {
      selectedColumnId.value = columnId ?? null
    }
  },
)

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Register
// the click-outside listener for the column picker at mount,
// deregister at unmount. Mirrors the profile picker's pattern (the
// profile picker uses inline @click.stop on its dropdown to avoid
// the same listener — both approaches are fine; the column picker
// uses the document listener because the dropdown is a sibling of
// the trigger button rather than a child).
onMounted(() => {
  document.addEventListener('click', handleDocumentClickColumn)
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Same
  // pattern for the per-task cwd picker.
  document.addEventListener('mousedown', handleDocumentClickCwd)
})
onUnmounted(() => {
  document.removeEventListener('click', handleDocumentClickColumn)
  document.removeEventListener('mousedown', handleDocumentClickCwd)
})

// Dirty tracking — the Save button enables only when the form is
// ready to submit. Two semantics:
//   - edit mode: the form must differ from the props.task baseline
//     (saves a wasted API call on a no-op Save click).
//   - create mode: any non-empty name is "dirty enough to submit"
//     (the task doesn't exist yet so there's nothing to compare to).
const isDirty = computed<boolean>(() => {
  if (isCreateMode.value) return isValid.value
  if (!props.task) return false
  const nameChanged = name.value.trim() !== props.task.name
  const descChanged = (description.value) !== (props.task.description ?? '')
  // Migration 067 — tags dirty check. Compare arrays via JSON.stringify
  // (cheap for ≤ 30 tags). Stable order matters: the chip input
  // preserves the user's add order, but if the backend ever returns
  // a different order, the dialog will treat the row as "dirty"
  // and push a no-op update. Acceptable; the order is stable
  // because we never re-sort tags on the backend.
  const tagsBefore = props.task.tags ?? []
  const tagsAfter = tags.value
  const tagsEqual =
    tagsBefore.length === tagsAfter.length &&
    tagsBefore.every((t, i) => t === tagsAfter[i])
  const tagsChanged = !tagsEqual
  return nameChanged || descChanged || tagsChanged
})

const isValid = computed<boolean>(() => name.value.trim().length > 0)
const canSave = computed<boolean>(() => isDirty.value && isValid.value)
// "Create task & run agent" requires only a name (description is
// optional — empty description degrades to a queued message that is
// just the title). The unattended toggle flows through separately.
const canRunAgent = computed<boolean>(() => isValid.value)

// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Inject the
// processingState map (provided by App.vue; populated via SSE worker
// events). The Start agent button is `:disabled` when a worker is
// already running for this task's session. Edit-mode only — create
// mode has its own ▶ Create task & run agent button.
//
// Defensive: `inject()` may return `undefined` if the provider is
// missing (e.g. tests that mount the dialog in isolation). The
// computed below treats that as "no worker running" (button enabled).
//
// Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md
const processingState = inject<Record<string, boolean> | undefined>(
  'processingState',
  undefined,
)
const isWorkerRunning = computed<boolean>(() => {
  if (!props.task?.id) return false
  return processingState?.[props.task.id] === true
})

// ─── Handlers ───────────────────────────────────────────────────────────

// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Edit-mode
// handler for the ▶ Start agent button. Emits `start-agent` with the
// task id; KanbanView's handler calls workspacesStore.startAgentOnTask,
// which POSTs to the new backend endpoint. The dialog stays open on
// failure (host sets errorMessage); closes on success.
const handleStartAgent = () => {
  if (isWorkerRunning.value) return
  if (!props.task?.id) return
  emit('start-agent', { taskId: props.task.id })
}

const handleSave = () => {
  if (!canSave.value) return
  // Belt + suspenders: if the user typed a tag and clicked Save
  // without pressing Enter/comma, the KanbanTagsInput still holds the
  // draft in its local `draftInput` ref. The mousedown handler
  // below commits it before click logic runs, but commit again here
  // to handle the (rarer) case where mousedown didn't fire (e.g.
  // keyboard activation via Space/Enter).
  tagsInputRef.value?.commitDraft()
  // canSave reads tags.value; re-check after the commit in case the
  // user's draft was the only "dirty" signal and committing it
  // didn't change isDirty (e.g. duplicate draft). canSave recomputes
  // reactively, but the read here is intentional — the Save button
  // is disabled while canSave is false.
  if (!canSave.value) return
  if (isCreateMode.value) {
      emit('create', {
        mode: 'create',
        name: name.value.trim(),
        description: description.value,
        // Forward the unattended toggle's current value. The
        // immediate-flip handler (handleUnattendedToggle) already
        // updated `unattended` via PUT in edit mode; in create
        // mode there's no session row yet, so this is the FIRST
        // (and only) time the value gets sent. Host threads it
        // through to api.createTask -> backend POST /tasks which
        // inserts a sessions row when the value is '1'.
        is_auto_retry_until_stop: unattended.value,
        // NEW (Migration 067 — kanban task tags): forward the
        // current tags array. The KanbanTagsInput already
        // validates + dedupes, so the array is ready to persist.
        tags: tags.value,
        // NEW (plan: 2026-08-06-kanban-task-profile-selector).
        // Empty string = backend default. Host captures but does
        // NOT persist on plain create (Path A — the backend's
        // task_create.zig has no selected_profile_model field).
        selectedProfile: selectedProfile.value,
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Create
        // mode image attachments: the editor never writes base64
        // into `description`. Instead it stages pasted/picked
        // images in `pendingFiles`. The host (KanbanView.
        // handleCreateTaskSave) reads them after `addTask`
        // returns the new taskId, uploads each via
        // `api.uploadTaskAttachment(taskId, file)`, then patches
        // the description with `![name](<url>)` markdown. Empty
        // array (not undefined) so the host can use the length
        // without a guard.
        pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
        // NEW (Migration 070 — kanban-cwd-session-optional plan).
        // Per-task cwd override. The dialog's folder picker
        // populates `cwdSession` (defaults to the parent kanban's
        // path when set; empty when the kanban is cwd-less or the
        // user skipped the picker). Empty string is the canonical
        // "no per-task cwd" sentinel — the backend stores '' and
        // the session_create 3-level fallback chain falls back to
        // the kanban-level path + the per-session sandbox. Host
        // threads this through to workspacesStore.addTask's
        // `cwd` param and to runAgentOnNewTask's `cwd` for the
        // create-and-run flow.
        cwdSession: cwdSession.value,
      })
    } else {
      emit('save', {
        mode: 'edit',
        name: name.value.trim(),
        description: description.value,
        // NEW (Migration 067): forward tags.
        tags: tags.value,
      })
    }
}

const handleClose = () => {
  // Emit BOTH events so both binding patterns work:
  //   - v-model:show (KanbanView) listens for `update:show`
  //   - :show + @close (KanbanSettingsDialog-style) listens for `close`
  emit('update:show', false)
  emit('close')
}

// NEW (plan: 2026-08-06-kanban-create-task-run-agent). Mirror of
// handleSave but for the "Create task & run agent" button. Emits
// `create-and-run` with mode='create_and_run' so the host can
// branch. Same payload as `create` (same fields, different mode
// discriminator) so the host's single handler can switch on mode.
const handleRunAgent = () => {
  if (!canRunAgent.value) return
  tagsInputRef.value?.commitDraft()
  if (!canRunAgent.value) return
  emit('create-and-run', {
    mode: 'create_and_run',
    name: name.value.trim(),
    description: description.value,
    is_auto_retry_until_stop: unattended.value,
    tags: tags.value,
    // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty
    // string = backend default. Host threads through to
    // runAgentOnNewTask which sets selected_profile_model on the
    // session at creation time so the chatview's picker reflects
    // it on landing.
    selectedProfile: selectedProfile.value,
    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc). Mirror of
    // handleSave's pendingFiles — see that handler for the
    // orchestration contract.
    pendingFiles: [...(descriptionEditorRef.value?.pendingFiles ?? [])],
    // NEW (Migration 070 — kanban-cwd-session-optional plan).
    // Mirror of handleSave's cwdSession — see that handler for the
    // 3-level fallback chain contract.
    cwdSession: cwdSession.value,
  })
}

// Commit any draft tag typed in the chip input the moment the user
// mousedowns the Save button. Why mousedown and not @blur on the
// input: the Save button has `:disabled="!canSave"`, and a draft
// tag typed without Enter/comma leaves canSave=false (the draft is
// in the chip input's local ref, not in `tags.value` yet). If we
// only relied on @blur, the click would land on a still-disabled
// button and the browser would drop it. mousedown is NOT gated by
// the disabled attribute (it's a low-level event), so we can
// commit the draft, the canSave computed flips to true, and the
// subsequent click event fires on the now-enabled button.
const commitTagsDraftOnSaveMouseDown = () => {
  tagsInputRef.value?.commitDraft()
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

// Toggle the unattended-mode flag. Emits `update-unattended` so the
// host can call api.updateSession(task.id, { isAutoRetryUntilStop })
// and persist it. We do NOT roll back on PUT failure here — the
// host owns the optimistic-vs-server-truth contract (and would
// re-bind task.is_auto_retry_until_stop via the workspaces store
// on next SSE event). For the common case where the user toggles
// and the host's PUT succeeds, the visual state matches the server
// immediately, which is the whole point of the toggle being
// immediate (not deferred to Save click).
const handleUnattendedToggle = (event: Event) => {
  const target = event.target as HTMLInputElement
  const newValue: '0' | '1' = target.checked ? '1' : '0'
  const previous = unattended.value
  // Optimistic local flip so the switch reflects the user's click
  // immediately. If the PUT fails, the SSE re-fetch (or a manual
  // rollback in the host) will correct it on the next paint.
  unattended.value = newValue
  emit('update-unattended', { value: newValue, previous })
}

// NEW (plan: 2026-08-06-kanban-task-profile-selector). Load profiles
// from LlmConfig (mirrors ChatView.loadProfiles). Called on dialog
// open in create mode; failure -> empty list (the picker still
// works, just only shows "Default").
const loadProfiles = async () => {
  if (!isCreateMode.value) return
  profilesLoading.value = true
  try {
    const config = await api.getNalarConfig()
    const profiles = (config.profiles ?? {}) as Record<
      string,
      { model?: string; base_url?: string }
    >
    availableProfiles.value = Object.entries(profiles).map(([name, p]) => ({
      name,
      model: p.model ?? '',
      base_url: p.base_url ?? '',
    }))
  } catch (err) {
    console.error('Failed to load profiles:', err)
    availableProfiles.value = []
  } finally {
    profilesLoading.value = false
  }
}

const toggleProfilePicker = () => {
  isProfilePickerOpen.value = !isProfilePickerOpen.value
}

const selectProfile = (name: string) => {
  selectedProfile.value = name
  isProfilePickerOpen.value = false
}

// ─── Metadata helpers ───────────────────────────────────────────────────

const taskTypeLabel = computed<string | null>(() => {
  const t = props.task?.task_type
  if (t === 'routine') return 'Routine'
  if (t === 'memory') return 'Memory'
  return null  // 'standard' and undefined both show no badge
})

const columnLabel = computed<string | null>(() => {
  return props.column?.name ?? null
})

// NEW (Task 2.7): Filter the suggestions composable's tags down to
// the names that are NOT already on the current task's draft chips.
// The model can't know about an unsaved draft, so we hide
// already-committed chips client-side. Case-insensitive set lookup
// so "Bug" doesn't show as a suggestion when the task has "bug".
const filteredTagSuggestions = computed<string[]>(() => {
  const excludeLower = new Set(tags.value.map((t) => t.toLowerCase()))
  return tagSuggestions.tags.value
    .map((s) => s.name)
    .filter((n) => !excludeLower.has(n.toLowerCase()))
})

// NEW (Migration 069 — kanban image urls column). The dialog's
// image gallery reads from the task row's `imageUrls` array. In
// edit mode this is the persisted column (loaded via the store's
// normalizeTaskTags from the `||`-joined wire string). In create
// mode the editor stages add/remove ops in its own `previewFiles`
// ref (mirrored into `pendingFiles` for the host to PATCH on save),
// so the gallery is naturally empty until the task is persisted.
//
// Tracking `props.task?.imageUrls` directly (not a local ref) keeps
// the gallery in sync with the host's optimistic
// `updateTaskDetails({ imageUrls })` write — the store mutates the
// task in place, the computed re-evaluates, the gallery re-renders
// without any re-open dance.
const imageUrls = computed<string[]>(() => props.task?.imageUrls ?? [])
</script>

<template>
  <Teleport to="body">
    <Transition name="kanban-task-detail-modal">
      <!--
        The dialog renders whenever `show` is true AND either:
          - a task is provided (edit mode), OR
          - the dialog is in create mode (task is intentionally null;
            the form starts blank).
        The original `v-if="show && task"` would have hidden the
        create-mode dialog because `task` is null.
      -->
      <div
        v-if="show && (task || isCreateMode)"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="isCreateMode ? 'kanban-task-detail-create-title' : 'kanban-task-detail-title'"
        data-testid="kanban-task-detail-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card. `max-w-2xl` (672px) — bumped from the previous
             `max-w-xl` (576px) per user feedback "make the dialog
             bigger" so the multi-field form (task name + column
             picker + description + tags + folder picker + profile
             picker + unattended mode) has more horizontal room
             without crossing into "wide modal" territory. `max-height:
             min(80vh, calc(100vh - 2rem))` (NOT a fixed height) so
             the card shrinks to fit its content when short — the
             body (`flex-1 overflow-y-auto min-h-0`) just takes its
             natural height when there's room, no empty space below
             the form. When content overflows the 80vh cap, the body
             fills the remaining space and scrolls (the original goal
             of the `min(80vh, ...)` constraint). Using `height:`
             instead forced the card to 80vh regardless of content,
             leaving a large gap between the form fields and the
             action buttons on short content (e.g. a brand-new task
             with no description). -->
        <div
          class="relative w-full max-w-2xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: min(80vh, calc(100vh - 2rem));
          "
        >
          <!-- Header -->
          <div
            class="px-5 pt-5 pb-4 shrink-0 flex items-center justify-between gap-3"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <h3
              :id="isCreateMode ? 'kanban-task-detail-create-title' : 'kanban-task-detail-title'"
              class="text-base font-semibold"
              style="color: var(--semantic-text);"
            >
              {{ isCreateMode ? 'New task' : 'Task details' }}
            </h3>
            <button
              type="button"
              @click="handleClose"
              data-testid="kanban-task-detail-close"
              class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
              style="color: var(--semantic-text-muted);"
              title="Close"
            >
              <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <!-- NEW (plan: 2026-08-19-kanban-error-banner-on-front).
               Error banner. Lifted OUT of the scrollable body so it
               stays permanently visible — even when the user scrolls
               down through the form fields (which used to push the
               banner off-screen, making it look like it was 'in the
               back of the dialog'). It is now a sibling of header /
               body / actions inside the dialog card, with shrink-0 so
               the flex column doesn't collapse it, and explicit
               `position: relative; z-index: 10` so it always renders
               above any descendant stacking context inside the body
               (e.g. the dropdowns in KanbanTagsInput which have
               z-50 on their dropdowns). The host sets errorMessage
               on a save/create/start-agent handler failure so the
               user can retry without losing their typed content
               (the form is NOT reset on error — only on a successful
               submit, via the broader watch's `show` change). -->
          <div
            v-if="errorMessage"
            class="shrink-0 px-5 py-3 text-sm"
            style="
              background-color: rgba(239, 68, 68, 0.12);
              border-bottom: 1px solid var(--color-border);
              color: rgb(220, 38, 38);
              position: relative;
              z-index: 10;
            "
            role="alert"
            data-testid="kanban-task-detail-error"
          >
            <div
              class="px-3 py-2 rounded-lg"
              style="border: 1px solid rgba(239, 68, 68, 0.4);"
            >
              {{ errorMessage }}
            </div>
          </div>

          <!-- Body (scrollable) -->
          <div class="flex-1 overflow-y-auto min-h-0 px-5 py-4">
            <!-- Task name input — big, prominent, full-width -->
            <div class="mb-4">
              <label
                for="kanban-task-detail-name"
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Task name
              </label>
              <input
                id="kanban-task-detail-name"
                ref="nameInput"
                v-model="name"
                type="text"
                placeholder="Enter task name…"
                :data-testid="isCreateMode ? 'kanban-task-detail-create-name' : 'kanban-task-detail-name'"
                class="w-full px-3 py-2.5 rounded-lg text-base font-medium outline-none transition-all duration-200"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                @keyup.enter="handleSave"
              />
            </div>

            <!-- Metadata strip (read-only). Hidden when no metadata
                 is available, which keeps the layout tight for the
                 common case (standard task with no pin / column
                 yet to load). In create mode the strip renders ONLY
                 when a column is provided — pin/type don't apply to
                 a brand-new task. -->
            <div
              v-if="columnLabel || (!isCreateMode && (taskTypeLabel || task?.is_pinned))"
              class="mb-4 flex items-center gap-2 flex-wrap text-xs"
              style="color: var(--semantic-text-dim);"
              data-testid="kanban-task-detail-metadata"
            >
              <!-- NEW (plan: 2026-08-06-kanban-add-task-button-placement).
                   Column picker (create mode only). Replaces the read-only
                   column strip in create mode — the user picks the target
                   column inside the dialog (mirrors the profile picker
                   pattern: button trigger + ▾ dropdown + ✓ checkmark +
                   click-outside close). Pick emits column-change so the
                   host updates activeCreateColumnId in real-time. Edit mode
                   falls through to the static strip below. -->
              <div
                v-if="isCreateMode && props.availableColumns.length > 0"
                ref="columnPickerRef"
                class="relative"
              >
                <button
                  type="button"
                  @click.stop="toggleColumnPicker"
                  class="min-w-[180px] px-2 py-0.5 rounded text-xs hover:opacity-80 inline-flex items-center justify-between gap-1"
                  style="
                    background-color: var(--semantic-sidebar-bg);
                    border: 1px solid var(--color-border);
                    color: var(--semantic-text);
                  "
                  data-testid="kanban-task-detail-column-picker"
                >
                  <span>{{ columnLabel }}</span>
                  <span class="text-[10px]">▾</span>
                </button>
                <div
                  v-if="isColumnPickerOpen"
                  class="absolute top-full mt-1 left-0 min-w-[180px] rounded-lg shadow-lg z-20 overflow-hidden"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                  "
                  data-testid="kanban-task-detail-column-picker-dropdown"
                  @click.stop
                >
                  <button
                    v-for="col in props.availableColumns"
                    :key="col.id"
                    type="button"
                    @click="selectColumn(col.id)"
                    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
                    style="color: var(--semantic-text);"
                    :data-testid="`kanban-task-detail-column-picker-item-${col.id}`"
                  >
                    <span class="font-medium">{{ col.name }}</span>
                    <span v-if="selectedColumnId === col.id">✓</span>
                  </button>
                </div>
              </div>
              <!-- Edit mode: read-only strip (unchanged). -->
              <span
                v-else-if="columnLabel"
                data-testid="kanban-task-detail-column"
              >
                {{ columnLabel }}
              </span>
              <span v-if="!isCreateMode && taskTypeLabel" data-testid="kanban-task-detail-type">
                <span aria-hidden="true">·</span>
                <span class="ml-1">{{ taskTypeLabel }}</span>
              </span>
              <span v-if="!isCreateMode && task?.is_pinned" data-testid="kanban-task-detail-pinned">
                Pinned
              </span>
              <!-- The read-only cwd strip (legacy) was removed by the
                   2026-08-14-kanban-task-detail-edit-cwd plan: the
                   picker button label now shows the cwd in both
                   modes, so the read-only span was redundant.
                   Plan: docs/superpowers/plans/
                   2026-08-14-kanban-task-detail-edit-cwd.md -->
            </div>

            <!-- Description — editor by default in both modes (preserves the
                 existing test contract: the textarea is always
                 available). A "Preview" toggle below renders the
                 current description as Markdown so the user can see
                 how it'll look on the card without leaving the form.

                 The editor owns its own textarea, paperclip, char
                 counter, @-trigger file picker, and image previews —
                 the dialog just passes the v-model and the cwd. -->
            <div>
              <label
                for="kanban-task-detail-description"
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Description
                <span
                  class="ml-1 text-[10px]"
                  style="color: var(--semantic-text-dim);"
                >
                  ({{ description.length }} / {{ DESCRIPTION_MAX }})
                </span>
              </label>

              <!-- Migration 069 — kanban image urls gallery. Reads
                   from task.imageUrls (set by the create-mode host
                   flow OR loaded from the row on edit-mode open).
                   Each image is a `data:image/<mime>;base64,...`
                   URL (from the `||`-delimited column string split
                   by the store's normalizeTaskTags). The editor
                   handles add/remove via its existing
                   `pendingFiles` mechanism; this gallery is the
                   read-only display of what's currently persisted.
                   Plan: docs/superpowers/plans/2026-08-06-kanban-
                   image-urls-column.md. -->
              <div
                v-if="imageUrls.length > 0"
                class="mb-3 flex flex-wrap gap-2"
                data-testid="kanban-task-detail-image-gallery"
              >
                <img
                  v-for="(url, idx) in imageUrls"
                  :key="idx"
                  :src="url"
                  :alt="`Task image ${idx + 1}`"
                  class="w-24 h-24 object-cover rounded border"
                  style="border-color: var(--color-border);"
                  :data-testid="`kanban-task-detail-image-${idx}`"
                />
              </div>

              <!-- Editor: shown in BOTH create + edit modes. The
                   previous "Preview" toggle button (which flipped to
                   <MarkdownDescription>) was removed per user
                   feedback — the dialog stays focused on the editor.
                   Plan: 2026-08-06-kanban-no-base64-in-desc. -->
              <KanbanDescriptionEditor
                ref="descriptionEditorRef"
                v-model="description"
                :cwd="cwd"
                :task-id="props.task?.id ?? ''"
                :max-length="DESCRIPTION_MAX"
                :test-id="isCreateMode ? 'kanban-task-detail-create-description' : 'kanban-task-detail-description'"
                data-testid="kanban-task-detail-description-editor"
              />
            </div>

            <!-- Tags (Migration 067 — kanban task tags feature).
                 Free-form chip input. Always shown (create + edit
                 modes). The KanbanTagsInput component handles all
                 validation + dedupe + color rendering. -->
            <div class="mt-4">
              <label
                for="kanban-task-detail-tags"
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Tags
              </label>
              <KanbanTagsInput
                ref="tagsInputRef"
                v-model="tags"
                :suggestions="filteredTagSuggestions"
                :has-more="tagSuggestions.hasMore.value"
                :loading-more="tagSuggestions.loading.value"
                :on-load-more="tagSuggestions.loadNextPage"
                :test-id="isCreateMode ? 'kanban-task-detail-create-tags' : 'kanban-task-detail-tags'"
              />
            </div>

            <!-- Unattended-mode toggle (always shown). Flips the
                 session's `is_auto_retry_until_stop` flag (which
                 lives on sessions, not workspace_item_tasks).
                 Immediate save on flip — does NOT wait for Save click.
                 In edit mode, the immediate save hits
                 PUT /api/llm/session/<id>. In create mode, the
                 flip is captured in local state and forwarded with
                 the create payload (the backend then atomically
                 inserts a `sessions` row + sets the flag in one
                 transaction). Either way, the flag persists from
                 the moment the task is created. -->
            <!-- NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd).
                 Per-task cwd picker row. Renders in BOTH create and
                 edit modes (previously only in create mode). In
                 create mode the picked cwd is forwarded via the
                 `create` / `create-and-run` emit's `cwdSession` field
                 on Save; in edit mode the picker fires `update-cwd`
                 so the host persists immediately (same iOS-style
                 immediate-save UX as the unattended toggle). The
                 picker's button label reflects the current cwd (or
                 the empty-state placeholder) so the user sees
                 "where does this task run?" without opening the
                 picker.
                 Plan: docs/superpowers/plans/
                 2026-08-14-kanban-task-detail-edit-cwd.md -->
            <div
              class="mt-4 pt-4 flex items-center gap-3"
              style="border-top: 1px solid var(--color-border);"
              data-testid="kanban-task-detail-cwd-row"
            >
              <!-- Per-task cwd picker (NEW: now visible in edit mode
                   too). Same trigger pattern as the profile picker
                   (button toggle + click-outside close). Pre-populated
                   from the parent kanban's path in create mode, or
                   the task's persisted `cwd` field in edit mode. -->
              <div ref="cwdPickerRef" class="relative shrink-0">
                <button
                  type="button"
                  @click.stop="toggleCwdPicker"
                  class="px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 hover:opacity-80 inline-flex items-center gap-1.5"
                  :style="cwdPickerStyle"
                  :title="
                    cwdSession
                      ? `Project root: ${cwdSession}`
                      : isCreateMode
                        ? 'No project root (optional)'
                        : 'No project root. Click to set a per-task cwd.'
                  "
                  data-testid="kanban-task-detail-cwd-picker"
                >
                  <!-- NEW (plan: 2026-08-06-kanban-folder-picker-style).
                       Inline SVG folder icon instead of the 📂 emoji.
                       `fill="currentColor"` inherits the button's text
                       color, so the icon matches the muted dark theme
                       (the emoji rendered as a system-colorful orange
                       icon that looked out of place next to the cleaner
                       profile picker's robot emoji). -->
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    viewBox="0 0 20 20"
                    fill="currentColor"
                    class="w-3.5 h-3.5 shrink-0"
                    aria-hidden="true"
                    data-testid="kanban-task-detail-cwd-picker-icon"
                  >
                    <path d="M2 5a2 2 0 012-2h4.586a1 1 0 01.707.293L11 5h5a2 2 0 012 2v8a2 2 0 01-2 2H4a2 2 0 01-2-2V5z" />
                  </svg>
                  <span class="font-mono truncate max-w-[180px] inline-block align-middle">
                    {{ cwdSession || 'Skip (no project root)' }}
                  </span>
                  <span class="text-[10px] shrink-0">▾</span>
                </button>
                <div
                  v-if="isCwdPickerOpen"
                  class="absolute z-30 mt-1 left-0"
                  data-testid="kanban-task-detail-cwd-picker-dropdown"
                >
                  <FilePickerDialog
                    v-model="isCwdPickerOpen"
                    mode="folder"
                    :load-items="loadFoldersForCwdPicker"
                    :key-for="(e: any) => e.path as string"
                    :path-for="(e: any) => e.path as string"
                    :is-expandable="(e: any) => e.is_directory as boolean"
                    :label-for="(e: any) => e.name as string"
                    :close-on-select="true"
                    :initial-path="cwdSession || props.cwd || '/'"
                    :selected-path="cwdSession || props.cwd || ''"
                    title="Select Per-Task Project Root"
                    :enable-recent-history="true"
                    @select="selectCwd"
                  />
                </div>
              </div>
            </div>

            <!-- Create mode: combined Profile + Unattended row (Q2 = 2a).
                 Same row keeps the dialog compact; visually pairs the
                 two controls (both shape how the agent runs). The
                 picker is only in create mode (Q1 = 1a). -->
            <div
              v-if="isCreateMode"
              class="mt-2 flex items-center gap-4"
              data-testid="kanban-task-detail-profile-and-unattended"
            >
              <!-- NEW (plan: 2026-08-06-kanban-task-profile-selector).
                   Profile-model picker. Loads from LlmConfig; mirrors
                   ChatView's picker pattern. -->
              <div ref="profilePickerRef" class="relative shrink-0">
                <button
                  type="button"
                  @click.stop="toggleProfilePicker"
                  class="px-3 py-1.5 rounded-lg text-xs font-medium transition-all duration-200 hover:opacity-80"
                  style="
                    background-color: var(--semantic-sidebar-bg);
                    border: 1px solid var(--color-border);
                    color: var(--semantic-text);
                  "
                  :title="
                    selectedProfile
                      ? `Using profile: ${selectedProfile}`
                      : 'Using default (top-level config)'
                  "
                  data-testid="kanban-task-detail-profile-picker"
                >
                  <span aria-hidden="true">🤖</span>
                  <span class="ml-1">{{ selectedProfile || 'Default' }}</span>
                  <span class="ml-1 text-[10px]">▾</span>
                </button>
                <div
                  v-if="isProfilePickerOpen"
                  class="absolute bottom-full mb-2 left-0 min-w-[240px] rounded-lg shadow-lg z-20 overflow-hidden"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                  "
                  data-testid="kanban-task-detail-profile-picker-dropdown"
                  @click.stop
                >
                  <button
                    type="button"
                    @click="selectProfile('')"
                    class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
                    style="color: var(--semantic-text);"
                    data-testid="kanban-task-detail-profile-picker-item"
                  >
                    <span class="font-medium">Default (top-level config)</span>
                    <span v-if="selectedProfile === ''">✓</span>
                  </button>
                  <button
                    v-for="p in availableProfiles"
                    :key="p.name"
                    type="button"
                    @click="selectProfile(p.name)"
                    class="w-full text-left px-3 py-2 text-xs hover:opacity-80"
                    style="
                      color: var(--semantic-text);
                      border-top: 1px solid var(--color-border);
                    "
                    data-testid="kanban-task-detail-profile-picker-item"
                  >
                    <div class="flex items-center justify-between">
                      <span class="font-medium">{{ p.name }}</span>
                      <span v-if="selectedProfile === p.name">✓</span>
                    </div>
                    <div class="text-[10px] mt-0.5" style="color: var(--semantic-text-muted)">
                      {{ p.model }} · {{ p.base_url }}
                    </div>
                  </button>
                  <div
                    v-if="!profilesLoading && availableProfiles.length === 0"
                    class="px-3 py-2 text-xs"
                    style="color: var(--semantic-text-muted)"
                    data-testid="kanban-task-detail-profile-picker-empty"
                  >
                    No profiles configured. Add one in Settings.
                  </div>
                </div>
              </div>

              <!-- Unattended mode (existing toggle, unchanged) -->
              <div class="flex-1 min-w-0 flex items-center justify-between gap-3">
                <div class="flex-1 min-w-0">
                  <div class="text-xs font-medium" style="color: var(--semantic-text-dim);">
                    Unattended mode
                  </div>
                  <div class="text-[11px] mt-0.5" style="color: var(--semantic-text-dim);">
                    Keep retrying past the 10-error limit for overnight
                    runs. Off = stop on too-many-retries.
                  </div>
                </div>
                <label
                  class="relative inline-flex items-center cursor-pointer shrink-0"
                  style="color: var(--semantic-text);"
                >
                  <input
                    type="checkbox"
                    :checked="unattended === '1'"
                    @change="handleUnattendedToggle"
                    class="sr-only peer"
                    data-testid="kanban-task-detail-unattended-toggle"
                  />
                  <div
                    class="w-11 h-6 rounded-full transition-colors duration-200"
                    style="background-color: var(--semantic-text-dim);"
                    :style="unattended === '1' ? { backgroundColor: '#f59e0b' } : {}"
                  />
                  <div
                    class="absolute top-0.5 left-0.5 w-5 h-5 rounded-full transition-transform duration-200"
                    style="background-color: white;"
                    :class="unattended === '1' ? 'translate-x-5' : ''"
                  />
                </label>
              </div>
            </div>

            <!-- Edit mode: just the unattended toggle (unchanged) -->
            <div
              v-else
              class="mt-2 pt-2 flex items-center justify-between gap-3"
              style="border-top: 1px solid var(--color-border);"
              data-testid="kanban-task-detail-unattended"
            >
              <div class="flex-1 min-w-0">
                <div class="text-xs font-medium" style="color: var(--semantic-text-dim);">
                  Unattended mode
                </div>
                <div class="text-[11px] mt-0.5" style="color: var(--semantic-text-dim);">
                  Keep retrying past the 10-error limit for overnight
                  runs. Off = stop on too-many-retries.
                </div>
              </div>
              <label
                class="relative inline-flex items-center cursor-pointer shrink-0"
                style="color: var(--semantic-text);"
              >
                <input
                  type="checkbox"
                  :checked="unattended === '1'"
                  @change="handleUnattendedToggle"
                  class="sr-only peer"
                  data-testid="kanban-task-detail-unattended-toggle"
                />
                <div
                  class="w-11 h-6 rounded-full transition-colors duration-200"
                  style="background-color: var(--semantic-text-dim);"
                  :style="unattended === '1' ? { backgroundColor: '#f59e0b' } : {}"
                />
                <div
                  class="absolute top-0.5 left-0.5 w-5 h-5 rounded-full transition-transform duration-200"
                  style="background-color: white;"
                  :class="unattended === '1' ? 'translate-x-5' : ''"
                />
              </label>
            </div>
          </div>

          <!-- Actions -->
          <div
            class="px-5 py-4 shrink-0 flex justify-end gap-2"
            style="border-top: 1px solid var(--color-border);"
          >
            <button
              type="button"
              @click="handleClose"
              data-testid="kanban-task-detail-cancel"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              Cancel
            </button>
            <button
              type="button"
              @mousedown="commitTagsDraftOnSaveMouseDown"
              @click="handleSave"
              :disabled="!canSave"
              data-testid="kanban-task-detail-save"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              {{ isCreateMode ? 'Create task' : 'Save' }}
            </button>
            <!-- NEW (plan: 2026-08-06-kanban-create-task-run-agent).
                 Outlined secondary button only in create mode. Sibling
                 to the primary "Create task" button — visually
                 subordinate so the safe default stays discoverable. The
                 ▶ play-icon prefix mirrors the routine "Run now" card
                 button for muscle memory. Disabled when name is empty;
                 description is NOT required (empty description degrades
                 to a queued message that is just the title). -->
            <button
              v-if="isCreateMode"
              type="button"
              @click="handleRunAgent"
              :disabled="!canRunAgent"
              data-testid="kanban-task-detail-create-and-run"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background-color: transparent;
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              title="Create the task and start the agent. The title + description becomes the first user message."
            >
              <span aria-hidden="true">▶</span>
              <span class="ml-1">Create task &amp; run agent</span>
            </button>
            <!-- NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
                 Outlined secondary button only in edit mode. Sibling
                 to the primary "Save" button — visually subordinate
                 so the safe default stays discoverable. The ▶ play-
                 icon prefix matches the create-mode ▶ Create task &
                 run agent button (and the routine Run now card) for
                 muscle memory. Edit mode's counterpart to the create-
                 mode "Create task & run agent" — kicks off the agent
                 on an existing task's session WITHOUT queueing a new
                 user message. The agent runs on whatever chat history
                 is already in the session. Disabled when a worker is
                 already running for this task's session (the
                 frontend's best-effort check; the backend's atomic
                 DB lookup is the source of truth and returns 409 on
                 race). -->
            <button
              v-if="!isCreateMode"
              type="button"
              @click="handleStartAgent"
              :disabled="isWorkerRunning"
              :title="
                isWorkerRunning
                  ? 'A worker is already running on this task — wait for it to finish before starting a new agent.'
                  : 'Trigger the agent on the existing chat context. No new message is queued — the agent resumes whatever context is already in the session.'
              "
              data-testid="kanban-task-detail-start-agent"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background-color: transparent;
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            >
              <span aria-hidden="true">▶</span>
              <span class="ml-1">Start agent</span>
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <!-- File preview modal. Mounted at the dialog root so it's not
       affected by the parent transition. The path comes from the
       chip click; cwd comes from props (the kanban's filesystem
       root, threaded in from KanbanView.item.path). -->
  <FilePreviewModal
    v-if="previewFilePath"
    :show="previewFilePath !== null"
    :cwd="cwd"
    :file-path="previewFilePath"
    @close="closeFilePreview"
  />
</template>

<style scoped>
.kanban-task-detail-modal-enter-active,
.kanban-task-detail-modal-leave-active {
  transition: opacity 0.2s ease;
}

.kanban-task-detail-modal-enter-from,
.kanban-task-detail-modal-leave-to {
  opacity: 0;
}

.kanban-task-detail-modal-enter-active > div:last-child,
.kanban-task-detail-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.kanban-task-detail-modal-enter-from > div:last-child,
.kanban-task-detail-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>

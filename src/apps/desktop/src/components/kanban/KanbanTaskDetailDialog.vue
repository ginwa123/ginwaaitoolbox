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
import { ref, computed, watch, nextTick } from 'vue'
import type { Task, KanbanColumn } from '../../stores/workspaces'
import KanbanDescriptionEditor from './KanbanDescriptionEditor.vue'
import MarkdownDescription from './MarkdownDescription.vue'
import FilePreviewModal from './FilePreviewModal.vue'

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
  }>(),
  {
    mode: 'edit',
    column: null,
    errorMessage: null,
    cwd: '',
  },
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
  save: [payload: { mode: 'edit'; name: string; description: string }]
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
    },
  ]
  // Emitted in edit mode when the user flips the unattended toggle.
  // The host persists via api.updateSession(task.id, { isAutoRetryUntilStop }).
  // value is '1' when toggled ON, '0' when toggled OFF. Emitted
  // BEFORE the optimistic UI flip so the host can capture the
  // pre-toggle value (in case it needs to roll back on PUT failure).
  'update-unattended': [payload: { value: '0' | '1'; previous: '0' | '1' }]
}>()

// ─── Form state ──────────────────────────────────────────────────────────

const name = ref('')
const description = ref('')
const unattended = ref<'0' | '1'>('0')
const nameInput = ref<HTMLInputElement | null>(null)
const DESCRIPTION_MAX = 5000
// Description render mode:
//   - Both modes default to the editor (textarea + paperclip + char
//     counter). The textarea is always available so existing test
//     selectors + form-state machinery keep working.
//   - A "Preview" toggle flips to <MarkdownDescription> for a rendered
//     view without leaving the form.
const isPreviewingDescription = ref(false)

// File preview modal state. Opened when the user clicks a file-path
// chip in either the inline MarkdownDescription (display mode) or the
// editor's preview.
const previewFilePath = ref<string | null>(null)
const openFilePreview = (path: string) => {
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
  async ([show, _taskId, _mode]) => {
    if (!show) return
    if (isCreateMode.value) {
      name.value = ''
      description.value = ''
      unattended.value = '0'
      isPreviewingDescription.value = false
    } else if (props.task) {
      name.value = props.task.name
      description.value = props.task.description ?? ''
      unattended.value = props.task.is_auto_retry_until_stop === '1' ? '1' : '0'
      isPreviewingDescription.value = false
    }
    await nextTick()
    nameInput.value?.focus()
    // Selecting the text is only useful in edit mode (so a rename
    // is a single keystroke). In create mode the input is empty —
    // `select()` is a no-op but skipping it removes a code-smell.
    if (!isCreateMode.value) nameInput.value?.select()
  },
  { immediate: true },
)

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
  return nameChanged || descChanged
})

const isValid = computed<boolean>(() => name.value.trim().length > 0)
const canSave = computed<boolean>(() => isDirty.value && isValid.value)

// ─── Handlers ───────────────────────────────────────────────────────────

const handleSave = () => {
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
    })
  } else {
    emit('save', {
      mode: 'edit',
      name: name.value.trim(),
      description: description.value,
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

        <!-- Dialog Card. Wider than AddTaskDialog (max-w-xl) so the
             description has room to breathe. min(80vh, ...) for the
             height so it scrolls on short viewports. -->
        <div
          class="relative w-full max-w-xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            height: min(80vh, calc(100vh - 2rem));
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

          <!-- Body (scrollable) -->
          <div class="flex-1 overflow-y-auto min-h-0 px-5 py-4">
            <!-- Error banner. Sits at the top of the body so the
                 user sees it immediately. Hidden when errorMessage is
                 null/empty. The host sets errorMessage on a save/
                 create handler failure so the user can retry without
                 losing their typed content (the form is NOT reset on
                 error — only on a successful submit, via watch's
                 `show` change). -->
            <div
              v-if="errorMessage"
              class="mb-4 px-3 py-2 rounded-lg text-sm"
              style="
                background-color: rgba(239, 68, 68, 0.12);
                border: 1px solid rgba(239, 68, 68, 0.4);
                color: rgb(220, 38, 38);
              "
              role="alert"
              data-testid="kanban-task-detail-error"
            >
              {{ errorMessage }}
            </div>

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
              <span v-if="columnLabel" data-testid="kanban-task-detail-column">
                {{ columnLabel }}
              </span>
              <span v-if="!isCreateMode && taskTypeLabel" data-testid="kanban-task-detail-type">
                <span aria-hidden="true">·</span>
                <span class="ml-1">{{ taskTypeLabel }}</span>
              </span>
              <span v-if="!isCreateMode && task?.is_pinned" data-testid="kanban-task-detail-pinned">
                Pinned
              </span>
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

              <!-- Editor: shown by default in BOTH create + edit modes. -->
              <KanbanDescriptionEditor
                v-show="!isPreviewingDescription"
                v-model="description"
                :cwd="cwd"
                :task-id="props.task?.id ?? ''"
                :max-length="DESCRIPTION_MAX"
                :test-id="isCreateMode ? 'kanban-task-detail-create-description' : 'kanban-task-detail-description'"
                data-testid="kanban-task-detail-description-editor"
              />

              <!-- Preview: opt-in via the toggle button below. Renders
                   the description as Markdown via <MarkdownDescription>. -->
              <div
                v-if="isPreviewingDescription"
                class="px-3 py-2.5 rounded-lg text-sm"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                  min-height: 160px;
                "
                data-testid="kanban-task-detail-description-preview"
              >
                <MarkdownDescription
                  :source="description"
                  :cwd="cwd"
                  :test-id="`kanban-task-detail-description-preview-rendered`"
                  @file-click="openFilePreview"
                />
              </div>

              <button
                type="button"
                class="mt-2 text-xs px-2 py-1 rounded transition-colors"
                style="
                  background-color: var(--semantic-card-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text-muted);
                "
                data-testid="kanban-task-detail-description-preview-toggle"
                @click="isPreviewingDescription = !isPreviewingDescription"
              >
                {{ isPreviewingDescription ? 'Edit description' : 'Preview' }}
              </button>
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
            <div
              class="mt-4 pt-4 flex items-center justify-between gap-3"
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
                <!-- Toggle track. peer-checked styles the background
                     to amber (#f59e0b) when on; dark when off. The
                     thumb slides 20px on check, matching the iOS-style
                     toggle convention. -->
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

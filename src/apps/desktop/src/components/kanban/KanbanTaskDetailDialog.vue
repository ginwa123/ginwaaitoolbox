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

const props = withDefaults(
  defineProps<{
    show: boolean
    mode?: 'edit' | 'create'
    task: Task | null
    column?: KanbanColumn | null  // optional — shown in metadata strip
    errorMessage?: string | null  // optional — red banner in body
  }>(),
  {
    mode: 'edit',
    column: null,
    errorMessage: null,
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
  create: [payload: { mode: 'create'; name: string; description: string }]
}>()

// ─── Form state ──────────────────────────────────────────────────────────

const name = ref('')
const description = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const DESCRIPTION_MAX = 5000

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
    } else if (props.task) {
      name.value = props.task.name
      description.value = props.task.description ?? ''
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
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">{{ isCreateMode ? '➕' : '📝' }}</span>
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
              <span aria-hidden="true" class="mr-1">⚠️</span>
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
                <span aria-hidden="true">📋</span>
                <span class="ml-1">{{ columnLabel }}</span>
              </span>
              <span v-if="!isCreateMode && taskTypeLabel" data-testid="kanban-task-detail-type">
                <span aria-hidden="true">·</span>
                <span class="ml-1">{{ taskTypeLabel }}</span>
              </span>
              <span v-if="!isCreateMode && task?.is_pinned" data-testid="kanban-task-detail-pinned">
                <span aria-hidden="true">📌</span>
                <span class="ml-1">Pinned</span>
              </span>
            </div>

            <!-- Description textarea — big (10 rows vs AddTaskDialog's 3),
                 full width. resize-y so the user can drag the corner to
                 make it taller for long descriptions. -->
            <div>
              <label
                for="kanban-task-detail-description"
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Description
                <span class="ml-1 text-[10px]" style="color: var(--semantic-text-dim);">
                  ({{ description.length }} / {{ DESCRIPTION_MAX }})
                </span>
              </label>
              <textarea
                id="kanban-task-detail-description"
                v-model="description"
                :maxlength="DESCRIPTION_MAX"
                rows="10"
                placeholder="Add a description…"
                :data-testid="isCreateMode ? 'kanban-task-detail-create-description' : 'kanban-task-detail-description'"
                class="w-full px-3 py-2.5 rounded-lg text-sm outline-none transition-all duration-200 resize-y"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                  font-family: inherit;
                  min-height: 200px;
                "
              />
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

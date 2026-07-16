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
      show       boolean
      task       Task | null  (the task to edit; null hides the form)
    emits:
      close      []
      save       [{ name: string, description: string }]
                Emitted when the user clicks Save. The host calls
                workspacesStore.updateTaskDetails(...) and closes
                the dialog on success.

  This dialog is purely presentational — no API calls, no store
  reads. The host (AppLayout) owns the "open + for which task"
  state and wires the `save` emit to a store action.

  Pattern source: KanbanSettingsDialog.vue — Teleport to body,
  max-height 70vh, transition + backdrop, semantic CSS variables
  for theme compatibility.
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue'
import type { Task, KanbanColumn } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  task: Task | null
  column?: KanbanColumn | null  // optional — shown in metadata strip
}>()

const emit = defineEmits<{
  close: []
  save: [payload: { name: string; description: string }]
}>()

// ─── Form state ──────────────────────────────────────────────────────────

const name = ref('')
const description = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const DESCRIPTION_MAX = 5000

// Reset form whenever the dialog opens OR the target task changes.
watch(
  () => [props.show, props.task?.id] as const,
  async ([show]) => {
    if (show && props.task) {
      name.value = props.task.name
      description.value = props.task.description ?? ''
      await nextTick()
      // Focus + select the name input so the user can rename in
      // place with a single keystroke.
      nameInput.value?.focus()
      nameInput.value?.select()
    }
  },
  { immediate: true },
)

// Dirty tracking — the Save button enables only when something
// actually changed (compared to the props.task baseline).
const isDirty = computed<boolean>(() => {
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
  emit('save', {
    name: name.value.trim(),
    description: description.value,
  })
}

const handleClose = () => {
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
      <div
        v-if="show && task"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="kanban-task-detail-title"
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
              id="kanban-task-detail-title"
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">📝</span>
              Task details
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
                data-testid="kanban-task-detail-name"
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
                 yet to load). -->
            <div
              v-if="columnLabel || taskTypeLabel || task?.is_pinned"
              class="mb-4 flex items-center gap-2 flex-wrap text-xs"
              style="color: var(--semantic-text-dim);"
              data-testid="kanban-task-detail-metadata"
            >
              <span v-if="columnLabel" data-testid="kanban-task-detail-column">
                <span aria-hidden="true">📋</span>
                <span class="ml-1">{{ columnLabel }}</span>
              </span>
              <span v-if="taskTypeLabel" data-testid="kanban-task-detail-type">
                <span aria-hidden="true">·</span>
                <span class="ml-1">{{ taskTypeLabel }}</span>
              </span>
              <span v-if="task?.is_pinned" data-testid="kanban-task-detail-pinned">
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
                data-testid="kanban-task-detail-description"
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
              Save
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

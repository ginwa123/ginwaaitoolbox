<!--
  KanbanColumnEditor — modal for managing kanban columns: add / rename
  / delete. One component, three modes (set via the `mode` prop):

    - 'add':    shows a name input + "Add" button → emits `add(name)`
    - 'rename': shows a name input pre-filled + "Save" button → emits
                `rename(name)`
    - 'delete': shows a confirmation message + "Delete" button →
                emits `delete()`

  The host (WorkspaceItem.vue) is responsible for opening the dialog
  in the right mode, for the confirm/cancel flow on `delete`, and for
  delegating to the store actions. This component is purely
  presentational.

  Public API:
    props:  show, mode ('add' | 'rename' | 'delete'), initialName
    emits:  close, add(name), rename(name), delete()
-->
<script setup lang="ts">
import { ref, watch, nextTick, computed, onBeforeUnmount } from 'vue'

type Mode = 'add' | 'rename' | 'delete'

const props = defineProps<{
  show: boolean
  mode: Mode
  initialName?: string
}>()

const emit = defineEmits<{
  close: []
  add: [name: string]
  rename: [name: string]
  delete: []
}>()

// ─── State ─────────────────────────────────────────────────────────────────

const name = ref('')
const nameInput = ref<HTMLInputElement | null>(null)

// ─── Computed labels & description per mode ────────────────────────────────

// Single source of truth for the header + description text. Keeps the
// template branch-free and ensures all 3 modes stay visually consistent.
const headerText = computed(() => {
  if (props.mode === 'add') return 'Add Column'
  if (props.mode === 'rename') return 'Rename Column'
  return 'Delete Column'
})

const descriptionText = computed(() => {
  if (props.mode === 'add') {
    return 'Add a new column to this kanban board'
  }
  if (props.mode === 'rename') {
    return 'Rename this column'
  }
  return 'Delete this column? Tasks in this column will become unassigned.'
})

// The header icon — matches the visual style of AddKanbanDialog.
const headerIcon = computed(() => {
  if (props.mode === 'delete') return '🗑️'
  return '📋'
})

// Show the name input for add / rename modes only; the delete mode
// shows a static confirmation message instead.
const showNameInput = computed(() => props.mode === 'add' || props.mode === 'rename')

const submitLabel = computed(() => {
  if (props.mode === 'add') return 'Add'
  if (props.mode === 'rename') return 'Save'
  return 'Delete'
})

// Whether the submit button is destructive (red). Only the delete
// mode is destructive; add / rename use the standard gradient.
const isDestructive = computed(() => props.mode === 'delete')

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleSubmit = () => {
  if (props.mode === 'delete') {
    emit('delete')
    handleClose()
    return
  }
  const trimmed = name.value.trim()
  if (!trimmed) return
  if (props.mode === 'add') {
    emit('add', trimmed)
  } else if (props.mode === 'rename') {
    // For rename, we still emit even if the name equals the initial
    // — the parent can choose to no-op. We deliberately do NOT skip
    // the emit because the user explicitly clicked Save.
    emit('rename', trimmed)
  }
  handleClose()
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    handleClose()
  }
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────

// Seed the name field on first render (so a rename modal opened with
// show=true at mount time has the column's name pre-filled, not an
// empty string), and reset + refocus on every subsequent open.
// Mirrors the AddKanbanDialog / AddItemDialog pattern. The
// `immediate: true` flag is critical — without it the watcher never
// fires on first render (Vue's watch defaults to skip-the-current-
// value), so the rename input would open blank.
name.value = props.initialName ?? ''
watch(
  () => props.show,
  async (show) => {
    if (show) {
      name.value = props.initialName ?? ''
      await nextTick()
      // Focus the name input when it exists; in delete mode there is
      // no input to focus, but focusing the dialog itself is harmless.
      if (showNameInput.value) {
        nameInput.value?.focus()
        nameInput.value?.select()
      }
    }
  },
)

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})
</script>

<template>
  <Teleport to="body">
    <Transition name="kanban-column-editor-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="`kanban-column-editor-title-${mode}`"
        :data-testid="`kanban-column-editor-${mode}`"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: 70vh;
          "
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              :id="`kanban-column-editor-title-${mode}`"
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">{{ headerIcon }}</span>
              {{ headerText }}
            </h3>
            <p
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim);"
            >
              {{ descriptionText }}
            </p>
          </div>

          <!-- Name input (add / rename) or confirmation text (delete) -->
          <div v-if="showNameInput" class="px-5 pb-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Column Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              :placeholder="mode === 'add' ? 'In review' : ''"
              :data-testid="`kanban-column-editor-${mode}-name`"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              @keyup.enter="handleSubmit"
            />
          </div>
          <div v-else class="px-5 pb-4">
            <!-- Delete-mode confirmation: surface the column name so the
                 user has explicit context on what they're deleting. -->
            <div
              class="text-sm px-3 py-2 rounded-lg"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :data-testid="`kanban-column-editor-${mode}-message`"
            >
              <strong>{{ initialName }}</strong>
            </div>
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              type="button"
              @click="handleClose"
              :data-testid="`kanban-column-editor-${mode}-cancel`"
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
              @click="handleSubmit"
              :disabled="showNameInput && !name.trim()"
              :data-testid="`kanban-column-editor-${mode}-submit`"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              :style="isDestructive
                ? 'background: var(--color-red, #ef4444); color: var(--color-bg);'
                : 'background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);'"
            >
              {{ submitLabel }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal entry/exit animation. Unique name to avoid collisions with
   other dialogs. */
.kanban-column-editor-modal-enter-active,
.kanban-column-editor-modal-leave-active {
  transition: opacity 0.2s ease;
}

.kanban-column-editor-modal-enter-from,
.kanban-column-editor-modal-leave-to {
  opacity: 0;
}

.kanban-column-editor-modal-enter-active > div:last-child,
.kanban-column-editor-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.kanban-column-editor-modal-enter-from > div:last-child,
.kanban-column-editor-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
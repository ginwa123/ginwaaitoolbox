<!--
  AddKanbanDialog — modal for creating a new project kanban board.

  Single-input modal flow:
    1. This dialog opens with a name input + an "Add" button
    2. User enters a name and clicks Add → emits `create(name)`
    3. The parent (Sidebar) calls `workspacesStore.addKanbanItem(...)`
       which POSTs to /api/workspaces/:wsId/items/kanban and seeds
       three default columns (todo / in progress / done).

  Mirrors AddItemDialog.vue's structure (Teleport / backdrop / dialog
  card / header / body / actions), minus the folder picker — kanban
  items have no on-disk path, only a name.

  Public API:
    props:  show (boolean)
    emits:  close, create(name: string)
-->
<script setup lang="ts">
import { ref, watch, nextTick, onBeforeUnmount } from 'vue'

const props = defineProps<{
  show: boolean
}>()

const emit = defineEmits<{
  close: []
  create: [name: string]
}>()

// ─── State ─────────────────────────────────────────────────────────────────

const name = ref('')
const nameInput = ref<HTMLInputElement | null>(null)

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleCreate = () => {
  const trimmedName = name.value.trim()
  if (trimmedName) {
    emit('create', trimmedName)
    handleClose()
  }
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

// Reset state when the dialog opens. Mirrors AddItemDialog — we
// deliberately do NOT preserve the typed name across open/close so
// the dialog is predictable for users.
watch(() => props.show, async (show) => {
  if (show) {
    name.value = ''
    await nextTick()
    nameInput.value?.focus()
  }
})

onBeforeUnmount(() => {
  document.body.style.overflow = ''
})
</script>

<template>
  <Teleport to="body">
    <Transition name="add-kanban-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-kanban-title"
        data-testid="add-kanban-dialog"
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
              id="add-kanban-title"
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">📋</span>
              Add Project Kanban
            </h3>
            <p
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim);"
            >
              Create a new kanban board
            </p>
          </div>

          <!-- Kanban Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Kanban Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Sprint 12"
              data-testid="add-kanban-name"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              @keyup.enter="handleCreate"
            />
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button
              type="button"
              @click="handleClose"
              data-testid="add-kanban-cancel"
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
              @click="handleCreate"
              :disabled="!name.trim()"
              data-testid="add-kanban-submit"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(
                  135deg,
                  var(--color-violet),
                  var(--color-blue)
                );
                color: var(--color-bg);
              "
            >
              Add
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal entry/exit animation for the AddKanbanDialog wrapper modal.
   Uses a unique transition name so it doesn't collide with other
   dialogs that share the .modal-* namespace. */
.add-kanban-modal-enter-active,
.add-kanban-modal-leave-active {
  transition: opacity 0.2s ease;
}

.add-kanban-modal-enter-from,
.add-kanban-modal-leave-to {
  opacity: 0;
}

.add-kanban-modal-enter-active > div:last-child,
.add-kanban-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.add-kanban-modal-enter-from > div:last-child,
.add-kanban-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
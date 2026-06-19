<script setup lang="ts">
// AddTaskPickerDialog — shown when the user clicks the green `+`
// button on a workspace item. Three large cards: "Standard Chat",
// "Routine", and "Memory". The parent (Sidebar.vue) decides which
// creation flow to open based on the emitted `pick` value.
//
// Style match: backdrop + card wrapper copied verbatim from
// AddTaskDialog.vue:44-143 so the visual language is consistent
// with every other dialog in the app.

const props = defineProps<{
  show: boolean
  projectName?: string
}>()

const emit = defineEmits<{
  close: []
  pick: [taskType: 'standard' | 'routine' | 'memory']
}>()

const handleClose = () => emit('close')

// The picker is a chooser, not a holder: once the user has picked
// a path, the picker has done its job and must close so the picked
// dialog isn't stacked on top of it. Emit `pick` first (parent
// decides which create dialog to open) and then `close` (parent
// hides the picker). Mirrors the `emit('create', ...); handleClose()`
// pattern in AddTaskDialog.vue:26-31.
const handleStandard = () => {
  emit('pick', 'standard')
  handleClose()
}

const handleRoutine = () => {
  emit('pick', 'routine')
  handleClose()
}

const handleMemory = () => {
  emit('pick', 'memory')
  handleClose()
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') {
    handleClose()
  }
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
        @keydown="handleKeydown"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 bg-black/60 backdrop-blur-sm"
          @click="handleClose"
        />

        <!-- Dialog Content -->
        <div
          class="relative w-full max-w-2xl mx-4 rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          data-testid="add-task-picker"
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              class="text-base font-semibold"
              style="color: var(--semantic-text);"
            >
              New Task
            </h3>
            <p v-if="projectName" class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Add task to "{{ projectName }}"
            </p>
          </div>

          <!-- Three cards side-by-side -->
          <div class="px-5 pb-5 grid grid-cols-3 gap-3">
            <!-- Standard Chat card -->
            <button
              type="button"
              @click="handleStandard"
              data-testid="picker-standard"
              class="flex flex-col items-start gap-2 p-4 rounded-lg text-left transition-all duration-200 hover:scale-[1.02]"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
            >
              <span class="text-2xl" aria-hidden="true">💬</span>
              <span class="text-sm font-semibold" style="color: var(--semantic-text);">Standard Chat</span>
              <span class="text-xs" style="color: var(--semantic-text-dim);">
                An interactive chat with the AI. You send messages, the AI responds.
              </span>
            </button>

            <!-- Routine card -->
            <button
              type="button"
              @click="handleRoutine"
              data-testid="picker-routine"
              class="flex flex-col items-start gap-2 p-4 rounded-lg text-left transition-all duration-200 hover:scale-[1.02]"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
            >
              <span class="text-2xl" aria-hidden="true">🕒</span>
              <span class="text-sm font-semibold" style="color: var(--semantic-text);">Routine</span>
              <span class="text-xs" style="color: var(--semantic-text-dim);">
                A scheduled task. The AI runs your prompt on a schedule; you see the runs in the chat.
              </span>
            </button>

            <!-- Memory card (new in 2026-06-20). Creates a local
                 .md file scoped to the parent workspace_item's
                 directory; the task row is a thin index pointing
                 at the file. See plans/2026-06-20-add-markdown-memory.md. -->
            <button
              type="button"
              @click="handleMemory"
              data-testid="picker-memory"
              class="flex flex-col items-start gap-2 p-4 rounded-lg text-left transition-all duration-200 hover:scale-[1.02]"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
            >
              <span class="text-2xl" aria-hidden="true">📝</span>
              <span class="text-sm font-semibold" style="color: var(--semantic-text);">Memory</span>
              <span class="text-xs" style="color: var(--semantic-text-dim);">
                A local .md file. The AI sees its content on every chat in this project.
              </span>
            </button>
          </div>

          <!-- Cancel -->
          <div class="px-5 pb-5 flex justify-end">
            <button
              @click="handleClose"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200"
              style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal transitions — copied verbatim from AddTaskDialog.vue. */
.modal-enter-active,
.modal-leave-active {
  transition: all 0.2s ease-out;
}
.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}
.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95) translateY(10px);
}
</style>

<!--
  AddDesignDialog — modal for creating a new design (HTML canvas) workspace item.

  Minimal modal with just a name input. Unlike AddKanbanDialog, design
  items do NOT bind to a folder — the LLM produces HTML that renders
  in a sandboxed iframe; there is no cwd to set.

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

const name = ref('')
const nameInput = ref<HTMLInputElement | null>(null)

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
    <Transition name="add-design-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-design-title"
        data-testid="add-design-dialog"
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
              id="add-design-title"
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">🎨</span>
              Add Design
            </h3>
            <p
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim);"
            >
              Create a new HTML canvas. The LLM populates pages via
              <code>set_design_page</code>.
            </p>
          </div>

          <!-- Design Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Design Name
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="Auth UI"
              data-testid="add-design-name"
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
              data-testid="add-design-cancel"
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
              data-testid="add-design-submit"
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
.add-design-modal-enter-active,
.add-design-modal-leave-active {
  transition: opacity 0.2s ease;
}

.add-design-modal-enter-from,
.add-design-modal-leave-to {
  opacity: 0;
}

.add-design-modal-enter-active > div:last-child,
.add-design-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.add-design-modal-enter-from > div:last-child,
.add-design-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
<!--
  AgentKnowledgeDialog — modal for adding a markdown knowledge file to an Agent.

  Body:
    - file_path (required, must be absolute)
    - label (optional)

  Public API:
    props:  show (boolean)
    emits:  close, create(file_path: string, label: string)

  Plan: 2026-08-15-agent-mode (Task 16)
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue'

const props = defineProps<{ show: boolean }>()

const emit = defineEmits<{
  close: []
  create: [filePath: string, label: string]
}>()

const filePath = ref('')
const label = ref('')
const pathInput = ref<HTMLInputElement | null>(null)
const pathTouched = ref(false)

const pathError = computed<string | null>(() => {
  if (!pathTouched.value) return null
  if (filePath.value.length === 0) return 'Path is required'
  if (!filePath.value.startsWith('/')) return 'Path must be absolute'
  return null
})

const canSubmit = computed(() => filePath.value.startsWith('/') && filePath.value.length > 0)

const handleCreate = () => {
  if (canSubmit.value) {
    emit('create', filePath.value, label.value)
    handleClose()
  }
}

const handleClose = () => emit('close')

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

watch(() => props.show, async (show) => {
  if (show) {
    filePath.value = ''
    label.value = ''
    pathTouched.value = false
    await nextTick()
    pathInput.value?.focus()
  }
})
</script>

<template>
  <Teleport to="body">
    <Transition name="agent-knowledge-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-knowledge-title"
        data-testid="agent-knowledge-dialog"
      >
        <div class="absolute inset-0 backdrop-blur-md" style="background: rgba(0, 0, 0, 0.6);" @click="handleClose" />
        <div
          class="relative w-full max-w-md mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 70vh;"
        >
          <div class="px-5 pt-5 pb-4">
            <h3 id="agent-knowledge-title" class="text-base font-semibold" style="color: var(--semantic-text);">
              Add Knowledge
            </h3>
            <p class="text-xs mt-1" style="color: var(--semantic-text-dim);">
              Attach a markdown file the agent will read at chat start
            </p>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">File Path (absolute)</label>
            <input
              ref="pathInput"
              v-model="filePath"
              type="text"
              placeholder="/home/me/docs/spec.md"
              data-testid="agent-knowledge-path"
              :aria-invalid="pathError !== null"
              class="w-full px-3 py-2 rounded-lg text-sm font-mono outline-none"
              :style="{
                backgroundColor: 'var(--semantic-sidebar-bg)',
                border: `1px solid ${pathError ? 'var(--color-red)' : 'var(--color-border)'}`,
                color: 'var(--semantic-text)',
              }"
              @input="pathTouched = true"
              @blur="pathTouched = true"
              @keyup.enter="handleCreate"
            />
            <p v-if="pathError" class="text-xs mt-1" style="color: var(--color-red);" data-testid="agent-knowledge-path-error">
              {{ pathError }}
            </p>
          </div>
          <div class="px-5 pb-4">
            <label class="block text-xs font-medium mb-2" style="color: var(--semantic-text-dim);">Label (optional)</label>
            <input
              v-model="label"
              type="text"
              placeholder="Project spec"
              data-testid="agent-knowledge-label"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none"
              style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border); color: var(--semantic-text);"
            />
          </div>
          <div class="px-5 pb-5 flex justify-end gap-2">
            <button type="button" @click="handleClose" data-testid="agent-knowledge-cancel" class="px-3 py-1.5 rounded-lg text-sm font-medium" style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); color: var(--semantic-text-muted);">Cancel</button>
            <button type="button" @click="handleCreate" :disabled="!canSubmit" data-testid="agent-knowledge-submit" class="px-3 py-1.5 rounded-lg text-sm font-medium disabled:opacity-50" style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);">Add</button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.agent-knowledge-modal-enter-active,
.agent-knowledge-modal-leave-active {
  transition: opacity 0.2s ease;
}
.agent-knowledge-modal-enter-from,
.agent-knowledge-modal-leave-to {
  opacity: 0;
}
</style>
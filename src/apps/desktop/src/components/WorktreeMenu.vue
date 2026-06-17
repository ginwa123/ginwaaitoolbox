<script setup lang="ts">
/**
 * Dropdown menu for the worktree indicator in the chat status bar.
 * Three actions:
 *   - "Create a PR" — emits 'create-pr' so the parent opens CreatePrDialog
 *   - "View in folder" — emits 'view-folder' so the parent opens a folder browser
 *   - "Clear worktree" — emits 'clear' so the parent sends the LLM a system message
 *
 * The menu closes itself after any action via the parent's v-if binding.
 */
import { ref, onMounted, onUnmounted } from 'vue'

const emit = defineEmits<{
  (e: 'create-pr'): void
  (e: 'view-folder'): void
  (e: 'clear'): void
  (e: 'close'): void
}>()

const menuRef = ref<HTMLElement | null>(null)

const handleClickOutside = (e: MouseEvent) => {
  if (menuRef.value && !menuRef.value.contains(e.target as Node)) {
    emit('close')
  }
}

onMounted(() => {
  // Add a tick delay so the click that opened the menu doesn't immediately close it
  setTimeout(() => document.addEventListener('click', handleClickOutside), 0)
})
onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside)
})

const onCreatePr = () => {
  emit('create-pr')
  emit('close')
}
const onViewFolder = () => {
  emit('view-folder')
  emit('close')
}
const onClear = () => {
  if (confirm('Clear the worktree binding? This removes the worktree directory and unbinds the session.')) {
    emit('clear')
    emit('close')
  }
}
</script>

<template>
  <div
    ref="menuRef"
    class="absolute bottom-full mb-2 left-0 min-w-[200px] rounded-lg shadow-lg z-20 overflow-hidden"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
    "
  >
    <button
      data-testid="worktree-menu-create-pr"
      @click="onCreatePr"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
      style="color: var(--semantic-text)"
    >
      <span>🔀</span>
      <span>Create a PR</span>
    </button>
    <button
      data-testid="worktree-menu-view-folder"
      @click="onViewFolder"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
      style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
    >
      <span>📁</span>
      <span>View in folder</span>
    </button>
    <button
      data-testid="worktree-menu-clear"
      @click="onClear"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
      style="color: var(--color-red); border-top: 1px solid var(--color-border)"
    >
      <span>🗑️</span>
      <span>Clear worktree</span>
    </button>
  </div>
</template>
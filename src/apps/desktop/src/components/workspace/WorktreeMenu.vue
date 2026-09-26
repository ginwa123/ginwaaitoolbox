<script setup lang="ts">
/**
 * Dropdown menu for the git indicator in the chat status bar.
 *
 * Shows different actions based on whether a worktree is bound:
 *
 * With worktree (`hasWorktree=true`):
 *   - 🔀 "Create a PR"    — currently disabled (frontend-only)
 *   - 📁 "View in folder" — currently disabled (frontend-only)
 *   - 🗑️ "Clear worktree" — currently disabled (frontend-only)
 *
 * Without worktree (`hasWorktree=false`):
 *   - 🌳 "Create worktree" — emits 'create-worktree' (parent opens CreateWorktreeDialog)
 *   - 📁 "Open in folder" — currently disabled (frontend-only, same feature as "View in folder")
 *   - 🔄 "Refresh status" — emits 'refresh' so the parent re-fetches git status
 *
 * The menu closes itself after any action via the parent's v-if binding.
 * Disabled items stay visible but cannot be clicked.
 */
import { ref } from 'vue'
import { useEventListener } from '@vueuse/core'

// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const props = defineProps<{
  /** Whether a worktree is currently bound to this session. */
  hasWorktree: boolean
  /** Current branch name, shown as a header inside the menu. */
  branch: string
  /** Optional status text (e.g. "clean", "2 uncommitted changes"). */
  status?: string
}>()

const emit = defineEmits<{
  (e: 'create-pr'): void
  (e: 'create-worktree'): void
  (e: 'view-folder'): void
  (e: 'clear'): void
  (e: 'refresh'): void
  (e: 'close'): void
}>()

const menuRef = ref<HTMLElement | null>(null)

const handleClickOutside = (e: MouseEvent) => {
  if (menuRef.value && !menuRef.value.contains(e.target as Node)) {
    emit('close')
  }
}

// The component's existence IS the open state (ChatView renders it under
// v-if), so the listener is bound for exactly the menu's lifetime and the
// component scope owns teardown. A deferred setTimeout attach could not:
// unmounting inside that same macrotask ran the removal first, then the
// pending timer attached a listener nothing would ever remove, and every
// later click in the app fired `close` on a dead component.
//
// The old tick delay existed to skip the click that opened the menu, but the
// opening click never reaches document anyway: ChatView's trigger uses
// @click.stop, and the v-if mount happens in a post-flush job, i.e. after
// that click's propagation has already finished.
useEventListener(document, 'click', handleClickOutside)

const onCreatePr = () => {
  emit('create-pr')
  emit('close')
}
const onViewFolder = () => {
  emit('view-folder')
  emit('close')
}
const onClear = () => {
  if (
    confirm(
      'Clear the worktree binding? This removes the worktree directory and unbinds the session.',
    )
  ) {
    emit('clear')
    emit('close')
  }
}
const onRefresh = () => {
  emit('refresh')
  emit('close')
}
const onCreateWorktree = () => {
  emit('create-worktree')
  emit('close')
}
</script>

<template>
  <div
    ref="menuRef"
    class="absolute bottom-full mb-2 left-0 min-w-[200px] rounded-lg shadow-lg z-20 overflow-hidden"
    style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
  >
    <!-- Header — shows current branch and (optional) status. Gives the
         user context for what they're acting on. -->
    <div
      class="px-3 py-2 text-[10px] uppercase tracking-wider"
      style="
        color: var(--semantic-text-dim);
        border-bottom: 1px solid var(--color-border);
        background-color: var(--semantic-sidebar-bg);
      "
    >
      <div class="flex items-center gap-1.5">
        <span>🌿</span>
        <span style="font-family: monospace">{{ branch || 'detached' }}</span>
      </div>
      <div
        v-if="status"
        class="mt-0.5 normal-case tracking-normal"
        style="color: var(--semantic-text-muted)"
      >
        {{ status }}
      </div>
    </div>

    <!-- Worktree-bound actions — all three temporarily disabled via frontend only. -->
    <template v-if="hasWorktree">
      <button
        data-testid="worktree-menu-create-pr"
        @click="onCreatePr"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-xs flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--semantic-text)"
      >
        <span>🔀</span>
        <span>Create a PR</span>
      </button>
      <button
        data-testid="worktree-menu-view-folder"
        @click="onViewFolder"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-xs flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
      >
        <span>📁</span>
        <span>View in folder</span>
      </button>
      <button
        data-testid="worktree-menu-clear"
        @click="onClear"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-xs flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--color-red); border-top: 1px solid var(--color-border)"
      >
        <span>🗑️</span>
        <span>Clear worktree</span>
      </button>
    </template>

    <!-- No-worktree actions -->
    <template v-else>
      <button
        data-testid="worktree-menu-create-worktree"
        @click="onCreateWorktree"
        class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
        style="color: var(--semantic-text)"
      >
        <span>🌳</span>
        <span>Create worktree</span>
      </button>
      <button
        data-testid="worktree-menu-view-folder"
        @click="onViewFolder"
        disabled
        title="Disabled"
        class="w-full text-left px-3 py-2 text-xs flex items-center gap-2 opacity-40 cursor-not-allowed"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
      >
        <span>📁</span>
        <span>Open in folder</span>
      </button>
      <button
        data-testid="worktree-menu-refresh"
        @click="onRefresh"
        class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center gap-2"
        style="color: var(--semantic-text); border-top: 1px solid var(--color-border)"
      >
        <span>🔄</span>
        <span>Refresh status</span>
      </button>
    </template>
  </div>
</template>

<script setup lang="ts">
/**
 * "Create worktree" dialog. Mounted by ChatView.vue when the user clicks
 * "Create worktree" in the WorktreeMenu (no-worktree branch).
 *
 * The dialog collects a SHORT NAME (e.g. "auth-fix", "bug-123") and
 * emits `create(name)`. The parent derives the full path as
 * `${sessionCwd}/.worktrees/${name}` and the branch as
 * `worktree/${name}`, then sends a system message to the LLM asking
 * it to call set_git_worktree(path=<full_path>). Branch defaults to
 * worktree/<name> in the tool, so the LLM doesn't need to pass it.
 *
 * Why this is simpler than CreatePrDialog:
 *   - No async pre-fill (no getGitWorktreeInfo call)
 *   - No base branch field (tool's default is correct for new worktrees)
 *   - No full path field (smart default + tool's validation handles it)
 *   - The actual work is done by the LLM after the user clicks Create,
 *     so the dialog itself is fire-and-forget
 *
 * The dialog closes itself via the parent's v-if binding.
 */
import { ref, onMounted, onUnmounted } from 'vue'

const emit = defineEmits<{
  (e: 'create', name: string): void
  (e: 'close'): void
}>()

const name = ref('')
const isSubmitting = ref(false)
const inputRef = ref<HTMLInputElement | null>(null)

onMounted(() => {
  // Focus the input on open so the user can start typing immediately
  setTimeout(() => inputRef.value?.focus(), 0)
  // Esc closes the dialog (no submit guard needed — name is empty)
  document.addEventListener('keydown', handleKeydown)
})

onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
})

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape' && !isSubmitting.value) emit('close')
}

const onSubmit = () => {
  if (isSubmitting.value) return
  const trimmed = name.value.trim()
  if (trimmed === '') return
  isSubmitting.value = true
  emit('create', trimmed)
  // Don't close here — the parent may show an error inline. Parent
  // decides when to close (on success, on error, on Cancel).
}

const onClose = () => {
  if (!isSubmitting.value) emit('close')
}
</script>

<template>
  <div
    class="fixed inset-0 z-50 flex items-center justify-center p-4"
    style="background-color: rgba(0, 0, 0, 0.5)"
    @click.self="onClose"
  >
    <div
      class="w-full max-w-md rounded-lg shadow-xl overflow-hidden"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      data-testid="create-worktree-dialog"
    >
      <div
        class="px-4 py-3 flex items-center justify-between"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <h2 class="text-sm font-semibold" style="color: var(--semantic-text)">
          🌳 Create a worktree
        </h2>
        <button
          @click="onClose"
          :disabled="isSubmitting"
          data-testid="create-worktree-close"
          class="opacity-60 hover:opacity-100"
          style="color: var(--semantic-text)"
        >
          ✕
        </button>
      </div>

      <div class="px-4 py-4 space-y-2">
        <label class="block text-xs font-medium" style="color: var(--semantic-text-dim)">
          Name
        </label>
        <input
          ref="inputRef"
          v-model="name"
          data-testid="create-worktree-name"
          type="text"
          class="w-full px-2 py-1.5 text-xs rounded font-mono"
          style="
            background-color: var(--semantic-input-bg, var(--semantic-card-bg));
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
            color-scheme: dark;
          "
          placeholder="auth-fix"
          @keyup.enter="onSubmit"
        />
        <p class="text-[10px] mt-1" style="color: var(--semantic-text-dim)">
          The worktree will be created at
          <code style="font-family: monospace;">&lt;session_cwd&gt;/.worktrees/&lt;name&gt;</code>
          and the branch will be
          <code style="font-family: monospace;">worktree/&lt;name&gt;</code>.
          Make sure
          <code style="font-family: monospace;">.worktrees/</code>
          exists in your project root (or change the name to use a different parent).
        </p>
      </div>

      <div
        class="px-4 py-3 flex items-center justify-end gap-2"
        style="border-top: 1px solid var(--color-border)"
      >
        <button
          @click="onClose"
          :disabled="isSubmitting"
          data-testid="create-worktree-cancel"
          class="px-3 py-1.5 text-xs rounded"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text);
          "
        >
          Cancel
        </button>
        <button
          @click="onSubmit"
          :disabled="isSubmitting || name.trim() === ''"
          data-testid="create-worktree-submit"
          class="px-3 py-1.5 text-xs font-medium rounded"
          :class="
            isSubmitting || name.trim() === ''
              ? 'opacity-50 cursor-not-allowed'
              : 'hover:opacity-80'
          "
          style="
            background-color: var(--color-violet);
            color: white;
          "
        >
          <span>{{ isSubmitting ? 'Creating...' : 'Create' }}</span>
        </button>
      </div>
    </div>
  </div>
</template>

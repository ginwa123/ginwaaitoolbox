<script setup lang="ts">
/**
 * "Create worktree" dialog. Mounted by ChatView.vue when the user clicks
 * "Create worktree" in the WorktreeMenu (no-worktree branch).
 *
 * The dialog is a small folder-picker + name input. The user picks a
 * parent directory by:
 *   - Clicking folders in the FolderExplorer to navigate into them
 *   - Typing/editing the path in the breadcrumb-style input at top
 *   - Clicking the ↑ button to go up one directory
 *
 * Then types a SHORT BASENAME (e.g. "auth-fix", "bug-123") for the
 * worktree itself. The dialog composes the final absolute path as
 * `${parentDir}/${basename}` and emits `create(path)`. The parent
 * sends a system message to the LLM asking it to call
 * set_git_worktree(path=<full_path>).
 *
 * The FolderExplorer is the existing component from src/apps/desktop/
 * src/components/FolderExplorer.vue (used in RightSidebar for the
 * workspace file browser). This dialog listens for its new
 * `folder-click` event to navigate. Existing FolderExplorer callers
 * (RightSidebar) are unaffected — they don't listen for folder-click.
 *
 * The tool handles path validation (must be absolute, no .., no null
 * bytes, ≤ 4096 chars, basename matches [A-Za-z0-9._-]{1,100}) and the
 * worktree-add subprocess. The branch defaults to
 * worktree/<basename(path)> in the tool, so the LLM doesn't need to
 * pass it.
 *
 * Why this is simpler than CreatePrDialog:
 *   - No async pre-fill (no getGitWorktreeInfo call)
 *   - No base branch field (tool's default is correct for new worktrees)
 *   - The actual work is done by the LLM after the user clicks Create,
 *     so the dialog itself is fire-and-forget
 *
 * The dialog closes itself via the parent's v-if binding.
 */
import { ref, computed, onMounted, onUnmounted } from 'vue'
import FolderExplorer from './FolderExplorer.vue'
import type { FolderEntry } from '../api'

const props = defineProps<{
  /** Absolute path used as the initial parent directory (typically the session cwd). */
  initialCwd?: string
}>()

const emit = defineEmits<{
  (e: 'create', path: string): void
  (e: 'close'): void
}>()

// Parent directory of the new worktree. Starts at initialCwd (the
// session cwd), or falls back to '/' if not provided.
const parentDir = ref(props.initialCwd && props.initialCwd.trim() !== '' ? props.initialCwd : '/')

// Basename of the new worktree (e.g. "auth-fix", "bug-123").
const basename = ref('')

const isSubmitting = ref(false)

// Final path that will be sent to set_git_worktree. Avoids double-slash
// when parentDir is "/".
const fullPath = computed(() => {
  const base = parentDir.value.endsWith('/') ? parentDir.value.slice(0, -1) : parentDir.value
  const trimmed = basename.value.trim()
  if (trimmed === '') return `${base}/`
  return `${base}/${trimmed}`
})

// Can the user submit? Need a non-empty basename + a valid-looking
// parent dir. The tool's validatePath is the source of truth; this is
// only the client-side guard to disable the button.
const canSubmit = computed(() => {
  return !isSubmitting.value && basename.value.trim() !== '' && parentDir.value.trim() !== ''
})

// Navigate into a folder clicked in the FolderExplorer.
const onFolderClick = (folder: FolderEntry) => {
  if (folder.is_directory) {
    parentDir.value = folder.path
  }
}

// Navigate up one directory from the current parentDir.
const goUp = () => {
  const trimmed = parentDir.value.replace(/\/+$/, '') || '/'
  if (trimmed === '/') return  // already at root
  const lastSlash = trimmed.lastIndexOf('/')
  parentDir.value = lastSlash === 0 ? '/' : trimmed.slice(0, lastSlash)
}

// Update parentDir when the user types in the path bar.
const onPathInput = (e: Event) => {
  const target = e.target as HTMLInputElement
  parentDir.value = target.value
}

onMounted(() => {
  // Esc closes the dialog (no submit guard needed — empty basename disables Create)
  document.addEventListener('keydown', handleKeydown)
})

onUnmounted(() => {
  document.removeEventListener('keydown', handleKeydown)
})

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape' && !isSubmitting.value) emit('close')
}

const onSubmit = () => {
  if (!canSubmit.value) return
  isSubmitting.value = true
  emit('create', fullPath.value)
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
      class="w-full max-w-xl rounded-lg shadow-xl overflow-hidden flex flex-col"
      style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border); max-height: 80vh"
      data-testid="create-worktree-dialog"
    >
      <div
        class="px-4 py-3 flex items-center justify-between shrink-0"
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

      <div class="flex-1 overflow-hidden flex flex-col">
        <!-- Parent directory: path bar + Up button + FolderExplorer -->
        <div class="px-4 py-3 space-y-2 flex-1 overflow-hidden flex flex-col">
          <label class="block text-xs font-medium" style="color: var(--semantic-text-dim)">
            Parent directory
          </label>
          <div class="flex items-center gap-2">
            <input
              :value="parentDir"
              @input="onPathInput"
              data-testid="create-worktree-parent"
              type="text"
              class="flex-1 px-2 py-1.5 text-xs rounded font-mono"
              style="
                background-color: var(--semantic-input-bg, var(--semantic-card-bg));
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
                color-scheme: dark;
              "
              spellcheck="false"
            />
            <button
              @click="goUp"
              :disabled="parentDir === '/'"
              :title="'Go up one directory'"
              data-testid="create-worktree-up"
              class="px-2 py-1.5 text-xs rounded shrink-0"
              :class="parentDir === '/' ? 'opacity-40 cursor-not-allowed' : 'hover:opacity-80'"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            >
              ↑
            </button>
          </div>

          <!-- Folder explorer — bounded height so the dialog doesn't grow unbounded -->
          <div
            class="flex-1 overflow-y-auto rounded"
            style="border: 1px solid var(--color-border); min-height: 200px; max-height: 320px;"
            data-testid="create-worktree-explorer"
          >
            <FolderExplorer
              :cwd="parentDir"
              @folder-click="onFolderClick"
            />
          </div>
        </div>

        <!-- Basename + hint -->
        <div class="px-4 pb-3 space-y-2 shrink-0">
          <label class="block text-xs font-medium" style="color: var(--semantic-text-dim)">
            Name
          </label>
          <input
            v-model="basename"
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
          <p class="text-[10px]" style="color: var(--semantic-text-dim)">
            The worktree will be created at
            <code style="font-family: monospace;">{{ fullPath }}</code>.
            The branch will be auto-derived as
            <code style="font-family: monospace;">worktree/{{ basename || '&lt;name&gt;' }}</code>.
            The parent directory must already exist.
          </p>
        </div>
      </div>

      <div
        class="px-4 py-3 flex items-center justify-end gap-2 shrink-0"
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
          :disabled="!canSubmit"
          data-testid="create-worktree-submit"
          class="px-3 py-1.5 text-xs font-medium rounded"
          :class="!canSubmit ? 'opacity-50 cursor-not-allowed' : 'hover:opacity-80'"
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

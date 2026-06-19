<!--
  AddMemoryDialog — modal for creating a new LOCAL memory file.

  A local memory lives in `<cwd>/.nalar/memories/<name>.md` (see
  `LOCAL_MEMORIES_DIR` in `src/modules/agent/tools/memories.zig`).
  The agent's `loadLocalKnowledge` picks up every `.md` in that
  directory on every chat and injects them as the "Local
  Knowledge" section of the system prompt (see
  `src/modules/agent/prompts.zig:263`).

  Distinct from the global memories (in `~/.config/nalar/memories/`)
  managed via the MemoriesSettings page — global memories apply
  to every project on the machine, while local memories are
  scoped to the cwd of the current workspace item. This dialog
  is the entry point for the per-project memory.

  Public API:
    props:  show (boolean), cwd (string — required, used to scope
                              the file to the right project dir)
    emits:  close
            create(name: string, path: string)

  Validation mirrors `memories.isValidMemoryName`:
    - non-empty after trim
    - must end in `.md`
    - no path separators (`/`, `\`)
    - no `..` segments
-->
<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'
import { createLocalMemory } from '../api'
import { useNotificationStore } from '../stores/notifications'

const props = defineProps<{
  show: boolean
  /**
   * The cwd to scope the new memory to. The file is written to
   * `<cwd>/.nalar/memories/<name>.md`. Required — the dialog
   * shows an error if missing (e.g. the user clicked "Add
   * Markdown" from a workspace with no folder item to derive
   * a cwd from).
   */
  cwd: string
}>()

const emit = defineEmits<{
  close: []
  create: [name: string, path: string]
}>()

// ─── State ─────────────────────────────────────────────────────────────────

const name = ref('')
const content = ref('')
const nameInput = ref<HTMLInputElement | null>(null)
const isSubmitting = ref(false)

const notificationStore = useNotificationStore()

// ─── Validation ─────────────────────────────────────────────────────────────

/**
 * Mirrors `memories.isValidMemoryName` from
 * `src/modules/agent/tools/memories.zig:372` — kept in sync so the
 * dialog rejects obvious typos before hitting the server. The
 * server is the source of truth; if the two ever drift, the
 * server-side check returns 400.
 */
function isValidMemoryName(rawName: string): boolean {
  const trimmed = rawName.trim()
  if (trimmed.length === 0) return false
  if (!trimmed.endsWith('.md')) return false
  if (trimmed.includes('/') || trimmed.includes('\\')) return false
  if (trimmed.includes('..')) return false
  return true
}

// ─── Handlers ──────────────────────────────────────────────────────────────

const handleCreate = async () => {
  const trimmedName = name.value.trim()
  if (!trimmedName || !content.value) return
  if (!props.cwd) {
    notificationStore.notifyError(
      'Cannot create local memory: no project directory (cwd) is set for this workspace.',
    )
    return
  }
  if (!isValidMemoryName(trimmedName)) {
    notificationStore.notifyError(
      'Invalid memory name (must end in .md, no /, no .., no \\)',
    )
    return
  }

  isSubmitting.value = true
  try {
    const result = await createLocalMemory(trimmedName, content.value, props.cwd)
    // createLocalMemory returns { memory: { name, title, path, size } } on success.
    // The ApiError throw handles the non-2xx case (toast is auto-fired
    // by apiFetch), so reaching this line means the memory exists.
    emit('create', result.memory.name, result.memory.path)
    handleClose()
  } catch (err) {
    // apiFetch already shows the error toast. The dialog stays open
    // so the user can correct the name/content and try again. No
    // additional notification needed here.
    console.error('[AddMemoryDialog] create failed:', err)
  } finally {
    isSubmitting.value = false
  }
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && !isSubmitting.value) {
    handleClose()
  }
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────

// Reset state on every open — matches AddItemDialog's contract.
// `immediate: true` ensures the default content is populated on
// the very first mount when `show=true` is passed as a prop (no
// `show` change has happened yet, so the watcher would otherwise
// never fire). Mirrors the pattern in MemoryDetail.vue:79.
watch(() => props.show, async (show) => {
  if (show) {
    name.value = ''
    content.value = '# New Memory\n\nWrite your notes here.\n'
    isSubmitting.value = false
    await nextTick()
    nameInput.value?.focus()
  }
}, { immediate: true })
</script>

<template>
  <Teleport to="body">
    <Transition name="add-memory-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-memory-title"
        data-testid="add-memory-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card -->
        <div
          class="relative w-full max-w-lg mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
          style="
            background-color: var(--semantic-card-bg);
            border: 1px solid var(--color-border);
            box-shadow:
              0 1px 2px rgba(0, 0, 0, 0.4),
              0 8px 24px rgba(0, 0, 0, 0.35);
            max-height: 80vh;
          "
        >
          <!-- Header -->
          <div class="px-5 pt-5 pb-4">
            <h3
              id="add-memory-title"
              class="text-base font-semibold flex items-center gap-2"
              style="color: var(--semantic-text);"
            >
              <span aria-hidden="true">📝</span>
              Add Markdown
            </h3>
            <p
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim);"
            >
              Create a local memory at
              <code class="font-mono break-all">{{ cwd || '(no cwd)' }}/.nalar/memories/</code>
            </p>
          </div>

          <!-- Name -->
          <div class="px-5 pb-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Name (must end in <code>.md</code>)
            </label>
            <input
              ref="nameInput"
              v-model="name"
              type="text"
              placeholder="my-memory.md"
              data-testid="add-memory-name"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200 font-mono"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
              :disabled="isSubmitting"
              @keyup.enter="handleCreate"
            />
          </div>

          <!-- Content -->
          <div class="px-5 pb-4 flex-1 flex flex-col overflow-hidden">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Initial Content
            </label>
            <textarea
              v-model="content"
              data-testid="add-memory-content"
              rows="8"
              class="flex-1 w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200 font-mono resize-none"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
                min-height: 160px;
              "
              :disabled="isSubmitting"
            />
          </div>

          <!-- Actions -->
          <div class="px-5 pb-5 flex justify-end gap-2 shrink-0">
            <button
              type="button"
              @click="handleClose"
              :disabled="isSubmitting"
              data-testid="add-memory-cancel"
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
              :disabled="
                isSubmitting ||
                !props.cwd ||
                !name.trim() ||
                !content.trim() ||
                !isValidMemoryName(name.trim())
              "
              data-testid="add-memory-submit"
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
              {{ isSubmitting ? 'Creating...' : 'Create' }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
/* Modal entry/exit animation. Uses a unique transition name to avoid
   colliding with .add-item-modal-* (different element, same scope). */
.add-memory-modal-enter-active,
.add-memory-modal-leave-active {
  transition: opacity 0.2s ease;
}
.add-memory-modal-enter-from,
.add-memory-modal-leave-to {
  opacity: 0;
}
.add-memory-modal-enter-active > div:last-child,
.add-memory-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}
.add-memory-modal-enter-from > div:last-child,
.add-memory-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>

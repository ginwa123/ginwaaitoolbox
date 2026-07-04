<!--
  CopyKanbanSpecDialog — modal for copying one kanban's column
  spec (names + descriptions, preserving order) into a target
  kanban. Mounted from the ⚙ Settings dialog's footer button.

  Layout (top → bottom):
    1. Header — "Copy spec from…" title + close.
    2. Source picker — <select> of the workspace's other kanbans
       (the active target is filtered out).
    3. Mode radio — "Replace existing columns" (destructive) or
       "Append at the end" (additive). Replace is the default.
    4. Confirm button — fires the copy, then closes.

  Public API:
    props:
      show        boolean
      workspaceId string
      targetItemId string — the kanban the user wants to copy INTO
                             (filtered out of the source picker)
    emits:
      close       []
      copy        [sourceItemId: string, mode: 'replace' | 'append']

  The dialog is purely presentational — the host (AppLayout)
  delegates to workspacesStore.copyKanbanSpecFrom on each emit.

  Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
    (Chunk 4, Task 4.1)
-->
<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue'
import { useWorkspacesStore, type WorkspaceItem } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  workspaceId: string
  targetItemId: string
}>()

const emit = defineEmits<{
  close: []
  copy: [sourceItemId: string, mode: 'replace' | 'append']
}>()

const workspacesStore = useWorkspacesStore()

// ─── State ────────────────────────────────────────────────────────────

const sourceItemId = ref<string>('')
const mode = ref<'replace' | 'append'>('replace')
const sourceSelect = ref<HTMLSelectElement | null>(null)

// ─── Picker data ──────────────────────────────────────────────────────

// All kanbans in the active workspace EXCEPT the target.
const availableSources = computed<WorkspaceItem[]>(() => {
  return workspacesStore.workspaces
    .flatMap((ws) => (ws.id === props.workspaceId ? ws.items : []))
    .filter(
      (item) =>
        item.item_type === 'kanban' && item.id !== props.targetItemId,
    )
    .sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
})

// ─── Handlers ─────────────────────────────────────────────────────────

const handleCopy = () => {
  if (!sourceItemId.value) return
  emit('copy', sourceItemId.value, mode.value)
  handleClose()
}

const handleClose = () => {
  emit('close')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

// ─── Lifecycle ────────────────────────────────────────────────────────

watch(
  () => props.show,
  async (show) => {
    if (show) {
      sourceItemId.value = ''
      mode.value = 'replace'
      const first = availableSources.value[0]
      if (first) sourceItemId.value = first.id
      await nextTick()
      sourceSelect.value?.focus()
    }
  },
)
</script>

<template>
  <Teleport to="body">
    <Transition name="copy-kanban-spec-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="copy-kanban-spec-title"
        data-testid="copy-kanban-spec-dialog"
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
          "
        >
          <!-- Header -->
          <div
            class="px-5 pt-5 pb-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <div class="flex items-center justify-between gap-3">
              <h3
                id="copy-kanban-spec-title"
                class="text-base font-semibold flex items-center gap-2"
                style="color: var(--semantic-text);"
              >
                <span aria-hidden="true">📋</span>
                Copy spec from…
              </h3>
              <button
                type="button"
                @click="handleClose"
                data-testid="copy-kanban-spec-close"
                class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80"
                style="color: var(--semantic-text-muted);"
                title="Close"
              >
                <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
            <p
              class="text-xs mt-1"
              style="color: var(--semantic-text-dim);"
            >
              Copy the column names + descriptions from another kanban into this one. Tasks are not copied.
            </p>
          </div>

          <!-- Body -->
          <div class="px-5 py-4">
            <label
              class="block text-xs font-medium mb-2"
              style="color: var(--semantic-text-dim);"
            >
              Source kanban
            </label>
            <select
              ref="sourceSelect"
              v-model="sourceItemId"
              data-testid="copy-kanban-spec-source"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
              "
            >
              <option
                v-for="item in availableSources"
                :key="item.id"
                :value="item.id"
              >
                {{ item.name || '(unnamed)' }}
              </option>
              <option
                v-if="availableSources.length === 0"
                value=""
                disabled
              >
                No other kanbans in this workspace
              </option>
            </select>
            <p
              v-if="availableSources.length === 0"
              class="text-[11px] mt-2 italic"
              style="color: var(--semantic-text-dim);"
              data-testid="copy-kanban-spec-empty"
            >
              Create another kanban in this workspace first, then come back to copy its spec.
            </p>

            <fieldset class="mt-4">
              <legend
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                What should happen to this kanban's existing columns?
              </legend>
              <label
                class="flex items-start gap-2 px-3 py-2 rounded-lg cursor-pointer mb-1"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
              >
                <input
                  v-model="mode"
                  type="radio"
                  value="replace"
                  data-testid="copy-kanban-spec-mode-replace"
                  class="mt-1"
                />
                <span>
                  <span class="text-sm font-medium" style="color: var(--semantic-text);">Replace</span>
                  <span class="block text-[11px]" style="color: var(--semantic-text-dim);">
                    Delete every column on this kanban (existing tasks become unassigned) and replace with the source's columns.
                  </span>
                </span>
              </label>
              <label
                class="flex items-start gap-2 px-3 py-2 rounded-lg cursor-pointer"
                style="background-color: var(--semantic-sidebar-bg); border: 1px solid var(--color-border);"
              >
                <input
                  v-model="mode"
                  type="radio"
                  value="append"
                  data-testid="copy-kanban-spec-mode-append"
                  class="mt-1"
                />
                <span>
                  <span class="text-sm font-medium" style="color: var(--semantic-text);">Append</span>
                  <span class="block text-[11px]" style="color: var(--semantic-text-dim);">
                    Keep this kanban's existing columns; add the source's columns at the end.
                  </span>
                </span>
              </label>
            </fieldset>
          </div>

          <!-- Actions -->
          <div
            class="px-5 pb-5 flex justify-end gap-2"
            style="border-top: 1px solid var(--color-border); padding-top: 1rem;"
          >
            <button
              type="button"
              @click="handleClose"
              data-testid="copy-kanban-spec-cancel"
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
              @click="handleCopy"
              :disabled="!sourceItemId || availableSources.length === 0"
              data-testid="copy-kanban-spec-confirm"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
              style="
                background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                color: var(--color-bg);
              "
            >
              Copy spec
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.copy-kanban-spec-modal-enter-active,
.copy-kanban-spec-modal-leave-active {
  transition: opacity 0.2s ease;
}
.copy-kanban-spec-modal-enter-from,
.copy-kanban-spec-modal-leave-to {
  opacity: 0;
}
.copy-kanban-spec-modal-enter-active > div:last-child,
.copy-kanban-spec-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}
.copy-kanban-spec-modal-enter-from > div:last-child,
.copy-kanban-spec-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>

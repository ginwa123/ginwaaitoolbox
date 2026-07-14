<!--
  KanbanSettingsDialog — per-board settings for a single kanban.

  Layout (top → bottom):
    1. Header — kanban name + "⚙ Settings" title + close button.
    2. "Add Column" inline form (name + description) at the top.
    3. Columns list — one row per column showing:
         - Name + description (truncated 1-line)
         - "Edit" + "Delete" actions
       Inline edit swaps the row into KanbanColumnEditor (rename
       mode). Delete opens the delete confirmation.

  Public API:
    props:
      show       boolean
      item       WorkspaceItem (the active kanban)
    emits:
      close      []
      addColumn  [name: string, description: string]
      editColumn [{ columnId: string; name: string; description: string }]
      deleteColumn [columnId: string]

  This dialog is purely presentational — the host (AppLayout)
  delegates to workspacesStore actions on each emit. The dialog
  reuses KanbanColumnEditor in 'rename' / 'delete' modes so the
  add/edit/delete UX stays consistent with the existing
  per-column "⋮" menu (no parallel implementation to drift).
-->
<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'
import KanbanColumnEditor from './KanbanColumnEditor.vue'
import InlineEditableText from './InlineEditableText.vue'
import WorkspaceItemMemoriesView from './WorkspaceItemMemoriesView.vue'
import type { WorkspaceItem } from '../stores/workspaces'

type SettingsMode = 'columns' | 'memories'
const settingsMode = ref<SettingsMode>('columns')

const props = defineProps<{
  show: boolean
  item: WorkspaceItem | null
  initialMode?: SettingsMode
}>()

const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [
    payload: { columnId: string; name: string; description: string },
  ]
  deleteColumn: [columnId: string]
  /**
   * Fired when the user renames the kanban via the inline pencil
   * in the dialog header. The new name is the trimmed value the
   * user entered. The host (AppLayout) delegates to
   * workspacesStore.updateKanbanItemName.
   *
   * Plan: docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md
   */
  renameItem: [name: string]
  /**
   * Fired when the user clicks the "Copy spec from…" footer button.
   * The host (AppLayout) opens CopyKanbanSpecDialog with the
   * active kanban as the target. The dialog will emit `copy`
   * back with the chosen source + mode; AppLayout delegates
   * to workspacesStore.copyKanbanSpecFrom.
   *
   * Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
   *   (Chunk 4, Task 4.2)
   */
  copySpec: []
}>()

// ─── Add Column inline form state ────────────────────────────────────────

const newColumnName = ref('')
const newColumnDescription = ref('')
const newColumnNameInput = ref<HTMLInputElement | null>(null)
const ADD_DESCRIPTION_MAX = 500

const handleAddSubmit = () => {
  const trimmedName = newColumnName.value.trim()
  if (!trimmedName) return
  emit('addColumn', trimmedName, newColumnDescription.value.trim())
  newColumnName.value = ''
  newColumnDescription.value = ''
}

// ─── Edit / delete via the existing KanbanColumnEditor ──────────────────

type SettingsEditorMode = 'rename' | 'delete'
const showSettingsEditor = ref(false)
const settingsEditorMode = ref<SettingsEditorMode>('rename')
const settingsEditorTargetId = ref<string | null>(null)
const settingsEditorTargetName = ref('')
const settingsEditorTargetDescription = ref('')

const handleEditColumn = (columnId: string) => {
  const col = props.item?.kanban_columns?.find((c) => c.id === columnId)
  if (!col) return
  settingsEditorMode.value = 'rename'
  settingsEditorTargetId.value = columnId
  settingsEditorTargetName.value = col.name
  settingsEditorTargetDescription.value = col.description ?? ''
  showSettingsEditor.value = true
}

const handleDeleteColumn = (columnId: string) => {
  const col = props.item?.kanban_columns?.find((c) => c.id === columnId)
  if (!col) return
  settingsEditorMode.value = 'delete'
  settingsEditorTargetId.value = columnId
  settingsEditorTargetName.value = col.name
  // Description is not shown in delete mode but we forward it so
  // the KanbanColumnEditor doesn't see an old value (defensive).
  settingsEditorTargetDescription.value = col.description ?? ''
  showSettingsEditor.value = true
}

const handleSettingsEditorClose = () => {
  showSettingsEditor.value = false
  settingsEditorTargetId.value = null
}

const handleSettingsEditorRename = (name: string, description: string) => {
  if (!settingsEditorTargetId.value) return
  emit('editColumn', {
    columnId: settingsEditorTargetId.value,
    name,
    description,
  })
  showSettingsEditor.value = false
  settingsEditorTargetId.value = null
}

const handleSettingsEditorDelete = () => {
  if (!settingsEditorTargetId.value) return
  emit('deleteColumn', settingsEditorTargetId.value)
  showSettingsEditor.value = false
  settingsEditorTargetId.value = null
}

// ─── Lifecycle ──────────────────────────────────────────────────────────

// Reset the add-form on dialog open. Focus the name input so the
// user can start typing immediately. Mirrors AddKanbanDialog's
// `watch(() => props.show, ...)` pattern.
watch(
  () => props.show,
  async (show) => {
    if (show) {
      newColumnName.value = ''
      newColumnDescription.value = ''
      await nextTick()
      newColumnNameInput.value?.focus()
    }
  },
)

// Sync settingsMode when the dialog opens, respecting initialMode.
// `immediate: true` so the watcher fires on first render (without
// it, the watcher only fires on changes and the initial-mount
// `settingsMode = 'columns'` ref default would stick even when
// initialMode is 'memories' — see the Vue 3 watcher-on-mount-time
// pitfall in the project memory
// `nalar-vue-async-onmounted-test-timing.md`).
watch(
  () => [props.show, props.initialMode] as const,
  ([show, initialMode]) => {
    if (show) {
      settingsMode.value = initialMode ?? 'columns'
    }
  },
  { immediate: true },
)

const handleClose = () => {
  emit('close')
}

const handleCopySpec = () => {
  emit('copySpec')
}

const handleKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape') handleClose()
}

// Sorted copy — defensive, mirrors KanbanView's sortedColumns
// computed. Backend returns in `position ASC` order; we re-sort
// locally so a re-render during a pending reorder still looks
// sensible.
const sortedColumns = () => {
  return (props.item?.kanban_columns ?? [])
    .slice()
    .sort((a, b) => a.position - b.position)
}
</script>

<template>
  <Teleport to="body">
    <Transition name="kanban-settings-modal">
      <div
        v-if="show"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
        @keydown="handleKeydown"
        role="dialog"
        aria-modal="true"
        aria-labelledby="kanban-settings-title"
        data-testid="kanban-settings-dialog"
      >
        <!-- Backdrop -->
        <div
          class="absolute inset-0 backdrop-blur-md"
          style="background: rgba(0, 0, 0, 0.6);"
          @click="handleClose"
        />

        <!-- Dialog Card (wider than the column editor — accommodates
             the column list + per-row edit/delete actions) -->
        <div
          class="relative w-full max-w-2xl mx-4 rounded-xl shadow-2xl flex flex-col overflow-hidden"
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
          <div
            class="px-5 pt-5 pb-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
          >
            <div class="flex items-center justify-between gap-3">
              <h3
                id="kanban-settings-title"
                class="text-base font-semibold flex items-center gap-2"
                style="color: var(--semantic-text);"
              >
                <span aria-hidden="true">⚙️</span>
                Kanban Settings
                <InlineEditableText
                  v-if="item"
                  :value="item.name"
                  :placeholder="'unnamed kanban'"
                  :ariaLabel="'kanban name'"
                  :testId="`kanban-settings-rename`"
                  display-class="text-sm font-normal ml-1"
                  @save="(newName) => emit('renameItem', newName)"
                />
              </h3>
              <button
                type="button"
                @click="handleClose"
                data-testid="kanban-settings-close"
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
              Add, rename, or delete columns. The description is optional — it&apos;s the meaning of the column, shown under the name in the board view.
            </p>
          </div>

          <!-- Tab strip: Columns | Local Memories. The memories tab only
               renders when the kanban has a `path` set (otherwise local
               memories have nowhere to live). Hidden in the no-path case
               so the existing columns UI stays clean.
               Plan: docs/superpowers/plans/2026-07-21-local-memories-workspace-item.md (Task 4) -->
          <div
            v-if="item?.path"
            class="flex gap-1 px-5 pt-3 pb-0 shrink-0"
            style="border-bottom: 1px solid var(--color-border);"
            data-testid="kanban-settings-tabs"
          >
            <button
              type="button"
              @click="settingsMode = 'columns'"
              data-testid="kanban-settings-tab-columns"
              class="px-3 py-2 text-xs font-medium rounded-t-lg transition-colors"
              :style="settingsMode === 'columns'
                ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
                : 'background-color: transparent; color: var(--semantic-text-muted);'"
            >Columns</button>
            <button
              type="button"
              @click="settingsMode = 'memories'"
              data-testid="kanban-settings-tab-memories"
              class="px-3 py-2 text-xs font-medium rounded-t-lg transition-colors"
              :style="settingsMode === 'memories'
                ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
                : 'background-color: transparent; color: var(--semantic-text-muted);'"
            >🧠 Local Memories</button>
          </div>

          <!-- Columns tab body (add-form + columns list + copy-spec footer).
               Wrapped in v-if so the memories tab can swap it out via
               settingsMode. The KanbanColumnEditor lives OUTSIDE this
               wrapper at the bottom of the template so its state stays
               independent of which tab is showing.
               Plan: docs/superpowers/plans/2026-07-21-local-memories-workspace-item.md (Task 4) -->
          <template v-if="settingsMode === 'columns'">
            <!-- Add Column inline form -->
            <div
              class="px-5 py-4 shrink-0"
              style="border-bottom: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
              data-testid="kanban-settings-add-form"
            >
            <h4
              class="text-xs font-semibold mb-2"
              style="color: var(--semantic-text-dim);"
            >Add a new column</h4>
            <div class="flex gap-2 mb-2">
              <input
                ref="newColumnNameInput"
                v-model="newColumnName"
                type="text"
                placeholder="Column name"
                data-testid="kanban-settings-add-name"
                class="flex-1 px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
                style="
                  background-color: var(--semantic-card-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                @keyup.enter="handleAddSubmit"
              />
              <button
                type="button"
                @click="handleAddSubmit"
                :disabled="!newColumnName.trim()"
                data-testid="kanban-settings-add-submit"
                class="px-3 py-2 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed shrink-0"
                style="
                  background: linear-gradient(135deg, var(--color-violet), var(--color-blue));
                  color: var(--color-bg);
                "
              >
                <span aria-hidden="true">+</span>
                <span class="ml-1">Add</span>
              </button>
            </div>
            <textarea
              v-model="newColumnDescription"
              :maxlength="ADD_DESCRIPTION_MAX"
              rows="2"
              placeholder="Description (optional) — what does this column mean?"
              data-testid="kanban-settings-add-description"
              class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200 resize-y"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text);
                font-family: inherit;
              "
            ></textarea>
          </div>

          <!-- Columns list -->
          <div class="flex-1 overflow-y-auto px-5 py-3 min-h-0">
            <div
              v-if="sortedColumns().length === 0"
              class="text-center py-8"
              style="color: var(--semantic-text-dim);"
              data-testid="kanban-settings-empty"
            >
              No columns yet. Add one above to get started.
            </div>
            <ul v-else class="space-y-2" data-testid="kanban-settings-column-list">
              <li
                v-for="col in sortedColumns()"
                :key="col.id"
                :data-testid="`kanban-settings-column-row-${col.id}`"
                class="px-3 py-2.5 rounded-lg flex items-start justify-between gap-3 transition-colors duration-200"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                "
              >
                <div class="flex-1 min-w-0">
                  <div
                    class="text-sm font-medium truncate"
                    style="color: var(--semantic-text);"
                    :data-testid="`kanban-settings-column-name-${col.id}`"
                  >{{ col.name }}</div>
                  <div
                    v-if="col.description"
                    class="text-xs mt-0.5 truncate"
                    style="color: var(--semantic-text-dim);"
                    :title="col.description"
                    :data-testid="`kanban-settings-column-description-${col.id}`"
                  >{{ col.description }}</div>
                  <div
                    v-else
                    class="text-xs mt-0.5 italic"
                    style="color: var(--semantic-text-dim);"
                    :data-testid="`kanban-settings-column-description-${col.id}`"
                  >No description</div>
                </div>
                <div class="flex gap-1 shrink-0">
                  <button
                    type="button"
                    @click="handleEditColumn(col.id)"
                    :data-testid="`kanban-settings-edit-${col.id}`"
                    class="px-2 py-1 rounded text-xs font-medium transition-opacity duration-200 hover:opacity-80"
                    style="
                      background-color: var(--semantic-card-bg);
                      border: 1px solid var(--color-border);
                      color: var(--semantic-text-muted);
                    "
                  >Edit</button>
                  <button
                    type="button"
                    @click="handleDeleteColumn(col.id)"
                    :data-testid="`kanban-settings-delete-${col.id}`"
                    class="px-2 py-1 rounded text-xs font-medium transition-opacity duration-200 hover:opacity-80"
                    style="
                      background-color: var(--semantic-card-bg);
                      border: 1px solid var(--color-border);
                      color: var(--color-red, #ef4444);
                    "
                  >Delete</button>
                </div>
              </li>
            </ul>
          </div>

          <!-- Copy spec footer (per-board "copy columns from another kanban" entry point).
               Lives at the bottom of the dialog so the column list (the dialog's primary
               content) stays above the fold. Clicking emits `copySpec`; the host opens
               CopyKanbanSpecDialog over this Settings dialog (both can be open simultaneously).
               Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md (Chunk 4, Task 4.2) -->
          <div
            class="px-5 py-3 shrink-0"
            style="border-top: 1px solid var(--color-border); background-color: var(--semantic-sidebar-bg);"
          >
            <button
              type="button"
              @click="handleCopySpec"
              data-testid="kanban-settings-copy-spec"
              class="px-3 py-1.5 rounded-lg text-sm font-medium transition-opacity duration-200 hover:opacity-80"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                color: var(--semantic-text-muted);
              "
            >
              <span aria-hidden="true">📋</span>
              <span class="ml-1">Copy spec from…</span>
            </button>
            <p
              class="text-[11px] mt-2 italic"
              style="color: var(--semantic-text-dim);"
            >
              Bulk-copy column names + descriptions from another kanban in this workspace. Tasks are not copied.
            </p>
          </div>
          </template>

          <!-- Local Memories tab body. Renders the existing
               WorkspaceItemMemoriesView inside the dialog so the user
               can manage per-kanban memories without leaving settings.
               Falls back to a friendly hint when the kanban has no path
               (defensive — the tab strip is hidden in this case, but
               initialMode could still select it programmatically).
               Plan: docs/superpowers/plans/2026-07-21-local-memories-workspace-item.md (Task 4) -->
          <div
            v-else-if="settingsMode === 'memories' && item?.path"
            class="flex-1 min-h-0 overflow-hidden"
            data-testid="kanban-settings-memories-panel"
          >
            <WorkspaceItemMemoriesView
              :cwd="item.path"
              :item-name="item.name"
            />
          </div>
          <div
            v-else-if="settingsMode === 'memories' && !item?.path"
            class="flex-1 flex items-center justify-center p-8"
            data-testid="kanban-settings-memories-no-path"
          >
            <p class="text-sm" style="color: var(--semantic-text-dim);">
              No directory is set on this kanban — pick one when creating the kanban to enable local memories.
            </p>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <!--
    Reuse the existing KanbanColumnEditor in rename / delete modes
    for per-row actions. The inner state (show / mode / target) is
    owned by THIS dialog (not the AppLayout-level KanbanColumnEditor
    state) so the two dialogs can coexist independently — a user
    can open KanbanSettingsDialog while KanbanColumnEditor from
    the ⋮ menu is already showing without one clobbering the other.
  -->
  <KanbanColumnEditor
    :show="showSettingsEditor"
    :mode="settingsEditorMode"
    :initial-name="settingsEditorTargetName"
    :initial-description="settingsEditorTargetDescription"
    @close="handleSettingsEditorClose"
    @rename="handleSettingsEditorRename"
    @delete="handleSettingsEditorDelete"
  />
</template>

<style scoped>
.kanban-settings-modal-enter-active,
.kanban-settings-modal-leave-active {
  transition: opacity 0.2s ease;
}

.kanban-settings-modal-enter-from,
.kanban-settings-modal-leave-to {
  opacity: 0;
}

.kanban-settings-modal-enter-active > div:last-child,
.kanban-settings-modal-leave-active > div:last-child {
  transition:
    transform 0.22s cubic-bezier(0.16, 1, 0.3, 1),
    opacity 0.22s ease;
}

.kanban-settings-modal-enter-from > div:last-child,
.kanban-settings-modal-leave-to > div:last-child {
  transform: scale(0.96) translateY(8px);
  opacity: 0;
}
</style>
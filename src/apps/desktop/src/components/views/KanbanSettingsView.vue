<!--
  KanbanSettingsView — dedicated full-page route for per-board kanban
  settings. Replaces KanbanSettingsDialog (the centered modal that
  used to pop up when the user clicked ⚙ on a kanban board header).

  URL: /app/kanban/:itemId/settings (path-based vue-router route).
  The page reads itemId from route.params and derives workspaceId
  from the store by walking workspaces (itemId is globally unique).

  Layout (mirrors SettingsView's 240px sidebar + content panel):
    1. Left sidebar — back button + "⚙ Kanban Settings" title +
       kanban name (inline rename via InlineEditableText) + tab
       strip ("Columns" / "🧠 Local Memories"; memories tab hidden
       when item?.path is null).
    2. Right content panel:
       - Columns tab: add-column inline form + columns list with
         per-row edit/delete + copy-spec footer.
       - Memories tab: WorkspaceItemMemoriesView (renders only when
         item.path is truthy).

  Empty / not-found states render centered hints with friendly
  messages instead of the columns UI.

  Plan: docs/superpowers/plans/2026-09-02-kanban-settings-as-page.md
-->
<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import KanbanColumnEditor from '../kanban/KanbanColumnEditor.vue'
import InlineEditableText from '../preview/InlineEditableText.vue'
import WorkspaceItemMemoriesView from './WorkspaceItemMemoriesView.vue'
import { useWorkspacesStore } from '../../stores/workspaces'

type SettingsMode = 'columns' | 'memories'

const route = useRoute()
const router = useRouter()
const workspacesStore = useWorkspacesStore()

// ─── Emits ─────────────────────────────────────────────────────────────────

const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [
    payload: { columnId: string; name: string; description: string },
  ]
  deleteColumn: [columnId: string]
  renameItem: [name: string]
  copySpec: []
}>()

// ─── State ──────────────────────────────────────────────────────────────────

const settingsMode = ref<SettingsMode>('columns')

// Add-column inline form state
const newColumnName = ref('')
const newColumnDescription = ref('')

// Per-row rename/delete editor (lifted from KanbanSettingsDialog's
// KanbanColumnEditor). Owns its own state so the page can open the
// editor independently of any other KanbanColumnEditor mounted by
// AppLayout for the ⋮ menu flow.
type SettingsEditorMode = 'rename' | 'delete'
const showSettingsEditor = ref(false)
const settingsEditorMode = ref<SettingsEditorMode>('rename')
const settingsEditorTargetId = ref<string | null>(null)
const settingsEditorTargetName = ref('')
const settingsEditorTargetDescription = ref('')

// ─── Computed ──────────────────────────────────────────────────────────────

// itemId comes from route.params (path). May be empty if the URL is
// malformed — defensive: render the "no kanban selected" hint.
const itemId = computed<string>(() => {
  const raw = route.params.itemId
  return typeof raw === 'string' ? raw : ''
})

// Look up the kanban WorkspaceItem across all workspaces. itemId is
// globally unique (workspace_items.id is the PK), so we don't need
// to filter by workspaceId first — but we still derive workspaceId
// below for the back navigation round-trip.
const item = computed(() => {
  const id = itemId.value
  if (!id) return null
  for (const ws of workspacesStore.workspaces) {
    const found = ws.items.find((i) => i.id === id)
    if (found) return found
  }
  return null
})

// Derive workspaceId by walking the store looking for the workspace
// that owns the current item. Returns '' if the item isn't found
// (defensive — goBack uses this to round-trip back to the kanban
// view; if we can't find the owning workspace, fall back to /app).
const workspaceId = computed<string>(() => {
  const id = itemId.value
  if (!id) return ''
  for (const ws of workspacesStore.workspaces) {
    if (ws.items.some((i) => i.id === id)) return ws.id
  }
  return ''
})

const notFound = computed(() => !!itemId.value && !item.value)
const emptyHint = computed(() => !itemId.value)

// ─── Handlers (mirror KanbanSettingsDialog 1:1) ────────────────────────────

const handleAddSubmit = () => {
  const trimmedName = newColumnName.value.trim()
  if (!trimmedName) return
  emit('addColumn', trimmedName, newColumnDescription.value.trim())
  newColumnName.value = ''
  newColumnDescription.value = ''
}

const handleEditColumn = (columnId: string) => {
  const col = item.value?.kanban_columns?.find((c) => c.id === columnId)
  if (!col) return
  settingsEditorMode.value = 'rename'
  settingsEditorTargetId.value = columnId
  settingsEditorTargetName.value = col.name
  settingsEditorTargetDescription.value = col.description ?? ''
  showSettingsEditor.value = true
}

const handleDeleteColumn = (columnId: string) => {
  const col = item.value?.kanban_columns?.find((c) => c.id === columnId)
  if (!col) return
  settingsEditorMode.value = 'delete'
  settingsEditorTargetId.value = columnId
  settingsEditorTargetName.value = col.name
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

// ─── Navigation ────────────────────────────────────────────────────────────

const goBack = () => {
  // The workspaceId is derived from the store (workspaceId computed
  // above). itemId comes from route.params. If either is missing,
  // fall back to /app so the user doesn't get stuck.
  const wsId = workspaceId.value
  const itId = itemId.value
  if (wsId && itId) {
    router.replace({
      path: '/app',
      query: { view: 'workspace', workspaceId: wsId, itemId: itId },
    })
  } else {
    router.replace({ path: '/app' })
  }
}

// ─── Lifecycle ─────────────────────────────────────────────────────────────

// Reset settingsMode when the route changes (so navigating from one
// kanban's settings to another's starts on the Columns tab, not the
// Memories tab that the previous kanban had selected).
watch(
  () => itemId.value,
  () => {
    settingsMode.value = 'columns'
    showSettingsEditor.value = false
    settingsEditorTargetId.value = null
  },
)

// ─── Helpers ───────────────────────────────────────────────────────────────

// Sorted copy — mirrors KanbanView's sortedColumns computed so a
// re-render during a pending reorder still looks sensible.
function sortedColumns() {
  return (item.value?.kanban_columns ?? [])
    .slice()
    .sort((a, b) => a.position - b.position)
}
</script>

<template>
  <div
    class="flex h-full"
    style="background-color: var(--semantic-content-bg)"
    data-testid="kanban-settings-page"
  >
    <!-- Left sidebar (240px wide, mirrors SettingsView) -->
    <div
      class="h-full flex flex-col shrink-0"
      style="
        width: 240px;
        background-color: var(--semantic-sidebar-bg);
        border-right: 1px solid var(--color-border);
      "
    >
      <!-- Header: back button + page title -->
      <div
        class="h-14 flex items-center px-4 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <button
          type="button"
          @click="goBack"
          class="w-8 h-8 rounded-lg flex items-center justify-center transition-colors duration-200 hover:opacity-80 mr-3"
          style="color: var(--semantic-text-muted)"
          title="Back to kanban"
          data-testid="kanban-settings-page-back"
        >
          <svg
            class="w-5 h-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 19l-7-7 7-7"
            />
          </svg>
        </button>
        <h1
          class="text-base font-semibold flex items-center gap-2"
          style="color: var(--semantic-text)"
          data-testid="kanban-settings-page-title"
        >
          <span aria-hidden="true">⚙️</span>
          <span>Kanban Settings</span>
        </h1>
      </div>

      <!-- Kanban name + tab strip -->
      <div
        v-if="item"
        class="flex-1 flex flex-col overflow-hidden"
      >
        <!-- Inline rename (mirrors KanbanSettingsDialog header pattern) -->
        <div class="px-4 pt-3 pb-2">
          <InlineEditableText
            :value="item.name"
            :placeholder="'unnamed kanban'"
            :ariaLabel="'kanban name'"
            :testId="`kanban-settings-page-rename`"
            display-class="text-sm font-normal"
            @save="(newName) => emit('renameItem', newName)"
          />
        </div>

        <!-- Tab strip: Columns | Local Memories. Hidden when no path. -->
        <div
          v-if="item?.path"
          class="flex gap-1 px-4 pt-2 pb-0 shrink-0"
          style="border-bottom: 1px solid var(--color-border)"
          data-testid="kanban-settings-page-tabs"
        >
          <button
            type="button"
            @click="settingsMode = 'columns'"
            data-testid="kanban-settings-page-tab-columns"
            class="px-3 py-2 text-xs font-medium rounded-t-lg transition-colors"
            :style="
              settingsMode === 'columns'
                ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
                : 'background-color: transparent; color: var(--semantic-text-muted);'
            "
          >
            Columns
          </button>
          <button
            type="button"
            @click="settingsMode = 'memories'"
            data-testid="kanban-settings-page-tab-memories"
            class="px-3 py-2 text-xs font-medium rounded-t-lg transition-colors"
            :style="
              settingsMode === 'memories'
                ? 'background-color: var(--semantic-card-bg); color: var(--semantic-text); border: 1px solid var(--color-border); border-bottom-color: var(--semantic-card-bg); margin-bottom: -1px;'
                : 'background-color: transparent; color: var(--semantic-text-muted);'
            "
          >
            🧠 Local Memories
          </button>
        </div>
      </div>
    </div>

    <!-- Right content panel -->
    <main class="flex-1 flex flex-col overflow-hidden">
      <!-- Empty / not-found hints (centered) -->
      <div
        v-if="emptyHint"
        class="flex-1 flex items-center justify-center p-8"
        data-testid="kanban-settings-page-no-item"
      >
        <p class="text-sm" style="color: var(--semantic-text-dim)">
          No kanban selected. Open this page from a kanban board's ⚙ Settings button.
        </p>
      </div>
      <div
        v-else-if="notFound"
        class="flex-1 flex items-center justify-center p-8"
        data-testid="kanban-settings-page-not-found"
      >
        <p class="text-sm" style="color: var(--semantic-text-dim)">
          That kanban doesn't exist or has been deleted.
        </p>
      </div>

      <!-- Columns tab body (add-form + columns list + copy-spec footer) -->
      <template v-else-if="settingsMode === 'columns'">
        <!-- Add Column inline form -->
        <div
          class="px-5 py-4 shrink-0"
          style="
            border-bottom: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
          "
          data-testid="kanban-settings-page-add-form"
        >
          <h4
            class="text-xs font-semibold mb-2"
            style="color: var(--semantic-text-dim)"
          >
            Add a new column
          </h4>
          <div class="flex gap-2 mb-2">
            <input
              v-model="newColumnName"
              type="text"
              placeholder="Column name"
              data-testid="kanban-settings-page-add-name"
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
              data-testid="kanban-settings-page-add-submit"
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
            :maxlength="500"
            rows="2"
            placeholder="Description (optional) — what does this column mean?"
            data-testid="kanban-settings-page-add-description"
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
            style="color: var(--semantic-text-dim)"
            data-testid="kanban-settings-page-empty"
          >
            No columns yet. Add one above to get started.
          </div>
          <ul
            v-else
            class="space-y-2"
            data-testid="kanban-settings-page-column-list"
          >
            <li
              v-for="col in sortedColumns()"
              :key="col.id"
              :data-testid="`kanban-settings-page-column-row-${col.id}`"
              class="px-3 py-2.5 rounded-lg flex items-start justify-between gap-3 transition-colors duration-200"
              style="
                background-color: var(--semantic-sidebar-bg);
                border: 1px solid var(--color-border);
              "
            >
              <div class="flex-1 min-w-0">
                <div
                  class="text-sm font-medium truncate"
                  style="color: var(--semantic-text)"
                  :data-testid="`kanban-settings-page-column-name-${col.id}`"
                >
                  {{ col.name }}
                </div>
                <div
                  v-if="col.description"
                  class="text-xs mt-0.5 truncate"
                  style="color: var(--semantic-text-dim)"
                  :title="col.description"
                  :data-testid="`kanban-settings-page-column-description-${col.id}`"
                >
                  {{ col.description }}
                </div>
                <div
                  v-else
                  class="text-xs mt-0.5 italic"
                  style="color: var(--semantic-text-dim)"
                  :data-testid="`kanban-settings-page-column-description-${col.id}`"
                >
                  No description
                </div>
              </div>
              <div class="flex gap-1 shrink-0">
                <button
                  type="button"
                  @click="handleEditColumn(col.id)"
                  :data-testid="`kanban-settings-page-edit-${col.id}`"
                  class="px-2 py-1 rounded text-xs font-medium transition-opacity duration-200 hover:opacity-80"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    color: var(--semantic-text-muted);
                  "
                >
                  Edit
                </button>
                <button
                  type="button"
                  @click="handleDeleteColumn(col.id)"
                  :data-testid="`kanban-settings-page-delete-${col.id}`"
                  class="px-2 py-1 rounded text-xs font-medium transition-opacity duration-200 hover:opacity-80"
                  style="
                    background-color: var(--semantic-card-bg);
                    border: 1px solid var(--color-border);
                    color: var(--color-red, #ef4444);
                  "
                >
                  Delete
                </button>
              </div>
            </li>
          </ul>
        </div>

        <!-- Copy spec footer -->
        <div
          class="px-5 py-3 shrink-0"
          style="
            border-top: 1px solid var(--color-border);
            background-color: var(--semantic-sidebar-bg);
          "
        >
          <button
            type="button"
            @click="emit('copySpec')"
            data-testid="kanban-settings-page-copy-spec"
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
            style="color: var(--semantic-text-dim)"
          >
            Bulk-copy column names + descriptions from another kanban in this workspace. Tasks are not copied.
          </p>
        </div>
      </template>

      <!-- Memories tab body -->
      <div
        v-else-if="settingsMode === 'memories' && item?.path"
        class="flex-1 min-h-0 overflow-hidden"
        data-testid="kanban-settings-page-memories-panel"
      >
        <WorkspaceItemMemoriesView
          :cwd="item.path"
          :item-name="item.name"
        />
      </div>
      <div
        v-else-if="settingsMode === 'memories' && !item?.path"
        class="flex-1 flex items-center justify-center p-8"
        data-testid="kanban-settings-page-memories-no-path"
      >
        <p class="text-sm" style="color: var(--semantic-text-dim)">
          No directory is set on this kanban — pick one when creating the kanban to enable local memories.
        </p>
      </div>
    </main>

    <!--
      Per-row rename/delete editor (lifted from KanbanSettingsDialog).
      The state is owned by THIS view so the editor can open
      independently of any AppLayout-level KanbanColumnEditor (e.g.
      the one mounted for the ⋮ menu flow).
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
  </div>
</template>
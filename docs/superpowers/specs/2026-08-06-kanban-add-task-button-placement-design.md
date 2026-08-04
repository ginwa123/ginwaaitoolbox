# Kanban — Move "+ Add task" to a proper place (header + dropdown column picker)

**Date:** 2026-08-06
**Worktree:** `~/.worktrees/kanban-add-button-placement` (branch: `worktree/kanban-add-button-placement`)
**Task:** `task_1785865184856` — "move button add task kanban to a proper place"
**User goal:** The "+ Add task" affordance currently lives as a full-width button in the **footer of every kanban column** (KanbanColumn.vue lines 830–849). The user wants a single global button in the kanban header (next to the search input), with column selection promoted to a dropdown inside the create dialog — so "only one button" exists for the entire board.

---

## 1. Context & current state

### 1.1 What the user sees today

Per the screenshot accompanying the task, every kanban column ends with a full-width `+ Add` button in a bordered footer. The board has 7 columns, so there are 7 identical `+ Add` buttons. This is the only path to create a new task.

The kanban header (lines 996–1063 in `KanbanView.vue`) currently contains:
- `InlineEditableText` for the kanban name (left)
- Yellow `⚠️ Set project root` banner (when `item.path` is null)
- `<KanbanSearchInput v-model="searchQuery" />`
- `⚙️ Settings` button (right)

The button the user wants goes between the search input and the settings button.

### 1.2 What already exists (anchor surface)

- `KanbanTaskDetailDialog.vue` in `mode="create"` already renders a **read-only column label** in the metadata strip (lines 700–707). The `column` prop is bound from `KanbanView.vue::activeCreateColumn` (a computed that resolves `activeCreateColumnId` against the columns list). This is the natural place to swap the static text for a dropdown — the parent already wires the column ref through.
- The dialog already has a precedent for in-dialog dropdowns: the **profile picker** at lines 831–901 mirrors the exact UX we want (button-styled trigger + dropdown with `✓` checkmark + click-outside + closed-then-reopened). Reuse the same pattern for the column picker.
- `KanbanView.vue::handleViewCreateTask(columnId)` (line 761) already does "open the create dialog with column X pre-selected". The new header button just calls this function with the **first column** by default.

### 1.3 What touches this

Files in the worktree that change:

| File | Role |
|---|---|
| `src/apps/desktop/src/components/kanban/KanbanColumn.vue` | **Remove** the footer "+ Add" button + emit + handler |
| `src/apps/desktop/src/components/kanban/KanbanView.vue` | **Add** the header "+ Add task" button + wire open |
| `src/apps/desktop/src/components/kanban/KanbanTaskDetailDialog.vue` | **Replace** the read-only column strip with a dropdown in create mode |
| `src/apps/desktop/src/__tests__/KanbanColumn.spec.ts` | **Delete** the "footer add" describe block |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts` | **Update** the create-dialog tests to drive the header button (+ new tests) |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts` | **Add** column-dropdown tests for create mode |

No backend, DB, or migration touch. The `addTask` + `moveTaskToColumn` flow (KanbanView.vue lines 819–880) is unchanged.

---

## 2. Design

### 2.1 High-level UX

- **One button** in the kanban header — between the search input and the Settings button. The label is `➕ Add task` (icon + text). Disabled when the kanban has zero columns.
- The button opens the **existing `KanbanTaskDetailDialog` in `mode="create"`** with the **first column** pre-selected.
- Inside the dialog, the previously read-only **column label** becomes an **interactive dropdown** (in create mode only). The user picks the column, fills the form, clicks `Create task` (or `Create task & run agent`).
- The dropdown defaults to the `column` prop KanbanView passes in. Switching columns inside the dialog updates `KanbanView.activeCreateColumnId` via a new `column-change` emit, so the `moveTaskToColumn` step on submit places the new task in the right column.
- **Edit mode is unchanged** — the column is still shown as a read-only strip (the task is already in a column; column cannot be changed mid-edit).

### 2.2 Header button (`KanbanView.vue`)

**Placement** (in the `<header>` block, line 996):

```
[Kanban name]  [⚠️ Set project root banner]  [KanbanSearchInput]  [➕ Add task]  [⚙️ Settings]
```

**Visual** (mirrors the existing Settings button so the two feel like a matching pair):

```html
<button
  type="button"
  @click="handleOpenCreateDialog"
  :disabled="!sortedColumns.length"
  class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
  style="
    background-color: var(--semantic-sidebar-bg);
    border: 1px solid var(--color-border);
    color: var(--semantic-text-muted);
  "
  :title="sortedColumns.length ? 'Add a task to this kanban' : 'Add columns first in Settings'"
  data-testid="kanban-add-task-button"
>
  <span aria-hidden="true">➕</span>
  <span class="ml-1">Add task</span>
</button>
```

**Behavior**:

```ts
const handleOpenCreateDialog = () => {
  const firstColumn = sortedColumns.value[0]
  if (!firstColumn) return  // disabled button covers this, but defensive
  handleViewCreateTask(firstColumn.id)
}
```

The existing `handleViewCreateTask(columnId)` (line 761) is unchanged — it just opens the create dialog with the given column. The header button reuses it.

### 2.3 Remove per-column footer (`KanbanColumn.vue`)

**Delete**:

- `<footer>` block (lines 830–849) — the dashed border, the `+ Add` button, the `handleAddClick` handler.
- `handleAddClick` function (lines 569–573).
- `addTask` emit from `defineEmits` (line 69).
- `data-testid="kanban-column-{id}-add-task"` (no longer exists).
- `:data-testid="kanban-column-{column.id}-add-task"` references in tests.

**Keep**:

- The `cardsInColumn` computed (no change).
- The empty-state placeholder (`<div v-if="cardsInColumn.length === 0">No tasks yet</div>`) — unchanged. With one global add button, the empty column still shows "No tasks yet" as a hint. The user clicks the header button to add to ANY column.

**Why remove the footer entirely (not just empty it)**:**

- Removing the footer shrinks each column by ~44px (footer was `px-3 py-2` + button `py-1.5`). On a 7-column board at default zoom this is a meaningful vertical real-estate win.
- The dashed border on the footer (`border-top: 1px solid var(--color-border)`) was a visual cue that the footer is "below the cards". Removing the footer removes the border too. Cards now butt against the column's bottom edge — cleaner.

**Tests**:

- `KanbanColumn.spec.ts` lines 231–249 — DELETE the `describe('KanbanColumn — footer add', ...)` block. The single test (`clicking "+ Add" emits add-task with the column id`) no longer applies.

### 2.4 Column dropdown in the dialog (`KanbanTaskDetailDialog.vue`)

**Replace the read-only column strip** (lines 699–707) with an interactive dropdown **only in create mode**:

```html
<!-- BEFORE (all modes, read-only) -->
<span v-if="columnLabel" data-testid="kanban-task-detail-column">
  {{ columnLabel }}
</span>

<!-- AFTER (create mode only, interactive) -->
<div v-if="isCreateMode && availableColumns.length > 0" ref="columnPickerRef" class="relative">
  <button
    type="button"
    @click.stop="toggleColumnPicker"
    class="px-2 py-0.5 rounded text-xs hover:opacity-80 inline-flex items-center gap-1"
    style="
      background-color: var(--semantic-sidebar-bg);
      border: 1px solid var(--color-border);
      color: var(--semantic-text);
    "
    data-testid="kanban-task-detail-column-picker"
  >
    <span>{{ columnLabel }}</span>
    <span class="text-[10px]">▾</span>
  </button>
  <div
    v-if="isColumnPickerOpen"
    class="absolute top-full mt-1 left-0 min-w-[180px] rounded-lg shadow-lg z-20 overflow-hidden"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
    "
    data-testid="kanban-task-detail-column-picker-dropdown"
    @click.stop
  >
    <button
      v-for="col in availableColumns"
      :key="col.id"
      type="button"
      @click="selectColumn(col.id)"
      class="w-full text-left px-3 py-2 text-xs hover:opacity-80 flex items-center justify-between"
      style="color: var(--semantic-text); border-top: 1px solid var(--color-border);"
      :data-testid="`kanban-task-detail-column-picker-item-${col.id}`"
    >
      <span class="font-medium">{{ col.name }}</span>
      <span v-if="selectedColumnId === col.id">✓</span>
    </button>
  </div>
</div>

<!-- Edit mode: unchanged (read-only strip) -->
<span v-else-if="columnLabel" data-testid="kanban-task-detail-column">
  {{ columnLabel }}
</span>
```

**New props** (in create mode only — these are optional and only consulted when `mode === 'create'`):

```ts
const props = withDefaults(
  defineProps<{
    /// ... existing
    // NEW (plan: 2026-08-06-kanban-add-task-button-placement). The
    // available columns for the create-mode column dropdown. Empty
    // array = no dropdown rendered (legacy tests + kanbans that
    // haven't loaded columns yet). Edit mode passes empty.
    availableColumns?: KanbanColumn[]
  }>(),
  { availableColumns: [] },
)
```

**New local state**:

```ts
const selectedColumnId = ref<string | null>(props.column?.id ?? null)
const isColumnPickerOpen = ref(false)
const columnPickerRef = ref<HTMLElement | null>(null)

// When the dialog opens or the parent passes a new `column` prop,
// re-sync the selectedColumnId (covers the case where KanbanView
// points at a different column via a future API).
watch(
  () => [props.show, props.column?.id] as const,
  ([show, _columnId]) => {
    if (show && isCreateMode.value) {
      selectedColumnId.value = props.column?.id ?? null
    }
  },
)

const toggleColumnPicker = () => {
  isColumnPickerOpen.value = !isColumnPickerOpen.value
}
const selectColumn = (id: string) => {
  selectedColumnId.value = id
  isColumnPickerOpen.value = false
  emit('column-change', id)
}

// Click outside the picker closes it (mirrors profile picker behaviour).
const handleDocumentClickColumn = (event: MouseEvent) => {
  if (!isColumnPickerOpen.value) return
  const target = event.target as Node | null
  if (columnPickerRef.value && target && !columnPickerRef.value.contains(target)) {
    isColumnPickerOpen.value = false
  }
}
onMounted(() => document.addEventListener('click', handleDocumentClickColumn))
onUnmounted(() => document.removeEventListener('click', handleDocumentClickColumn))
```

**New emit**:

```ts
const emit = defineEmits<{
  /// ... existing
  // NEW. Create mode only. Fires when the user picks a different
  // column from the dropdown. The parent (KanbanView) updates
  // `activeCreateColumnId` so the final `moveTaskToColumn` puts
  // the new task in the selected column. Fires in addition to the
  // existing `create` / `create-and-run` emits at submit time —
  // the submit emit's column is the source of truth at submit.
  'column-change': [columnId: string]
}>()
```

**Wire the create / create-and-run payload**:

The dialog's `create` + `create-and-run` emits currently carry only `name`, `description`, `tags`, `is_auto_retry_until_stop`, `selectedProfile`, `pendingFiles`. The column is implicit — the parent already knows it via `activeCreateColumnId`. **No payload change needed.** The parent will read `selectedColumnId` from the new emit when handling the submit, OR (simpler) the parent just reads its own `activeCreateColumnId` ref at submit time — which is already what it does. The `column-change` emit is a real-time mirror so the host's reactive state stays in sync if the host needs to display the current target column anywhere else.

### 2.5 Wire the parent (`KanbanView.vue`)

**Listen for the new emit** on the create-mode dialog:

```html
<KanbanTaskDetailDialog
  v-model:show="showCreateDialog"
  mode="create"
  :task="null"
  :column="activeCreateColumn"
  :available-columns="sortedColumns"
  :cwd="item.path || ''"
  :workspace-id="workspaceId"
  :error-message="createError"
  @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create' })"
  @create-and-run="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })"
  @column-change="(columnId) => activeCreateColumnId = columnId"
/>
```

**Behaviour**: when the user changes the column in the dropdown, `activeCreateColumnId` updates immediately. The watch on `activeCreateColumn` (line 751) re-runs, `activeCreateColumn` computed re-evaluates, the dialog's `column` prop re-resolves. The dropdown's `selectedColumnId` watch is then re-fired in the dialog (the `[show, column?.id]` watcher above) — but our local `selectedColumnId` will already match the new value because the user just clicked it. **No infinite loop** — the same-value watcher no-ops.

---

## 3. Edge cases

| Edge case | Behaviour |
|---|---|
| Kanban has **zero columns** | Header button is **disabled** (`disabled` + `title="Add columns first in Settings"`). The button stays visible so users know the affordance exists. |
| Kanban has **1 column** | Dropdown is shown with the single item + ✓ checkmark. User clicks `+ Add task` → dialog opens with the column pre-selected. Visually consistent with multi-column. |
| **Single column** + **disabled first-column auto-select** | The header button calls `handleViewCreateTask(firstColumn.id)` with the only column. The dialog opens with the column pre-selected. |
| User clicks dropdown, **changes column**, then clicks Create | `column-change` fires → `activeCreateColumnId` updates → `moveTaskToColumn(taskId, selectedColumnId, 0)` puts the task in the chosen column at position 0. |
| User **opens the dialog, changes column, then closes without creating** | `activeCreateColumnId` was updated. Next time the user clicks `+ Add task` in the header, the FIRST column is used (not the stale one). The header button does NOT preserve the previous column state — fresh open = first column. **(Rationale: matches user expectation of "Add task" = open the form in the default state.**)** |
| User **clicks the dropdown, hovers off, clicks outside** | Click-outside handler closes the dropdown (mirrors profile picker). |
| **Edit mode** dialog | Column is shown as a **read-only** strip (unchanged). The dropdown is gated on `isCreateMode`. |
| Tests mock `props.column = null` (no column provided) | Dropdown is hidden (no `v-if` match). The `selectedColumnId` ref starts as `null`. Submit can still proceed — the parent falls back to `activeCreateColumn.value?.id?.length ? ... : (first column)` (existing behaviour in `handleCreateTaskSave`). |
| User creates a task via `+ Add task` header, the **create succeeds**, then the user clicks `+ Add task` again | The dialog re-opens with `activeCreateColumnId = sortedColumns[0]?.id` (the header button resets the column every open). The dropdown's `selectedColumnId` watcher re-syncs from the new `column` prop. |

---

## 4. Tests

### 4.1 `KanbanColumn.spec.ts`

**Delete** (lines 231–249):

```ts
describe('KanbanColumn — footer add', () => {
  let wrapper: VueWrapper | null = null
  beforeEach(() => { setActivePinia(createPinia()) })
  afterEach(() => { wrapper?.unmount(); wrapper = null; vi.restoreAllMocks() })
  it('clicking "+ Add" emits add-task with the column id', async () => { ... })
})
```

No replacement — the footer add button no longer exists.

### 4.2 `KanbanView.spec.ts`

**Update** the existing `KanbanView — create-task flow` describe block (lines 598–onward):

- The helper `mountAndOpenDialog` currently triggers `kanban-column-col_x-add-task` — change the testid to `kanban-add-task-button` (the new header button).
- The assertions (saves via `addTask`, moves to chosen column) stay the same — the underlying flow is unchanged.

**Add** new tests:

1. `header + Add task button is disabled when there are no columns` — mount with `kanban_columns: []`, assert the button is `disabled` and the testid is `kanban-add-task-button`.
2. `header + Add task button is enabled when at least one column exists` — mount with 1 column, assert not disabled.
3. `clicking header + Add task opens the create dialog with the first column pre-selected` — mount with 2 columns, click the button, assert the dialog shows with the first column (`col_x`) selected.
4. `column-change in the dialog updates the active create column (so moveTaskToColumn uses the right column at submit)` — mount with 2 columns, click the button, change the dropdown to `col_y`, fill name, submit → assert `moveTaskToColumn` was called with `col_y` (not `col_x`).

### 4.3 `KanbanTaskDetailDialog.spec.ts`

**Add** new tests:

1. `create mode: column is rendered as a dropdown button (not a static text)` — mount with `mode="create"`, `column={ name: 'todo', id: 'col_x' }`, `availableColumns=[col_x, col_y]`, assert the `kanban-task-detail-column-picker` testid exists and the static `kanban-task-detail-column` testid does NOT.
2. `create mode: column dropdown defaults to the column prop` — assert the dropdown button's text starts with `'todo'`.
3. `create mode: clicking the dropdown opens the picker, picking a column emits column-change` — click the dropdown, click the second item, assert `column-change` fired with `'col_y'`.
4. `create mode: single-column kanban — dropdown still renders with the single item + checkmark` — mount with `availableColumns=[col_x]`, assert the dropdown renders and the item has the `✓` indicator.
5. `edit mode: column is rendered as a static text strip (no dropdown)` — mount with `mode="edit"`, `task={...}`, `column={...}`, assert the static `kanban-task-detail-column` testid exists and the `kanban-task-detail-column-picker` testid does NOT.
6. `create mode: click outside the dropdown closes it` — open the dropdown, dispatch a click on `document.body`, assert the dropdown is gone.

---

## 5. Out of scope (deferred)

- **In-column "+ Add" empty-state button** — The user said "only one button". We're not adding an in-column "+ Add" link when the column is empty. The "No tasks yet" placeholder is kept as-is.
- **Keyboard shortcut for "+ Add task"** — could add `c` or `n` later. Not in this PR.
- **Drag-and-drop from outside the kanban into a specific column** — separate UX concern.
- **Animated column reorder preview while the dropdown is open** — not relevant to this PR.
- **Bulk-add task via CSV** — separate feature.

---

## 6. Verification checklist

```bash
cd ~/.worktrees/kanban-add-button-placement

# Frontend type-check + build
timeout 180 bun run build 2>&1 | tail -n 20

# Frontend tests (the new + deleted tests)
timeout 240 bunx vitest run src/__tests__/KanbanColumn.spec.ts src/__tests__/KanbanView.spec.ts src/__tests__/KanbanTaskDetailDialog.spec.ts 2>&1 | tail -n 40

# Full test suite (regression check)
timeout 240 bunx vitest run 2>&1 | tail -n 20

# Backend tests (no backend change, but verify nothing broke)
timeout 180 zig build test --summary all
```

Pre-fix baseline: `bunx vitest run` full suite is 2100 pass / 19 fail (the 19 are the documented pre-existing baseline per `AGENTS.md`). Post-fix expectation: same 2100 pass / 19 fail — no regressions, new tests added on top.

Live smoke: open the kanban at `http://localhost:8080` → confirm:
- The header has a `+ Add task` button (next to search).
- No `+ Add` footers on columns.
- Clicking the header button opens the create dialog with a column dropdown (defaults to the first column).
- Picking a different column in the dropdown + filling the form + clicking `Create task` puts the task in the chosen column.

---

## 7. Pitfalls (record for the agent writing this)

- **Don't add the column dropdown to EDIT mode** — the task is already in a column, and migrating it to a new column is a separate op (not in this scope). Edit mode keeps the read-only strip.
- **The profile picker is rendered at the BOTTOM of the dialog body** (below the description + tags). The column picker is rendered in the METADATA STRIP at the TOP of the dialog body (between the name input and the description). Different visual positions; same dropdown pattern.
- **The dropdown's `column-change` emit must NOT trigger a re-pull of `selectedColumnId`** — the dialog's watcher on `[show, column?.id]` re-syncs from the parent, but that's the ROOT OF TRUTH for the initial state. The user's click is the source of truth once they've picked. The two are equal at the moment of click, so no infinite loop.
- **Don't remove the `activeCreateColumn` computed (KanbanView.vue line 751)** — it's still used by the dialog's `column` prop. The new emit drives it, but the computed stays.
- **The disabled button SHOULD still be visible** — hiding the affordance surprises users who expect a kanban to have an add button. The `title` attribute explains why it's disabled.
- **The header button uses `sortedColumns`.** If the user has reordered columns via drag, the new "first" column is the one at position 0 (the actual leftmost). That matches the user's intuition of "where do I add to?".
- **vue-tsc + vitest BOTH need to pass.** Per the project's `nalar-frontend-patterns` memory, `bun run build` runs `vue-tsc --build` (type-check) and `bunx vitest run` runs runtime tests. The new `availableColumns` prop is `KanbanColumn[]` — type the same as the existing `column` prop to avoid TS type errors.
- **The dropdown's `z-20` is intentional** — the dialog body's `overflow-y-auto` CAN clip dropdowns that go below the visible area. The dropdown renders INSIDE the metadata strip, so it scrolls with the body. None of the column names will be long enough to clip, but if a future column has a 200-char name, the dropdown will be clipped. Acceptable for v1 — no kanban has names that long today.

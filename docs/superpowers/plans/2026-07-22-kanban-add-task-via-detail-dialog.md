# Plan: Use KanbanTaskDetailDialog for "Add Task" in Kanban Mode

## Goal

Replace `AddTaskDialog.vue` with `KanbanTaskDetailDialog.vue` when adding a task in kanban mode. The "+ Add" button on a kanban column should open the existing detail dialog (which has a richer description textarea and a column-aware metadata strip) in **create** mode rather than the small "Standard Chat" modal.

The `AddTaskDialog` is preserved for non-kanban parents (workspace items whose `item_type !== 'kanban'`), where it remains the right choice for a quick "create a chat task" flow.

## Current State (verified)

### Code paths

1. **`KanbanColumn.vue:498-503`** — Footer "+ Add" button → emits `addTask` with `columnId`.
2. **`KanbanView.vue:351`** — `<KanbanColumn ... @add-task="(columnId) => emit('addTask', { columnId })" />` re-emits upward.
3. **`AppLayout.vue:860-869`** — `handleKanbanAddTask` calls `sidebarRef.value?.openStandardTaskDialog(ws.id, activeWorkspaceItem.value.id)`.
4. **`Sidebar.vue:109-113`** — `openStandardTaskDialog` sets state and flips `showAddTaskDialog = true`.
5. **`Sidebar.vue:1195`** — `<AddTaskDialog :show="showAddTaskDialog" ... />` mounted at the sidebar root.
6. **`Sidebar.vue:644-666`** — `handleAddTaskCreated` calls `workspacesStore.addTask(...)`, navigates to the new task, and closes the dialog.

### Why this needs to change

The screenshot in the task shows the kanban's "todo" column with three small tasks (`design mode ...`, `new agent too...`, `frontend kanb...`). The "+ Add" button at the bottom opens `AddTaskDialog`, which:
- Shows only a 3-row description (vs. KanbanTaskDetailDialog's 10-row).
- Has no column context (the column the user picked is silently dropped — `columnId` is logged as TODO but never reaches `addTask`).
- Does not show the "📋 todo · Standard" metadata strip that the detail dialog already renders.
- Auto-navigates to the new task, breaking the user's kanban context.

The user wants to use `KanbanTaskDetailDialog` so the create flow has the same UX as the edit flow. We add a `mode: 'edit' | 'create'` prop and a `column` context prop.

### Backend constraints

- `createTask` in `api/index.ts:493-528` posts to `/workspaces/:wsId/items/:itemId/tasks`. No `kanban_column_id` field is supported.
- `task_create.zig:362-410` auto-assigns newly-created kanban tasks to the **first** column at position `MAX+1`.
- After create, `moveTaskToColumn(workspaceId, itemId, taskId, columnId, position)` (workspaces store:982) reassigns to the desired column. The store sets `kanban_column_id` + `kanban_position` locally and calls `api.moveTask` — the move endpoint DOES accept `kanban_column_id`.

So the create flow is:
1. `workspacesStore.addTask(...)` → creates at first column (backend default).
2. `workspacesStore.moveTaskToColumn(ws.id, item.id, newTaskId, desiredColumnId, 0)` → moves to user's chosen column at position 0 (top).

The backend's auto-assign to the first column is acceptable because the subsequent `moveTaskToColumn` immediately overwrites it. No backend change needed.

## Design Decisions

### D1 — Single component, mode prop

Keep one `KanbanTaskDetailDialog.vue` with a `mode: 'edit' | 'create'` prop. Default is `'edit'` (backward compatible). Why single component:
- Same UX, same form, same metadata strip — only the header icon/title, the initial form state, and the save emit behavior differ.
- Avoids duplicating the rich description textarea, validation, and metadata helpers across two files.

### D2 — Add `column` prop (optional)

Already exists for edit mode. In create mode, the column is **required** (we need it to know where to put the task). The metadata strip renders the column name as visual context — same UX as edit mode where the task already lives in the column.

### D3 — `save` emit becomes a discriminated payload

Today the dialog emits `{ name, description }`. After this change:
- Edit mode: emits `{ mode: 'edit', name, description }`.
- Create mode: emits `{ mode: 'create', name, description }`.

This makes the parent handler trivial — single switch on `payload.mode`. Backward compatible at the test level (existing tests assert the first arg of the emit, which is the payload object — adding `mode` to the object means those assertions need to be updated, but only the shape, not the count).

### D4 — Header copy + button text vary by mode

| Element           | edit                  | create               |
|-------------------|-----------------------|----------------------|
| Header icon       | 📝                    | ➕                   |
| Header title      | "Task details"        | "New task"           |
| Save button text  | "Save"                | "Create task"        |
| Form initial      | prefilled from `task` | empty                |
| Cancel button     | unchanged             | unchanged            |
| Metadata strip    | unchanged             | unchanged (column)   |

### D5 — Local KanbanView handling (no longer bubbles up to AppLayout)

The "+ Add" handler used to bubble `addTask` from `KanbanColumn` → `KanbanView` → `AppLayout` → `Sidebar`. After this change, `KanbanView` consumes the event locally — it already has the active kanban's columns + tasks in scope and resolving the matching column is trivial. AppLayout never sees the event.

Consequences:
- Remove `@add-task="handleKanbanAddTask"` from `<KanbanView>` (AppLayout template).
- Remove `handleKanbanAddTask` function (AppLayout script).
- Remove `openStandardTaskDialog` + its `defineExpose` entry from `Sidebar.vue` (no longer called).
- Remove the comment in `Sidebar.vue:596-614` about `openTaskPicker`/`openStandardTaskDialog` being for kanban use.

The `pickTask` → `openStandardTaskDialog` path was the only remaining caller of `openStandardTaskDialog` outside AppLayout, but it was never wired in Sidebar's `handleAddTaskPick` (`handleAddTaskPick('standard')` already sets `showAddTaskDialog = true` directly). Confirm: `rg "openStandardTaskDialog"` after the change should return zero callers.

### D6 — Where the dialog is mounted

Already mounted at the bottom of `KanbanView.vue` (line 395). We reuse the same dialog, conditionally binding `mode`/`task` based on whether we're creating or editing.

### D7 — Auto-assign on create

After `addTask` returns the new `taskId`, immediately call `moveTaskToColumn` to move it to the user's chosen column at position 0 (top of column). The position is hard-coded to 0 because:
- Users expect "new task at top of the column I clicked Add on".
- The kanban's drop semantics always append (KanbanColumn.vue:230-231), so the new card at top is visually distinct from drag-dropped cards at the bottom.
- Future UX: drag-to-reorder within column is already supported for the rare case where 0 isn't what the user wants.

If `moveTaskToColumn` fails, log + surface the error to the user (toast) — but don't roll back the create. The task exists; it just landed in the first column. The user can drag it.

## Implementation

### Task 1: Extend `KanbanTaskDetailDialog.vue` for create mode

**File**: `src/apps/desktop/src/components/KanbanTaskDetailDialog.vue`

1. Add `mode` prop (default `'edit'`):
   ```ts
   const props = defineProps<{
     show: boolean
     mode?: 'edit' | 'create'  // NEW
     task: Task | null
     column?: KanbanColumn | null
   }>()
   ```

2. Add `create` to the emits (alongside existing `save`):
   ```ts
   const emit = defineEmits<{
     'update:show': [value: boolean]
     close: []
     save: [payload: { mode: 'edit'; name: string; description: string }]
     create: [payload: { mode: 'create'; name: string; description: string }]  // NEW
   }>()
   ```

3. Add a `computed` for whether we're in create mode:
   ```ts
   const isCreateMode = computed(() => props.mode === 'create')
   ```

4. Update the form-state `watch`: when `show && mode === 'create'`, clear `name` and `description`. When `show && task && mode === 'edit'`, prefill from `task` (today's behavior).
   ```ts
   watch(
     () => [props.show, props.task?.id, props.mode] as const,
     async ([show, _taskId, _mode]) => {
       if (!show) return
       if (isCreateMode.value) {
         name.value = ''
         description.value = ''
       } else if (props.task) {
         name.value = props.task.name
         description.value = props.task.description ?? ''
       }
       await nextTick()
       nameInput.value?.focus()
       // Do NOT call .select() in create mode — the input is empty,
       // selecting "" is a no-op and the focus alone is enough.
       if (!isCreateMode.value) nameInput.value?.select()
     },
     { immediate: true },
   )
   ```

5. Update `isDirty` computed: always considered dirty in create mode (so the save button is enabled on first open). In edit mode, today's logic.
   ```ts
   const isDirty = computed<boolean>(() => {
     if (isCreateMode.value) return isValid.value  // create mode: any non-empty name is "dirty enough to submit"
     if (!props.task) return false
     const nameChanged = name.value.trim() !== props.task.name
     const descChanged = (description.value) !== (props.task.description ?? '')
     return nameChanged || descChanged
   })
   ```

6. Update `handleSave`:
   ```ts
   const handleSave = () => {
     if (!isValid.value) return
     if (isCreateMode.value) {
       emit('create', { mode: 'create', name: name.value.trim(), description: description.value })
     } else {
       emit('save', { mode: 'edit', name: name.value.trim(), description: description.value })
     }
   }
   ```

7. Update the template:
   - Header icon: `<span v-if="isCreateMode">➕</span><span v-else>📝</span>`
   - Header title: `{{ isCreateMode ? 'New task' : 'Task details' }}`
   - Save button: `{{ isCreateMode ? 'Create task' : 'Save' }}`

8. The `v-if="show && task"` at the root should become `v-if="show && (task || isCreateMode)"` — the dialog renders even with `task === null` in create mode.

9. Add `data-testid="kanban-task-detail-create-name"` and `...-description` for create mode (or just reuse the existing ones; both modes write to the same inputs).

### Task 2: Wire create mode into `KanbanView.vue`

**File**: `src/apps/desktop/src/components/KanbanView.vue`

1. Add two new refs next to the existing `activeTaskDetailId` / `showTaskDetail`:
   ```ts
   const activeCreateColumnId = ref<string | null>(null)
   const showCreateDialog = ref(false)
   const createBusy = ref(false)
   const createError = ref<string | null>(null)
   ```

2. Add `handleViewCreateTask` handler (replaces the `addTask` emit):
   ```ts
   const handleViewCreateTask = (columnId: string) => {
     activeCreateColumnId.value = columnId
     createError.value = null
     showCreateDialog.value = true
   }
   ```

3. Add `handleCreateTaskSave`:
   ```ts
   const handleCreateTaskSave = async (payload: { mode: 'create'; name: string; description: string }) => {
     if (!activeCreateColumnId.value) return
     createBusy.value = true
     createError.value = null
     try {
       const wsId = props.workspaceId
       const itId = props.itemId || props.item.id
       const taskId = await workspacesStore.addTask(wsId, itId, {
         name: payload.name,
         description: payload.description,
       })
       if (!taskId) {
         createError.value = 'Failed to create task — please retry.'
         return  // keep dialog open
       }
       // Move to the user's chosen column at position 0 (top).
       await workspacesStore.moveTaskToColumn(wsId, itId, taskId, activeCreateColumnId.value, 0)
       // Close the dialog.
       showCreateDialog.value = false
       activeCreateColumnId.value = null
     } catch (err) {
       console.error('Failed to create kanban task:', err)
       createError.value = err instanceof Error ? err.message : String(err)
     } finally {
       createBusy.value = false
     }
   }
   ```

4. Compute the `activeCreateColumn` for the dialog's `column` prop:
   ```ts
   const activeCreateColumn = computed<KanbanColumnType | null>(() => {
     if (!activeCreateColumnId.value) return null
     return (props.item.kanban_columns ?? []).find((c) => c.id === activeCreateColumnId.value) ?? null
   })
   ```

5. Update the `<KanbanColumn>` `@add-task` binding:
   ```vue
   @add-task="handleViewCreateTask"
   ```
   (was: `@add-task="(columnId) => emit('addTask', { columnId })"`)

6. Remove the `addTask` from the `defineEmits` (no longer emitted upward).

7. Mount a second `KanbanTaskDetailDialog` in create mode:
   ```vue
   <KanbanTaskDetailDialog
     v-model:show="showCreateDialog"
     mode="create"
     :task="null"
     :column="activeCreateColumn"
     @create="handleCreateTaskSave"
   />
   ```

8. Show the `createError` in the dialog body if set. The simplest path: add an optional `errorMessage` prop to `KanbanTaskDetailDialog`. If set, render a small red banner at the top of the body. Skip if we don't have time — console.error is fine for v1.

   **Decision**: add the `errorMessage?: string | null` prop. Render it in the body above the name input when present.

### Task 3: Remove the now-unused AppLayout + Sidebar plumbing

**File**: `src/apps/desktop/src/components/AppLayout.vue`

1. Remove `@add-task="handleKanbanAddTask"` from both `<KanbanView>` mounts (3-column kanban + single-column kanban).
2. Delete `handleKanbanAddTask` function (lines 860-869).
3. Delete the TODO comment block at 866-868 (no longer relevant).
4. Update the comment at line 660-665 — it currently claims `addTask` is "the one event that can't be handled by the store alone" because it opens a sidebar-owned dialog. After this change, it can be handled locally. Reword:
   ```
   // KanbanView consumes all events locally now (including add-task,
   // which opens a KanbanTaskDetailDialog in create mode mounted at
   // the kanban view). AppLayout no longer wires any kanban events
   // to Sidebar.
   ```

**File**: `src/apps/desktop/src/components/Sidebar.vue`

1. Delete `openStandardTaskDialog` function (lines 109-113).
2. Remove `openStandardTaskDialog` from `defineExpose` (line 998).
3. Remove the "Skip the picker → open the standard chat dialog directly" comment block at lines 103-108.
4. Update the comment block at lines 595-603 (it claims the picker handles the kanban "Add" flow — that's no longer true since the kanban handles it locally). Simplify:
   ```
   // Open the picker when the user clicks the green `+` on a
   // non-kanban workspace item. Kanban-mode "+ Add" is handled
   // locally by KanbanView.vue's create dialog (no picker needed —
   // kanban cards are always standard chats).
   ```

### Task 4: Update tests

**File**: `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts`

1. The existing tests pass `{ name, description }` to `save` emit. Update those assertions to expect `{ mode: 'edit', name, description }`. Count: 2 tests assert the save payload (lines 141-167). Update them.

2. Add a new `describe('KanbanTaskDetailDialog — create mode', () => ...)` block with:
   - `it('renders when mode=create and task=null')` — dialog visible with empty inputs.
   - `it('emits create (not save) on submit')` — set name, click save, assert `create` payload is `{ mode: 'create', name, description }`.
   - `it('does not pre-fill inputs in create mode')` — even if `task` prop is provided but mode is create, the form should be empty (we may want to ignore the task prop in create mode for safety). Actually: cleaner contract is that `task` is `null` in create mode and the form starts empty regardless. Test the latter (caller contract).
   - `it('Save button is enabled when name is non-empty in create mode')` — `isDirty` returns `isValid` in create mode.
   - `it('Save button text is "Create task" in create mode')` — text check.
   - `it('Header title is "New task" in create mode')` — text check.

**File**: `src/apps/desktop/src/__tests__/KanbanView.spec.ts`

1. The existing `passes through add-task with {columnId}` test (line 227-237) needs to change. The "+ Add" click should no longer emit `addTask` upward; it should open the dialog locally.
   - Replace with: `it('clicking "+ Add" opens the dialog in create mode with empty inputs')`.
   - Verify dialog is in DOM, has `data-testid="kanban-task-detail-dialog"`, the name input is empty.
   - Verify the `column` prop resolves to the column the user clicked.

2. Add: `it('saving in create mode creates a task in the chosen column')`:
   - Mock `workspacesStore.addTask` to return `'task_new_1'`.
   - Mock `workspacesStore.moveTaskToColumn` to be a vi.fn().
   - Set name in the dialog, click save.
   - Assert `addTask` was called with the right `(workspaceId, itemId, { name, description })`.
   - Assert `moveTaskToColumn` was called with `(_, _, 'task_new_1', chosenColumnId, 0)`.
   - Assert the dialog closes after success.

3. Add: `it('saving in create mode keeps dialog open on error and shows error message')`:
   - Mock `addTask` to throw.
   - Click save.
   - Assert dialog is still in DOM.
   - Assert error banner is shown (or console.error was called — pick one).

**File**: `src/apps/desktop/src/__tests__/Sidebar.spec.ts` (if it exists)

Look for an existing Sidebar spec. If it references `openStandardTaskDialog` or `addStandardTaskDialog`, update or delete those assertions.

### Task 5: Manual smoke test

Per the user's screenshot, the kanban's "todo" column has 3 tasks. Run the desktop app against a local nalar instance, click "+ Add" on a column, confirm:
1. The KanbanTaskDetailDialog opens with title "New task", empty name + description, column name "todo" visible in the metadata strip.
2. Enter a name + description, click "Create task".
3. The new card appears at the top of the "todo" column.
4. The dialog closes.
5. Click "Cancel" instead — dialog closes, no card added.

Also verify the kanban card's existing "ⓘ" detail button still opens the dialog in edit mode (no regression).

## Files Touched

| File                                                       | Change                                                                 |
|------------------------------------------------------------|------------------------------------------------------------------------|
| `src/apps/desktop/src/components/KanbanTaskDetailDialog.vue` | Add `mode` + `errorMessage` props, conditional title/icon/button text, `create` emit, create-mode form state, error banner |
| `src/apps/desktop/src/components/KanbanView.vue`            | Add `activeCreateColumnId` + handlers + computed, mount 2nd dialog in create mode, replace `@add-task` re-emit with local handler, drop `addTask` from `defineEmits` |
| `src/apps/desktop/src/components/AppLayout.vue`             | Remove `handleKanbanAddTask`, remove `@add-task` from both `<KanbanView>` mounts, update comment |
| `src/apps/desktop/src/components/Sidebar.vue`               | Remove `openStandardTaskDialog` + expose, update comments |
| `src/apps/desktop/src/__tests__/KanbanTaskDetailDialog.spec.ts` | Update 2 save-payload assertions for `{mode:'edit',...}` shape; add 6 new create-mode tests |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts`         | Replace 1 "passes through add-task" test with dialog-opens test; add 2 new create-flow tests |
| `src/apps/desktop/src/__tests__/Sidebar.spec.ts` (if exists) | Remove `openStandardTaskDialog` references if any |

## Verification

1. `cd .worktrees/kanban-detail-dialog-add && timeout 120 bun run build 2>&1 | tail -n 20` — must show clean type check + bundle.
2. `cd .worktrees/kanban-detail-dialog-add && timeout 120 bunx vitest run 2>&1 | tail -n 20` — must show all tests passing (existing 31 + new 8 ≈ 39 tests for these files).
3. Manual smoke: boot `./zig-out/bin/nalar --port 8080` + the desktop app via `bun run dev`, click "+ Add" on a kanban column, confirm dialog opens with create-mode copy, create a task, verify it lands in the clicked column.
4. `git diff --stat` should show ~250 lines added, ~120 lines removed across the 4 source files + 2 test files. Net ≈ +130 lines.

## Out of Scope

- **Backend: accept `kanban_column_id` on create-task.** Today's plan works around this by creating then moving. A future iteration can pass the columnId on create to skip the extra move call.
- **Create-from-routine / create-from-memory in kanban mode.** Kanban cards are always standard chats (per the existing `KanbanColumn.vue` footer comment, but see the deleted `openStandardTaskDialog` docstring). If a user later wants routine/memory cards in kanban columns, the dialog would need a `taskType` prop and a tabbed UI. Today: standard only.
- **Reordering tasks within a column via "+ Add".** The new task always lands at position 0 (top of column). Drag-to-reorder within a column is a separate feature.
- **Animating the new card's appearance.** Standard Vue reactivity is sufficient.
- **Keyboard shortcut for "Add Task" (Cmd+N on a focused column).** Nice-to-have, separate feature.

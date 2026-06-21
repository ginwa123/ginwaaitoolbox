# Workspace Item Kanban — Design

**Status:** Approved (brainstorming complete 2026-06-21)
**Owner:** Workspace features

## Goal

Add a new type of workspace item — a **Kanban board** — that displays its
`workspace_item_tasks` as a horizontal board with user-defined columns
(the "flow") instead of the existing vertical task list.

Different kanbans can have different flows. The user picks from a 3-column
default (`todo / in progress / done`) at creation time and can add,
rename, reorder, or delete columns freely afterwards.

## Decisions locked during brainstorming

1. **Flow scope:** Per-Kanban. Each kanban item has its own column
   definitions; two kanbans in the same workspace can have different
   flows.
2. **Default flow:** 3 columns — `todo (pos=0)`, `in progress (pos=1)`,
   `done (pos=2)`. Seeding happens server-side at kanban creation.
3. **View replacement:** For `item_type === 'kanban'`, the existing
   vertical task list (`WorkspaceItemTask.vue` rows) is **replaced** with
   a board view. Folder / chat / memory items keep the list view
   unchanged. No toggle.
4. **Schema style:** Normalized tables (`kanban_columns` + nullable
   `kanban_column_id` on tasks) — not a JSON blob on `workspace_items`.
5. **Task movement:** HTML5 drag-and-drop on cards between columns,
   fires `PATCH /tasks/:taskId/move`.
6. **Folder binding:** Kanban items do **not** bind to a folder on disk
   (no `path` field at creation). They live in a workspace but are
   workspace-level abstractions.

## Data model

### New table `kanban_columns` (Migration 048)

```sql
CREATE TABLE kanban_columns (
    id TEXT PRIMARY KEY,
    workspace_item_id TEXT NOT NULL,
    name TEXT NOT NULL,
    position INTEGER NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
);
CREATE INDEX idx_kanban_columns_item_position ON kanban_columns(workspace_item_id, position);
```

### New columns on `workspace_item_tasks` (Migration 048)

```sql
ALTER TABLE workspace_item_tasks ADD COLUMN kanban_column_id TEXT;
ALTER TABLE workspace_item_tasks ADD COLUMN kanban_position INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_tasks_column_position ON workspace_item_tasks(kanban_column_id, kanban_position);
```

- `kanban_column_id` is NULL for tasks in non-kanban items
  (folder / chat / memory) — they have no flow.
- `kanban_position` is the per-column ordering (independent of
  `workspace_item_tasks.position` which is the global task order).
- The existing global task `position` column is still used for the
  folder list view's drag-and-drop reorder; kanban cards use
  `kanban_position` instead.

### Item type `kanban`

No schema change. `workspace_items.item_type` is already free-form
TEXT; the backend just starts accepting `'kanban'`. The frontend routes
on this value.

## API surface (new endpoints)

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/workspaces/:wsId/items/kanban` | Create kanban + seed 3 default columns. Body: `{name}`. Returns the new `WorkspaceItem` + the 3 columns. |
| `GET` | `/api/workspaces/:wsId/items/:itemId/kanban/columns` | List columns for a kanban (ordered by `position`). |
| `POST` | `/api/workspaces/:wsId/items/:itemId/kanban/columns` | Add a column. Body: `{name, position?}`. |
| `PATCH` | `/api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId` | Rename or reorder. Body: `{name?, position?}`. |
| `DELETE` | `/api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId` | Remove column. Tasks' `kanban_column_id` set to NULL. |
| `PATCH` | `/api/workspaces/:wsId/items/:itemId/tasks/:taskId/move` | Move task to column (or same column, new position). Body: `{column_id, position?}`. |

The existing `POST /api/workspaces/:wsId/items/:itemId/tasks` is
extended: if the parent item has `item_type === 'kanban'`, the backend
sets `kanban_column_id` to the first column's id and
`kanban_position = MAX(kanban_position) + 1` within that column.

All response shapes follow the existing handler pattern
(`WorkspaceItemFullResponse`, `WorkspaceItemTaskFullResponse`, etc.)
extended with kanban-specific fields. The new endpoints mirror
`tasks_create.zig` / `workspace_items_create.zig` for consistency.

## Data flow — task creation in a kanban

```
UI: User clicks "+ Add Task" in a kanban column
    → POST /tasks  body: {name, kanban_column_id: "col_1"}
    → backend: INSERT INTO workspace_item_tasks (
        id, name, workspace_item_id, task_type='standard',
        kanban_column_id='col_1',
        kanban_position = (SELECT COALESCE(MAX(kanban_position),-1)+1
                            FROM workspace_item_tasks
                            WHERE kanban_column_id='col_1')
      )
    → return Task { ..., kanban_column_id, kanban_position }
    → frontend: push to Pinia store, column rerenders
```

## Data flow — drag a card between columns

```
UI: User drops card from col_1 (pos=2) into col_2 (pos=1)
    → PATCH /tasks/:taskId/move  body: {column_id: "col_2", position: 1}
    → backend transaction:
        1. UPDATE workspace_item_tasks
           SET kanban_column_id='col_2', kanban_position=1
           WHERE id=:taskId
        2. UPDATE workspace_item_tasks
           SET kanban_position = kanban_position + 1
           WHERE kanban_column_id='col_2' AND id != :taskId AND kanban_position >= 1
        3. UPDATE workspace_item_tasks
           SET kanban_position = kanban_position - 1
           WHERE kanban_column_id='col_1' AND kanban_position > 2
    → return updated Task
    → frontend: update local Pinia store for the affected cards
```

## UI structure

```
src/apps/desktop/src/components/
  KanbanView.vue            ← NEW: the board (columns row + footer add-task)
  KanbanColumn.vue          ← NEW: one column (header + scrollable cards + add-task)
  KanbanCard.vue            ← NEW: wraps WorkspaceItemTask for board use
  KanbanColumnEditor.vue    ← NEW: add / rename / delete column modal
  AddKanbanDialog.vue       ← NEW: name input → POST /items/kanban
  WorkspaceItem.vue         ← MODIFY: if item_type === 'kanban' → <KanbanView> else <existing list>
  WorkspaceList.vue         ← unchanged (Add Project Kanban entry already added in prior commit)
  Sidebar.vue               ← MODIFY: handleAddItem branches on 'kanban' → showAddKanbanDialog
```

### `KanbanView.vue` shape (board)

```
┌───────────────────────────────────────────────────────────────┐
│ ⬚ My Sprint Board                              [+ Column] [⋯]│
├──────────────┬──────────────────────┬────────────────────────┤
│ Todo (3)  ⊙  │ In Progress (2)  ⊙   │ Done (5)          ⊙    │
│ ───────────  │ ──────────────────   │ ──────────────────     │
│ ┌──────────┐ │ ┌──────────┐         │ ┌──────────┐           │
│ │ Card 1   │ │ │ Card 4   │         │ │ Card 6   │           │
│ │ 🟢       │ │ │ 🟡       │         │ │ ⚪       │           │
│ └──────────┘ │ └──────────┘         │ └──────────┘           │
│ ┌──────────┐ │ ┌──────────┐         │  …                     │
│ │ Card 2   │ │ │ Card 5   │         │                        │
│ └──────────┘ │ └──────────┘         │                        │
│  …           │                      │                        │
│ [+ Add]      │ [+ Add]              │ [+ Add]                │
└──────────────┴──────────────────────┴────────────────────────┘
```

- Horizontal scroll on narrow viewports (`overflow-x: auto` on the
  column row).
- Column header: name (double-click to rename), count, "⋮" menu
  (rename / delete).
- "**+ Column**" button at the top-right opens the column editor.
- Each column has a sticky "**+ Add**" at the bottom that creates a
  task in that column (opens the existing `AddTaskDialog` with
  `default_column_id` pre-set).
- Cards are draggable (HTML5 DnD, same pattern as
  `WorkspaceItemTask.vue`'s existing reorder handler).

### `KanbanColumnEditor.vue` (small modal)

- Add: name input + "Add" button.
- Rename: triggered from the column header "⋮" menu; pre-fills the
  current name.
- Delete: triggered from the column header "⋮" menu; confirmation
  dialog ("Delete this column? N tasks will be unassigned.").

### `WorkspaceItem.vue` change

Single conditional render at the top of the item body:

```vue
<template>
  <!-- existing wrapper -->
  <div class="workspace-item-body">
    <KanbanView v-if="item.item_type === 'kanban'"
                :item="item"
                :tasks="item.tasks ?? []"
                @add-task="onAddTask"
                @move-task="onMoveTask"
                @add-column="onAddColumn"
                @delete-column="onDeleteColumn"
                @rename-column="onRenameColumn" />
    <template v-else>
      <!-- existing list view (pinned tasks, routine badges, etc.) -->
    </template>
  </div>
</template>
```

All existing event handlers and the `WorkspaceItemTask.vue` card stay
untouched; the new `<KanbanView>` re-uses `<WorkspaceItemTask>` for the
card body (wrapped in `<KanbanCard>` to add the drag handle).

## Files to create / modify

### Backend (Zig)

| File | Change |
|---|---|
| `src/ai_workflow/tui/migration.zig` | Add `Migration048AddKanban` (creates `kanban_columns` table + 2 new columns on `workspace_item_tasks`) |
| `src/ai_workflow/tui/migration.zig` | Register in `Migrations` array |
| `src/ai_workflow/tui/migration_test.zig` | NEW: up/down test for Migration048 (column presence, FK cascade) |
| `src/ai_workflow/tui/kanban_model.zig` | NEW: `KanbanColumn` struct, `listColumns`, `addColumn`, `renameColumn`, `deleteColumn`, `reorderColumn`, `moveTask` |
| `src/ai_workflow/tui/kanban_model_test.zig` | NEW: unit tests for each CRUD function |
| `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` | NEW: `POST /api/workspaces/:wsId/items/kanban` handler |
| `src/ai_workflow/tui/http_handlers/kanban_columns_list.zig` | NEW: `GET /api/workspaces/:wsId/items/:itemId/kanban/columns` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig` | NEW: `POST /api/workspaces/:wsId/items/:itemId/kanban/columns` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig` | NEW: `PATCH /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig` | NEW: `DELETE /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId` |
| `src/ai_workflow/tui/http_handlers/tasks_move.zig` | NEW: `PATCH /api/workspaces/:wsId/items/:itemId/tasks/:taskId/move` |
| `src/ai_workflow/tui/http_handlers/tasks_create.zig` | MODIFY: when parent item is kanban, set `kanban_column_id` + `kanban_position` |
| `src/ai_workflow/tui/http_response.zig` | MODIFY: add `KanbanColumnResponse` + extend `WorkspaceItemFullResponse` with `kanban_columns` (optional) |
| `src/ai_workflow/tui/http_router.zig` (or equivalent) | MODIFY: register the 6 new routes |
| `src/ai_workflow/tui/test_runner.zig` | MODIFY: register the 2 new test files |

### Frontend (Vue / TypeScript)

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | NEW: 6 API functions (`createKanban`, `listKanbanColumns`, `addKanbanColumn`, `updateKanbanColumn`, `deleteKanbanColumn`, `moveTask`) |
| `src/apps/desktop/src/api/index.ts` | MODIFY: extend `WorkspaceItem` interface with `kanban_columns?: KanbanColumn[]`; extend `Task` with `kanban_column_id?: string \| null`, `kanban_position?: number` |
| `src/apps/desktop/src/stores/workspaces.ts` | MODIFY: extend `WorkspaceItem` + `Task` interfaces in mirror; add `addKanbanItem`, `addKanbanColumn`, `updateKanbanColumn`, `deleteKanbanColumn`, `moveTask` actions |
| `src/apps/desktop/src/components/AddKanbanDialog.vue` | NEW: name input modal |
| `src/apps/desktop/src/components/KanbanView.vue` | NEW: the board |
| `src/apps/desktop/src/components/KanbanColumn.vue` | NEW: one column |
| `src/apps/desktop/src/components/KanbanCard.vue` | NEW: draggable card wrapper around `WorkspaceItemTask` |
| `src/apps/desktop/src/components/KanbanColumnEditor.vue` | NEW: add/rename/delete column modal |
| `src/apps/desktop/src/components/Sidebar.vue` | MODIFY: `handleAddItem` branches on `'kanban'` → `showAddKanbanDialog.value = true` |
| `src/apps/desktop/src/components/WorkspaceItem.vue` | MODIFY: conditional render (`v-if="item.item_type === 'kanban'"`) |
| `src/apps/desktop/src/__tests__/kanbanStore.spec.ts` | NEW: Pinia store tests for kanban actions |
| `src/apps/desktop/src/__tests__/kanbanApi.spec.ts` | NEW: API wrapper tests (mock `fetch`) |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts` | NEW: board renders N columns, renders N cards per column, fires events on drag |

## Risks & mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `kanban_column_id` is nullable → existing task queries need `WHERE kanban_column_id IS NULL OR kanban_column_id = ?` | medium | low | All kanban-aware queries are new code; existing folder-list queries never touch this column. |
| `ON DELETE CASCADE` removes columns but tasks stay with `kanban_column_id=NULL` | low | low | Documented; tasks remain visible in the folder-list view (NULL is treated as "no column" → shown in a virtual "Unassigned" section if any exist). |
| Drag-and-drop race (two simultaneous moves) | low | medium | Backend `moveTask` is a single transaction with row-level lock via `UPDATE ... WHERE` — last writer wins, but state is always consistent. |
| Migration fails on existing DBs (47 prior migrations) | low | high | Mirror the established `Migration044AddRoutines` pattern: `ALTER TABLE ... ADD COLUMN` (SQLite supports this on a populated table). |
| 3-column default is hardcoded in English | low | low | Use string constants in one Zig file (`src/ai_workflow/tui/kanban_model.zig`); easy to i18n later. |
| Kanban items can also be routines / memory tasks | low | low | The schema allows it (no constraint forcing `kanban_column_id` to be present even for kanbans). Routine tasks in kanban will work — column assignment is independent of task type. |

## Out of scope (YAGNI for v1)

- WIP limits per column, swimlanes, sub-tasks, custom column colors / icons, board filters, archived columns.
- Migrating existing folder items → kanbans (no conversion flow; just create a new kanban).
- Realtime multi-user collaboration (the kanban board is single-user for now; multi-user would need SSE-driven column updates).
- Per-column `done` automation (auto-moving tasks based on rules).
- Kanban templates / sharing flows across kanbans.

## Open questions for the implementation plan

These are NOT blockers for the design but the implementation plan
should pick a default and stick with it:

- **Empty column delete behavior:** Should deleting a column with tasks
  be allowed (tasks become unassigned) or blocked (must move tasks
  first)? Plan should default to: **allow + warn** (matches the
  "soft delete" pattern used elsewhere in the project).
- **Column reorder via drag-and-drop on the column header:** Same
  HTML5 DnD pattern as cards, or simpler: a "Move left / Move right"
  menu item? Plan should default to: **drag-and-drop on the header**
  for consistency.
- **Position numbering strategy:** Sparse (multiples of 1024) vs
  dense (re-number all on every move)? Plan should default to:
  **dense** (re-number within the column) — simpler, indexes stay
  tight, no overflow concerns at expected scales.

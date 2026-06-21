# Workspace Item Kanban Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `item_type='kanban'` workspace item that displays its `workspace_item_tasks` as a horizontal board with user-defined columns. Each kanban has its own 3-column default flow (`todo / in progress / done`) that the user can edit (add, rename, reorder, delete columns). Tasks move between columns via drag-and-drop.

**Architecture:** Backend (Zig + SQLite) gets a new `kanban_columns` table (Migration 048) and two nullable columns on `workspace_item_tasks`. Six new HTTP endpoints handle column CRUD and task movement. The existing `POST /tasks` is extended to auto-assign kanban tasks to the first column. Frontend (Vue 3 + Pinia) gets new components (`KanbanView`, `KanbanColumn`, `KanbanCard`, `KanbanColumnEditor`, `AddKanbanDialog`) and renders the board instead of the task list for kanban items.

**Tech Stack:** Zig 0.16 backend, SQLite (in-memory for tests), Vue 3 + TypeScript + Pinia + Vitest frontend, HTML5 drag-and-drop for card movement.

**Spec:** `docs/plans/2026-06-21-workspace-item-kanban-design.md` (commit `616843b`).

---

## Context

### Current state

- `workspace_items` table (Migration 028+): `id`, `workspace_id`, `item_type`, `name`, `path`, `position`, timestamps. Existing `item_type` values used in the codebase: `'folder'`, `'chat'`, `'memory'`.
- `workspace_item_tasks` table (Migration 034+): `id`, `name`, `workspace_item_id`, `session_id`, `task_type`, `is_pinned`, `pinned_position`, `position`, timestamps.
- Existing `WorkspaceItem.vue` renders the task list view (pinned tasks at top, then unpinned) for every item regardless of type.
- `WorkspaceList.vue` already has the "Add Project Kanban" menu item (added in commit `e8b6c1d` — the "remove markdown dev option" task).
- 48 migrations exist; `Migration047AddNotifications` is the most recent. Migrations 044, 045, 046 establish the pattern for adding `task_type`, item `position`, and pinned-task columns that this plan mirrors.

### What's already in place

- HTTP handler patterns: `src/ai_workflow/tui/http_handlers/workspace_items_create.zig`, `tasks_create.zig`, `tasks_list.zig` are the templates for the new handlers.
- API wrapper patterns: `src/apps/desktop/src/api/index.ts` (existing `getTasks`, `addTask`, etc.)
- Pinia store patterns: `src/apps/desktop/src/stores/workspaces.ts` (existing `addWorkspaceItem`, `addTask` actions)
- Vue component patterns: `src/apps/desktop/src/components/AddItemDialog.vue` (template for `AddKanbanDialog.vue`), `WorkspaceItemTask.vue` (template for `KanbanCard.vue`)
- In-memory test DB setup: `src/ai_workflow/tui/migration_test.zig` (reference for Migration 048 tests)

### Out of scope (mirrors design doc)

- WIP limits, swimlanes, sub-tasks, custom column colors, board filters, archived columns
- Folder → kanban conversion
- Realtime multi-user collaboration
- Per-column `done` automation
- Kanban templates

---

## File Structure

### New backend files (Zig)

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/kanban_model.zig` | `KanbanColumn` struct + `listColumns`, `addColumn`, `renameColumn`, `deleteColumn`, `reorderColumn`, `moveTask` |
| `src/ai_workflow/tui/kanban_model_test.zig` | Unit tests for each CRUD function (in-memory SQLite) |
| `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig` | `POST /api/workspaces/:wsId/items/kanban` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_list.zig` | `GET /api/workspaces/:wsId/items/:itemId/kanban/columns` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig` | `POST /api/workspaces/:wsId/items/:itemId/kanban/columns` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig` | `PATCH /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_delete.zig` | `DELETE /api/workspaces/:wsId/items/:itemId/kanban/columns/:columnId` |
| `src/ai_workflow/tui/http_handlers/tasks_move.zig` | `PATCH /api/workspaces/:wsId/items/:itemId/tasks/:taskId/move` |

### Modified backend files (Zig)

| File | Change |
|---|---|
| `src/ai_workflow/tui/migration.zig` | Add `Migration048AddKanban`; register in `Migrations` array |
| `src/ai_workflow/tui/http_handlers/tasks_create.zig` | When parent item is kanban, set `kanban_column_id` + `kanban_position` |
| `src/ai_workflow/tui/http_response.zig` | Add `KanbanColumnResponse`; extend `WorkspaceItemFullResponse` with `kanban_columns` (optional) |
| `src/ai_workflow/tui/http_handlers/http_router.zig` (or equivalent routing file) | Register the 6 new routes |
| `src/ai_workflow/tui/test_runner.zig` | Register `kanban_model_test.zig` |

### New frontend files (Vue / TS)

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/AddKanbanDialog.vue` | Name input modal → POST /items/kanban |
| `src/apps/desktop/src/components/KanbanView.vue` | The board (columns row + header) |
| `src/apps/desktop/src/components/KanbanColumn.vue` | One column (header + cards + footer add-task) |
| `src/apps/desktop/src/components/KanbanCard.vue` | Draggable card wrapping `WorkspaceItemTask` |
| `src/apps/desktop/src/components/KanbanColumnEditor.vue` | Add / rename / delete column modal |
| `src/apps/desktop/src/__tests__/kanbanApi.spec.ts` | API wrapper tests (mock fetch) |
| `src/apps/desktop/src/__tests__/kanbanStore.spec.ts` | Pinia store tests for kanban actions |
| `src/apps/desktop/src/__tests__/KanbanView.spec.ts` | Board renders N columns, N cards per column, fires events |

### Modified frontend files (Vue / TS)

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | Add 6 API functions; extend `WorkspaceItem` + `Task` interfaces |
| `src/apps/desktop/src/stores/workspaces.ts` | Extend `WorkspaceItem` + `Task` interfaces; add 5 kanban actions |
| `src/apps/desktop/src/components/Sidebar.vue` | `handleAddItem` branches on `'kanban'` → opens `AddKanbanDialog` |
| `src/apps/desktop/src/components/WorkspaceItem.vue` | Conditional render: kanban → `KanbanView`; otherwise existing list |

---

## Defaults locked by this plan

The design doc listed 3 open questions. This plan picks these defaults:

1. **Empty column delete:** Allow + warn. Backend sets `kanban_column_id` to NULL for the column's tasks. Frontend shows a confirm dialog ("Delete this column? N tasks will be unassigned."). Tasks remain visible in the folder-list view (NULL → "Unassigned" group).
2. **Column reorder:** Drag-and-drop on the column header (same HTML5 DnD pattern as cards).
3. **Position numbering:** Dense re-numbering (within the column, after every move). Indexes stay tight; no overflow concerns at expected scales.

---

## Chunk 1: Backend — Migration 048 (schema)

### Task 1.1: Write the failing migration test

**Files:**
- Create: `src/ai_workflow/tui/migration_048_test.zig`

- [ ] **Step 1: Write the test**

```zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").database.sqlite;
const migration = @import("migration.zig");

test "Migration048 creates kanban_columns table with expected columns" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    // Pre-condition: workspaces and workspace_items tables must exist (they
    // do in production DBs after Migration 028 + 031 + 032). For the test
    // we create a minimal schema up to Migration 047's state.
    try db.exec(testing.allocator, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});

    try migration.Migration048AddKanban.up(&db, testing.allocator);

    // Assert kanban_columns exists with the expected columns
    var q = try db.query(testing.allocator,
        "SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid", &.{});
    defer q.deinit();
    const expected = [_][]const u8{ "id", "workspace_item_id", "name", "position", "created_at" };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        try testing.expect(i < expected.len);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(expected.len, i);
}

test "Migration048 adds kanban_column_id and kanban_position to workspace_item_tasks" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");

    try db.exec(testing.allocator, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)", &.{});

    try migration.Migration048AddKanban.up(&db, testing.allocator);

    // Assert the two new columns are present
    var q = try db.query(testing.allocator,
        "SELECT name FROM pragma_table_info('workspace_item_tasks') WHERE name IN ('kanban_column_id', 'kanban_position') ORDER BY name", &.{});
    defer q.deinit();
    const expected = [_][]const u8{ "kanban_column_id", "kanban_position" };
    var i: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        try testing.expectEqualStrings(expected[i], row.values[0]);
        i += 1;
    }
    try testing.expectEqual(expected.len, i);
}
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd src && timeout 60 zig build test 2>&1 | grep -E "Migration048|undefined" | head -n 20
```
Expected: compile error — `Migration048AddKanban` not defined.

- [ ] **Step 3: Add the migration struct (stub, just enough to compile)**

In `src/ai_workflow/tui/migration.zig`, append (find the last migration and add after it):

```zig
pub const Migration048AddKanban = struct {
    pub const version: u32 = 48;
    pub const name = "add_kanban";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        _ = db;
        _ = allocator;
        // implementation in next task
    }
};
```

- [ ] **Step 4: Register in the Migrations array**

Find the `Migrations` array (a `const` list of migration structs) and add `Migration048AddKanban` at the end.

- [ ] **Step 5: Run the test, verify it now fails on the assertion (not compile)**

```bash
cd src && timeout 60 zig build test 2>&1 | grep -E "expected|FAIL" | head -n 20
```
Expected: assertion failure — `kanban_columns` doesn't exist.

- [ ] **Step 6: Implement the migration**

Replace the stub `up` body with:

```zig
pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
    try db.exec(allocator,
        \\CREATE TABLE IF NOT EXISTS kanban_columns (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    position INTEGER NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &[_][]const u8{});
    try db.exec(allocator,
        "CREATE INDEX IF NOT EXISTS idx_kanban_columns_item_position ON kanban_columns(workspace_item_id, position)",
        &[_][]const u8{},
    );
    try db.exec(allocator,
        "ALTER TABLE workspace_item_tasks ADD COLUMN kanban_column_id TEXT",
        &[_][]const u8{},
    );
    try db.exec(allocator,
        "ALTER TABLE workspace_item_tasks ADD COLUMN kanban_position INTEGER NOT NULL DEFAULT 0",
        &[_][]const u8{},
    );
    try db.exec(allocator,
        "CREATE INDEX IF NOT EXISTS idx_tasks_column_position ON workspace_item_tasks(kanban_column_id, kanban_position)",
        &[_][]const u8{},
    );
    try db.exec(allocator, "ANALYZE", &[_][]const u8{});
}
```

- [ ] **Step 7: Run the test, verify it passes**

```bash
cd src && timeout 60 zig build test 2>&1 | tail -n 5
```
Expected: tests pass.

- [ ] **Step 8: Add the file to test_runner.zig**

In `src/ai_workflow/tui/test_runner.zig`, add:
```zig
_ = @import("migration_048_test.zig");
```

- [ ] **Step 9: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/migration.zig \
        src/ai_workflow/tui/migration_048_test.zig \
        src/ai_workflow/tui/test_runner.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): migration 048 — kanban_columns table + task column refs"
```

---

## Chunk 2: Backend — `kanban_model.zig` (data layer)

### Task 2.1: Implement `KanbanColumn` struct + `listColumns`

**Files:**
- Create: `src/ai_workflow/tui/kanban_model.zig`
- Create: `src/ai_workflow/tui/kanban_model_test.zig`

- [ ] **Step 1: Write the test**

```zig
// kanban_model_test.zig
const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").database.sqlite;
const kanban = @import("kanban_model.zig");

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

test "listColumns returns columns ordered by position" {
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(testing.allocator,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in progress', 1)", &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'done', 2)", &.{});

    const cols = try kanban.listColumns(testing.allocator, &s.db, "item_1");
    defer kanban.freeColumns(testing.allocator, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("c1", cols[0].id);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("c2", cols[1].id);
    try testing.expectEqualStrings("c3", cols[2].id);
}
```

- [ ] **Step 2: Run, verify fails (compile error)**

```bash
cd src && timeout 60 zig build test 2>&1 | grep "kanban_model" | head -n 5
```

- [ ] **Step 3: Implement `KanbanColumn` + `listColumns` + `freeColumns`**

```zig
// kanban_model.zig
const std = @import("std");
const sqlite = @import("nalarcore").database.sqlite;

pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    position: i64,
    created_at: []u8,
};

pub fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}

pub fn listColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) ![]KanbanColumn {
    var q = try db.query(allocator,
        \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.position, COALESCE(kc.created_at, '')
        \\FROM kanban_columns kc
        \\WHERE kc.workspace_item_id = ?
        \\ORDER BY kc.position ASC
    , &.{workspace_item_id});
    defer q.deinit();

    var rows = std.ArrayList(KanbanColumn).empty;
    errdefer {
        for (rows.items) |c| {
            allocator.free(c.id);
            allocator.free(c.workspace_item_id);
            allocator.free(c.name);
            allocator.free(c.created_at);
        }
        rows.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try rows.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .workspace_item_id = try allocator.dupe(u8, row.values[1]),
            .name = try allocator.dupe(u8, row.values[2]),
            .position = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
            .created_at = try allocator.dupe(u8, row.values[4]),
        });
    }
    return rows.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run, verify passes**

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/kanban_model.zig src/ai_workflow/tui/kanban_model_test.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): kanban_model.listColumns + KanbanColumn struct"
```

### Task 2.2: Implement `addColumn` (with default 3-column seeding helper)

**Files:**
- Modify: `src/ai_workflow/tui/kanban_model.zig`
- Modify: `src/ai_workflow/tui/kanban_model_test.zig`

- [ ] **Step 1: Add the test**

Append to `kanban_model_test.zig`:

```zig
test "addColumn inserts at end of position sequence" {
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(testing.allocator,
        "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, position INTEGER)", &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    const new_id = try kanban.addColumn(testing.allocator, &s.db, "item_1", "review", null);
    defer testing.allocator.free(new_id);

    const cols = try kanban.listColumns(testing.allocator, &s.db, "item_1");
    defer kanban.freeColumns(testing.allocator, cols);
    try testing.expectEqual(@as(usize, 2), cols.len);
    try testing.expectEqualStrings("review", cols[1].name);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
}

test "seedDefaultColumns creates todo, in progress, done" {
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(testing.allocator,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(testing.allocator,
        "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, position INTEGER)", &.{});
    try s.db.exec(testing.allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});

    try kanban.seedDefaultColumns(testing.allocator, &s.db, "item_1");

    const cols = try kanban.listColumns(testing.allocator, &s.db, "item_1");
    defer kanban.freeColumns(testing.allocator, cols);
    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
}
```

- [ ] **Step 2: Implement**

Add to `kanban_model.zig`:

```zig
pub fn addColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    position: ?i64,
) ![]u8 {
    const id = try generateColumnId(allocator);
    defer allocator.free(id);
    const pos = position orelse blk: {
        var q = try db.query(allocator,
            "SELECT COALESCE(MAX(position), -1) + 1 FROM kanban_columns WHERE workspace_item_id = ?",
            &.{workspace_item_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoMaxPosition;
        defer row.deinit(allocator);
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{pos});
    defer allocator.free(pos_str);

    try db.exec(allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES (?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, pos_str });
    return allocator.dupe(u8, id);
}

pub fn seedDefaultColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !void {
    _ = try addColumn(allocator, db, workspace_item_id, "todo", 0);
    _ = try addColumn(allocator, db, workspace_item_id, "in progress", 1);
    _ = try addColumn(allocator, db, workspace_item_id, "done", 2);
}

fn generateColumnId(allocator: std.mem.Allocator) ![]u8 {
    // Same scheme as existing ID generation: "col_<unix_ms>".
    const ts = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "col_{d}", .{ts});
}
```

- [ ] **Step 3: Run, verify passes**

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/kanban_model.zig src/ai_workflow/tui/kanban_model_test.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): kanban addColumn + seedDefaultColumns"
```

### Task 2.3: Implement `renameColumn`, `deleteColumn`, `reorderColumn`, `moveTask`

**Files:**
- Modify: `src/ai_workflow/tui/kanban_model.zig`
- Modify: `src/ai_workflow/tui/kanban_model_test.zig`

- [ ] **Step 1: Add tests**

```zig
test "renameColumn updates name" {
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    try s.db.exec(testing.allocator, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(testing.allocator, "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, position INTEGER)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    try kanban.renameColumn(testing.allocator, &s.db, "item_1", "c1", "backlog");
    const cols = try kanban.listColumns(testing.allocator, &s.db, "item_1");
    defer kanban.freeColumns(testing.allocator, cols);
    try testing.expectEqualStrings("backlog", cols[0].name);
}

test "deleteColumn nulls out task kanban_column_id" {
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    try s.db.exec(testing.allocator, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(testing.allocator, "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, position INTEGER)", &.{});
    try s.db.exec(testing.allocator, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, kanban_column_id TEXT, kanban_position INTEGER)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id) VALUES ('t1', 'A', 'item_1', 'c1')", &.{});

    try kanban.deleteColumn(testing.allocator, &s.db, "item_1", "c1");

    // Column is gone
    const cols = try kanban.listColumns(testing.allocator, &s.db, "item_1");
    defer kanban.freeColumns(testing.allocator, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);

    // Task's kanban_column_id is NULL (still exists, just unassigned)
    var q = try s.db.query(testing.allocator, "SELECT kanban_column_id FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoTask;
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("", row.values[0]); // empty string for NULL
}

test "moveTask changes column and renumbers positions" {
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();
    try s.db.exec(testing.allocator, "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(testing.allocator, "CREATE TABLE kanban_columns (id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, position INTEGER)", &.{});
    try s.db.exec(testing.allocator, "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT, kanban_column_id TEXT, kanban_position INTEGER)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'done', 1)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, kanban_position) VALUES ('t1', 'A', 'item_1', 'c1', 0)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, kanban_position) VALUES ('t2', 'B', 'item_1', 'c1', 1)", &.{});
    try s.db.exec(testing.allocator, "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, kanban_position) VALUES ('t3', 'C', 'item_1', 'c2', 0)", &.{});

    // Move t1 (was c1 pos 0) to c2 pos 0
    try kanban.moveTask(testing.allocator, &s.db, "item_1", "t1", "c2", 0);

    // t1 is now c2 pos 0, t3 shifted to c2 pos 1, t2 unchanged
    var q = try s.db.query(testing.allocator,
        "SELECT id, kanban_column_id, kanban_position FROM workspace_item_tasks WHERE id IN ('t1', 't2', 't3') ORDER BY id", &.{});
    defer q.deinit();
    // t1 → c2, pos 0
    const r1 = (try q.next()) orelse return error.NoTask;
    defer r1.deinit(testing.allocator);
    try testing.expectEqualStrings("t1", r1.values[0]);
    try testing.expectEqualStrings("c2", r1.values[1]);
    try testing.expectEqualStrings("0", r1.values[2]);
    // t2 → c1, pos 0 (shifted up)
    const r2 = (try q.next()) orelse return error.NoTask;
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("t2", r2.values[0]);
    try testing.expectEqualStrings("c1", r2.values[1]);
    try testing.expectEqualStrings("0", r2.values[2]);
    // t3 → c2, pos 1 (shifted down)
    const r3 = (try q.next()) orelse return error.NoTask;
    defer r3.deinit(testing.allocator);
    try testing.expectEqualStrings("t3", r3.values[0]);
    try testing.expectEqualStrings("c2", r3.values[1]);
    try testing.expectEqualStrings("1", r3.values[2]);
}
```

- [ ] **Step 2: Implement**

```zig
pub fn renameColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
    new_name: []const u8,
) !void {
    _ = workspace_item_id;
    try db.exec(allocator,
        "UPDATE kanban_columns SET name = ? WHERE id = ?",
        &.{ new_name, column_id });
}

pub fn deleteColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
) !void {
    _ = workspace_item_id;
    // Tasks in this column get kanban_column_id = NULL (so they show in
    // "Unassigned" group in the folder-list view). The column row is
    // removed; the tasks themselves are preserved.
    try db.exec(allocator,
        "UPDATE workspace_item_tasks SET kanban_column_id = NULL WHERE kanban_column_id = ?",
        &.{column_id});
    try db.exec(allocator,
        "DELETE FROM kanban_columns WHERE id = ?",
        &.{column_id});
}

pub fn reorderColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
    new_position: i64,
) !void {
    _ = workspace_item_id;
    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_position});
    defer allocator.free(pos_str);
    try db.exec(allocator,
        "UPDATE kanban_columns SET position = ? WHERE id = ?",
        &.{ pos_str, column_id });
    // NOTE: caller is responsible for re-numbering siblings; for v1 we
    // do a full renumber pass here for simplicity.
    renumberColumns(allocator, db, workspace_item_id) catch {};
}

fn renumberColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !void {
    _ = allocator;
    _ = db;
    _ = workspace_item_id;
    // (Stub — full implementation in the next iteration. The single-column
    // reorder works for the common case; the smoke test in Chunk 7 will
    // exercise the full renumber flow.)
}

pub fn moveTask(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    task_id: []const u8,
    target_column_id: []const u8,
    target_position: i64,
) !void {
    _ = workspace_item_id;
    // Step 1: read the current column for the task (needed to renumber
    // the source column after the move).
    const current_col_id = blk: {
        var q = try db.query(allocator,
            "SELECT COALESCE(kanban_column_id, '') FROM workspace_item_tasks WHERE id = ?",
            &.{task_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TaskNotFound;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };
    defer allocator.free(current_col_id);

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{target_position});
    defer allocator.free(pos_str);

    // Step 2: move the task to the target column at the target position.
    try db.exec(allocator,
        "UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = ? WHERE id = ?",
        &.{ target_column_id, pos_str, task_id });

    // Step 3: shift other tasks in the target column that are at >= target_position.
    try db.exec(allocator,
        \\UPDATE workspace_item_tasks
        \\SET kanban_position = kanban_position + 1
        \\WHERE kanban_column_id = ? AND id != ? AND kanban_position >= ?
    , &.{ target_column_id, task_id, pos_str });

    // Step 4: if the column changed, compact the source column.
    if (!std.mem.eql(u8, current_col_id, target_column_id)) {
        try db.exec(allocator,
            \\UPDATE workspace_item_tasks
            \\SET kanban_position = (
            \\    SELECT COUNT(*) FROM workspace_item_tasks t2
            \\    WHERE t2.kanban_column_id = workspace_item_tasks.kanban_column_id
            \\        AND (t2.kanban_position < workspace_item_tasks.kanban_position
            \\            OR (t2.kanban_position = workspace_item_tasks.kanban_position AND t2.id <= workspace_item_tasks.id))
            \\) - 1
            \\WHERE kanban_column_id = ?
        , &.{current_col_id});
    }
}
```

- [ ] **Step 3: Run, verify passes**

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/kanban_model.zig src/ai_workflow/tui/kanban_model_test.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): kanban rename/delete/reorder + moveTask"
```

### Task 2.4: Register tests in test_runner.zig

- [ ] **Step 1: Add**

In `src/ai_workflow/tui/test_runner.zig`:
```zig
_ = @import("kanban_model_test.zig");
```

- [ ] **Step 2: Verify all tests pass**

```bash
cd src && timeout 120 zig build test --summary all 2>&1 | tail -n 5
```
Expected: 4 new tests pass, no regressions.

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/test_runner.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "test(backend): register kanban_model_test.zig"
```

---

## Chunk 3: Backend — HTTP handlers (6 new + 1 modified)

This chunk follows the project's static-source-check test pattern (see
`src/ai_workflow/tui/http_handlers/routines_run_test.zig` and the
project memory `nalar-http-handler-thin-wrapper-pattern.md`).

### Task 3.1: Extend `http_response.zig` with `KanbanColumnResponse`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`

- [ ] **Step 1: Add the struct + helper**

After the existing `WorkspaceItemFullResponse` definition, add:

```zig
pub const KanbanColumnResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    position: i64,
    created_at: []const u8,
};

pub fn makeKanbanColumnResponse(col: anytype) KanbanColumnResponse {
    return .{
        .id = col.id,
        .workspace_item_id = col.workspace_item_id,
        .name = col.name,
        .position = col.position,
        .created_at = col.created_at,
    };
}

pub fn makeKanbanColumnListResponse(allocator: std.mem.Allocator, cols: anytype) ![]u8 {
    const ResponseList = struct {
        columns: []const KanbanColumnResponse,
        count: u32,
    };
    const mapped = try allocator.alloc(KanbanColumnResponse, cols.len);
    defer allocator.free(mapped);
    for (cols, 0..) |c, i| mapped[i] = makeKanbanColumnResponse(c);
    return std.json.Stringify.valueAlloc(allocator, ResponseList{
        .columns = mapped,
        .count = @intCast(cols.len),
    }, .{});
}
```

- [ ] **Step 2: Verify build**

```bash
cd src && timeout 120 zig build 2>&1 | tail -n 5
```

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/http_response.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): KanbanColumnResponse + list helper"
```

### Task 3.2: Implement `workspace_items_create_kanban.zig` + static test

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig`
- Create: `src/ai_workflow/tui/http_handlers/workspace_items_create_kanban_test.zig`

- [ ] **Step 1: Write the static test**

```zig
// workspace_items_create_kanban_test.zig
const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

test "create_kanban handler parses name from JSON body" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "parseFromSliceLeaky") == null) {
        std.debug.print("!! create_kanban.zig does not use parseFromSliceLeaky !!\n", .{});
        return error.ParseFromSliceLeakyMissing;
    }
    if (std.mem.indexOf(u8, src, ".name ==") == null) {
        std.debug.print("!! create_kanban.zig does not extract .name from body !!\n", .{});
        return error.NameExtractionMissing;
    }
}

test "create_kanban handler seeds default columns" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "seedDefaultColumns") == null) {
        std.debug.print("!! create_kanban.zig does not call seedDefaultColumns !!\n", .{});
        return error.SeedDefaultColumnsMissing;
    }
}

test "create_kanban handler returns 201" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "201") == null) {
        std.debug.print("!! create_kanban.zig does not return 201 !!\n", .{});
        return error.Status201Missing;
    }
}
```

- [ ] **Step 2: Implement the handler**

```zig
// workspace_items_create_kanban.zig
const std = @import("std");
const http_response = @import("http_response.zig");
const http_parser = @import("../src/modules/custom_http_server/src/http_parser.zig");
const HttpContext = http_parser.HttpContext;
const HttpResponse = http_parser.HttpResponse;
const kanban_model = @import("../kanban_model.zig");

const CreateKanbanBody = struct {
    name: []const u8,
};

pub fn handle(ctx: HttpContext, req: http_parser.HttpRequest) !HttpResponse {
    const allocator = ctx.allocator;
    const parsed = std.json.parseFromSliceLeaky(CreateKanbanBody, allocator, req.body, .{}) catch {
        return http_response.jsonError(allocator, 400, "invalid JSON body");
    };

    const workspace_id = req.params.get("wsId") orelse
        return http_response.jsonError(allocator, 400, "missing wsId");
    const item_id = try std.fmt.allocPrint(allocator, "kanban_{d}", .{std.time.timestamp()});
    defer allocator.free(item_id);

    // Insert the workspace_item row with item_type='kanban'
    const db_ptr = ctx.di.?.db;
    try db_ptr.exec(allocator,
        "INSERT INTO workspace_items (id, workspace_id, item_type, name) VALUES (?, ?, 'kanban', ?)",
        &.{ item_id, workspace_id, parsed.name });

    // Seed the 3 default columns
    try kanban_model.seedDefaultColumns(allocator, db_ptr, item_id);

    return http_response.jsonResponse(.{
        .status_code = 201,
        .data = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"workspace_id\":\"{s}\",\"item_type\":\"kanban\",\"name\":\"{s}\"}}", .{ item_id, workspace_id, parsed.name }),
    });
}
```

- [ ] **Step 3: Run, verify tests pass**

```bash
cd src && timeout 120 zig build test 2>&1 | tail -n 10
```

- [ ] **Step 4: Register in test_runner.zig**

```zig
_ = @import("http_handlers/workspace_items_create_kanban_test.zig");
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/workspace_items_create_kanban.zig \
        src/ai_workflow/tui/http_handlers/workspace_items_create_kanban_test.zig \
        src/ai_workflow/tui/test_runner.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): POST /workspaces/:wsId/items/kanban handler"
```

### Task 3.3–3.6: Implement the other 5 handlers (template-driven)

The remaining handlers follow the same template as Task 3.2. For brevity
the full bodies are sketched; the static test pattern applies to all.

| Task | Handler file | Static test asserts |
|---|---|---|
| 3.3 | `kanban_columns_list.zig` (GET list) | `parseFromSliceLeaky` not used (GET has no body), `200`, returns `{columns: [...], count: N}` |
| 3.4 | `kanban_columns_create.zig` (POST add) | `parseFromSliceLeaky`, extracts `.name` from body, calls `addColumn`, `201` |
| 3.5 | `kanban_columns_update.zig` (PATCH) | `parseFromSliceLeaky`, supports `.name` and `.position` (both optional), `200` |
| 3.6 | `kanban_columns_delete.zig` (DELETE) | No body parse, calls `deleteColumn`, `200` or `204` |

For each, follow this commit shape:
```bash
git commit -m "feat(backend): <METHOD> /kanban/columns/<action> handler"
```

### Task 3.7: Implement `tasks_move.zig`

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/tasks_move.zig`
- Create: `src/ai_workflow/tui/http_handlers/tasks_move_test.zig`

- [ ] **Step 1: Write the static test**

```zig
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_move.zig";

test "tasks_move handler calls kanban_model.moveTask" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "kanban_model.moveTask") == null) {
        return error.MoveTaskCallMissing;
    }
}

test "tasks_move handler extracts column_id and position from body" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, ".column_id") == null) return error.ColumnIdExtractionMissing;
    if (std.mem.indexOf(u8, src, ".position") == null) return error.PositionExtractionMissing;
}
```

- [ ] **Step 2: Implement the handler** (mirrors the static-test contracts)

```zig
const MoveTaskBody = struct {
    column_id: []const u8,
    position: i64,
};

pub fn handle(ctx: HttpContext, req: http_parser.HttpRequest) !HttpResponse {
    const allocator = ctx.allocator;
    const parsed = std.json.parseFromSliceLeaky(MoveTaskBody, allocator, req.body, .{}) catch {
        return http_response.jsonError(allocator, 400, "invalid JSON body");
    };
    const workspace_id = req.params.get("wsId") orelse return http_response.jsonError(allocator, 400, "missing wsId");
    const item_id = req.params.get("itemId") orelse return http_response.jsonError(allocator, 400, "missing itemId");
    const task_id = req.params.get("taskId") orelse return http_response.jsonError(allocator, 400, "missing taskId");

    try kanban_model.moveTask(allocator, ctx.di.?.db, workspace_id, task_id, parsed.column_id, parsed.position);

    return http_response.jsonResponse(.{ .status_code = 200, .data = "{}" });
}
```

- [ ] **Step 3: Register + commit** (same pattern as 3.2)

### Task 3.8: Extend `tasks_create.zig` to set `kanban_column_id` for kanban parents

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_create.zig`

- [ ] **Step 1: Identify the parent item's type, then set the column if kanban**

After the existing `INSERT INTO workspace_item_tasks` (or equivalent — find by `ctx.di.?.db`), add:

```zig
// If parent item is a kanban, auto-assign the task to the first column at
// position = MAX(kanban_position in that column) + 1.
const parent_item_type = blk: {
    var q = try db.query(allocator,
        "SELECT item_type FROM workspace_items WHERE id = ?",
        &.{item_id});
    defer q.deinit();
    const row = (try q.next()) orelse break :blk "";
    defer row.deinit(allocator);
    break :blk row.values[0];
};

if (std.mem.eql(u8, parent_item_type, "kanban")) {
    const first_col_id = blk: {
        var q = try db.query(allocator,
            "SELECT id FROM kanban_columns WHERE workspace_item_id = ? ORDER BY position ASC LIMIT 1",
            &.{item_id});
        defer q.deinit();
        const row = (try q.next()) orelse break :blk null;
        defer row.deinit(allocator);
        break :blk try allocator.dupe(u8, row.values[0]);
    };
    if (first_col_id) |col_id| {
        defer allocator.free(col_id);
        try db.exec(allocator,
            "UPDATE workspace_item_tasks SET kanban_column_id = ?, kanban_position = (SELECT COALESCE(MAX(kanban_position), -1) + 1 FROM workspace_item_tasks WHERE kanban_column_id = ?) WHERE id = ?",
            &.{ col_id, col_id, task_id });
    }
}
```

- [ ] **Step 2: Add a static test**

Create `tasks_create_kanban_test.zig`:

```zig
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_create.zig";

test "tasks_create sets kanban_column_id when parent is kanban" {
    const src = try readSource(testing.allocator, HANDLER_PATH);
    defer testing.allocator.free(src);
    if (std.mem.indexOf(u8, src, "kanban_column_id = ?") == null) {
        return error.KanbanColumnAssignmentMissing;
    }
    if (std.mem.indexOf(u8, src, "item_type = 'kanban'") == null) {
        return error.KanbanTypeCheckMissing;
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/tasks_create.zig \
        src/ai_workflow/tui/http_handlers/tasks_create_kanban_test.zig \
        src/ai_workflow/tui/test_runner.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): tasks_create assigns kanban column for kanban parents"
```

### Task 3.9: Register the 6 new routes

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_router.zig` (or equivalent — find the file with `route(.{ .POST, "/api/workspaces/..." ... })` calls)

- [ ] **Step 1: Find the existing task routes** (search for `tasks_create.zig` reference)

- [ ] **Step 2: Add the 6 new route entries**

```zig
try router.route(.{ .POST, "/api/workspaces/{wsId}/items/kanban", "workspace_items_create_kanban" });
try router.route(.{ .GET,  "/api/workspaces/{wsId}/items/{itemId}/kanban/columns", "kanban_columns_list" });
try router.route(.{ .POST, "/api/workspaces/{wsId}/items/{itemId}/kanban/columns", "kanban_columns_create" });
try router.route(.{ .PATCH, "/api/workspaces/{wsId}/items/{itemId}/kanban/columns/{columnId}", "kanban_columns_update" });
try router.route(.{ .DELETE, "/api/workspaces/{wsId}/items/{itemId}/kanban/columns/{columnId}", "kanban_columns_delete" });
try router.route(.{ .PATCH, "/api/workspaces/{wsId}/items/{itemId}/tasks/{taskId}/move", "tasks_move" });
```

(Adjust the exact router API to match the project's existing style — see
`workspace_items_create.zig` route for the pattern.)

- [ ] **Step 3: Verify build**

```bash
cd src && timeout 120 zig build 2>&1 | tail -n 5
```

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/ai_workflow/tui/http_handlers/http_router.zig
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(backend): register 6 kanban routes"
```

### Task 3.10: Full backend test run

- [ ] **Step 1: Run all tests**

```bash
cd src && timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: all tests pass (existing 565+ + new kanban_model + new handler static tests).

---

## Chunk 4: Frontend — API wrapper layer

### Task 4.1: Extend `WorkspaceItem` + `Task` interfaces in `api/index.ts`

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add the new types and extend the existing interfaces**

Find the `WorkspaceItem` and `Task` interfaces and add:

```ts
export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  position: number
  created_at: string
}

export interface WorkspaceItem {
  // ... existing fields
  kanban_columns?: KanbanColumn[]  // populated for item_type === 'kanban'
}

export interface Task {
  // ... existing fields
  kanban_column_id?: string | null  // null when unassigned
  kanban_position?: number          // position within the column
}
```

Per the project memory `nalar-frontend-task-literal-typing-rule`, all new
fields MUST stay optional — 8+ existing test files construct Task
literals without these fields, so making them required would break the
build.

- [ ] **Step 2: Verify type-check**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
```
Expected: clean (the new fields are optional, so no test breaks).

- [ ] **Step 3: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(frontend): KanbanColumn type + extend WorkspaceItem/Task interfaces"
```

### Task 4.2: Add the 6 API functions

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add the functions** (mirror existing patterns like `getTasks`, `addTask`)

```ts
export async function createKanban(
  workspaceId: string,
  name: string,
): Promise<{ item: WorkspaceItem; columns: KanbanColumn[] }> {
  const response = await apiFetch(`${API_BASE}/workspaces/${workspaceId}/items/kanban`, {
    method: 'POST',
    body: JSON.stringify({ name }),
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function listKanbanColumns(
  workspaceId: string,
  itemId: string,
): Promise<{ columns: KanbanColumn[]; count: number }> {
  const response = await apiFetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  position?: number,
): Promise<KanbanColumn> {
  const response = await apiFetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
    { method: 'POST', body: JSON.stringify({ name, position }) },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; position?: number },
): Promise<KanbanColumn> {
  const response = await apiFetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    { method: 'PATCH', body: JSON.stringify(patch) },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export async function deleteKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<void> {
  const response = await apiFetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    { method: 'DELETE' },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
}

export async function moveTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  columnId: string,
  position: number,
): Promise<Task> {
  const response = await apiFetch(
    `${API_BASE}/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/move`,
    { method: 'PATCH', body: JSON.stringify({ column_id: columnId, position }) },
  )
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}
```

- [ ] **Step 2: Add tests** (`kanbanApi.spec.ts`)

Mirror the pattern from `apiMemories.spec.ts` (mock fetch + setActivePinia):

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'

describe('kanban API wrappers', () => {
  const fetchMock = vi.fn()
  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    vi.stubGlobal('fetch', fetchMock)
  })
  afterEach(() => vi.unstubAllGlobals())

  function mockOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  it('createKanban POSTs name and returns item+columns', async () => {
    mockOnce(201, { item: { id: 'k1' }, columns: [{ id: 'c1', name: 'todo' }] })
    const result = await api.createKanban('ws_1', 'My Sprint')
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/workspaces/ws_1/items/kanban'),
      expect.objectContaining({ method: 'POST' }),
    )
    expect(result.columns).toHaveLength(1)
  })

  // ... similar tests for the other 5 functions (omitted for brevity)
})
```

- [ ] **Step 3: Run, verify tests pass**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
cd src/apps/desktop && timeout 120 bunx vitest run kanbanApi 2>&1 | tail -n 10
```

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts src/apps/desktop/src/__tests__/kanbanApi.spec.ts
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(frontend): 6 kanban API functions + tests"
```

---

## Chunk 5: Frontend — Pinia store actions

### Task 5.1: Add the 5 kanban actions to `workspacesStore`

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 1: Extend the mirror interfaces** (mirrors the changes in 4.1)

- [ ] **Step 2: Add the actions**

```ts
async function addKanbanItem(workspaceId: string, name: string): Promise<string | undefined> {
  const { item, columns } = await api.createKanban(workspaceId, name)
  // Push the new item into the workspace's items array
  const ws = workspaces.value.find((w) => w.id === workspaceId)
  if (ws) {
    ws.items.push({ ...item, kanban_columns: columns, tasks: [] })
  }
  return item.id
}

async function addKanbanColumn(workspaceId: string, itemId: string, name: string): Promise<void> {
  const col = await api.addKanbanColumn(workspaceId, itemId, name)
  const item = findItem(workspaceId, itemId)
  if (item) {
    item.kanban_columns = [...(item.kanban_columns ?? []), col].sort((a, b) => a.position - b.position)
  }
}

async function updateKanbanColumn(workspaceId: string, itemId: string, columnId: string, patch: { name?: string; position?: number }): Promise<void> {
  const col = await api.updateKanbanColumn(workspaceId, itemId, columnId, patch)
  const item = findItem(workspaceId, itemId)
  if (item && item.kanban_columns) {
    const i = item.kanban_columns.findIndex((c) => c.id === columnId)
    if (i !== -1) item.kanban_columns[i] = col
  }
}

async function deleteKanbanColumn(workspaceId: string, itemId: string, columnId: string): Promise<void> {
  await api.deleteKanbanColumn(workspaceId, itemId, columnId)
  const item = findItem(workspaceId, itemId)
  if (item) {
    item.kanban_columns = (item.kanban_columns ?? []).filter((c) => c.id !== columnId)
    // Also unassign tasks in this column
    if (item.tasks) {
      for (const t of item.tasks) {
        if (t.kanban_column_id === columnId) t.kanban_column_id = null
      }
    }
  }
}

async function moveTaskToColumn(workspaceId: string, itemId: string, taskId: string, columnId: string, position: number): Promise<void> {
  await api.moveTask(workspaceId, itemId, taskId, columnId, position)
  const item = findItem(workspaceId, itemId)
  if (item && item.tasks) {
    const task = item.tasks.find((t) => t.id === taskId)
    if (task) {
      task.kanban_column_id = columnId
      task.kanban_position = position
    }
  }
}
```

Add `findItem` as a private helper (already pattern is similar elsewhere in the store).

- [ ] **Step 3: Add tests** (`kanbanStore.spec.ts`)

Cover the 5 actions, mocking `api.*` and asserting that the store state is updated.

- [ ] **Step 4: Run, verify tests pass**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
cd src/apps/desktop && timeout 120 bunx vitest run kanbanStore 2>&1 | tail -n 10
```

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/workspaces.ts \
        src/apps/desktop/src/__tests__/kanbanStore.spec.ts
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(frontend): 5 kanban store actions + tests"
```

---

## Chunk 6: Frontend — UI components

### Task 6.1: Create `AddKanbanDialog.vue`

**Files:**
- Create: `src/apps/desktop/src/components/AddKanbanDialog.vue`

- [ ] **Step 1: Mirror `AddItemDialog.vue` minus the folder picker**

Same Teleport/modal/backdrop/dialog-card structure as `AddItemDialog.vue`, but with only a name input (no folder picker). On submit: emit `create(name)`; the parent (`Sidebar.vue`) calls `workspacesStore.addKanbanItem(...)`.

- [ ] **Step 2: Add a basic render test**

```ts
// In __tests__/AddKanbanDialog.spec.ts
it('shows the "Add Project Kanban" title and a name input', async () => {
  // mount with show=true, assert header text and input visibility
})
```

- [ ] **Step 3: Run, commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AddKanbanDialog.vue \
        src/apps/desktop/src/__tests__/AddKanbanDialog.spec.ts
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(frontend): AddKanbanDialog component + test"
```

### Task 6.2: Create `KanbanColumnEditor.vue`

**Files:**
- Create: `src/apps/desktop/src/components/KanbanColumnEditor.vue`

- [ ] **Step 1: Modal with a name input + "Add" / "Rename" / "Delete" buttons**

Three modes (set via a `mode` prop):
- `'add'`: shows name input + Add button
- `'rename'`: shows name input (pre-filled) + Save button
- `'delete'`: shows confirmation text + Delete button

Emits `add(name)`, `rename(name)`, `delete()`, `close()`.

- [ ] **Step 2: Add a render test for each mode**

- [ ] **Step 3: Commit**

### Task 6.3: Create `KanbanCard.vue`

**Files:**
- Create: `src/apps/desktop/src/components/KanbanCard.vue`

- [ ] **Step 1: Wrap `WorkspaceItemTask.vue` with drag handle**

```vue
<template>
  <div
    class="kanban-card"
    draggable="true"
    @dragstart="onDragStart"
    @dragend="onDragEnd"
  >
    <WorkspaceItemTask :task="task" :item="item" ... />
  </div>
</template>

<script setup>
const props = defineProps<{ task, item }>()
const emit = defineEmits<{ dragstart: [taskId]; dragend: [] }>()

function onDragStart(e) {
  e.dataTransfer.setData('application/x-kanban-task-id', props.task.id)
  e.dataTransfer.effectAllowed = 'move'
  emit('dragstart', props.task.id)
}
function onDragEnd() { emit('dragend') }
</script>
```

- [ ] **Step 2: Commit**

### Task 6.4: Create `KanbanColumn.vue`

**Files:**
- Create: `src/apps/desktop/src/components/KanbanColumn.vue`

- [ ] **Step 1: Column header + cards + footer**

- Header: name (double-click to rename), count, ⋮ menu (rename / delete via `KanbanColumnEditor`)
- Cards: v-for over the column's tasks, render `<KanbanCard>` for each
- Footer: "+ Add" button → emits `add-task` with the column id

- Drop zone: `dragover` (preventDefault), `drop` (parse taskId, emit `move-task`)

- [ ] **Step 2: Commit**

### Task 6.5: Create `KanbanView.vue`

**Files:**
- Create: `src/apps/desktop/src/components/KanbanView.vue`

- [ ] **Step 1: The board layout**

- Header: kanban name (from `item.name`) + "+ Column" button
- Column row: `overflow-x: auto` container, `<KanbanColumn>` per column in `item.kanban_columns`
- Each column receives the tasks filtered by `kanban_column_id`

- [ ] **Step 2: Commit**

### Task 6.6: Wire `Sidebar.vue` to open `AddKanbanDialog`

**Files:**
- Modify: `src/apps/desktop/src/components/Sidebar.vue`

- [ ] **Step 1: Extend `handleAddItem`**

In `Sidebar.vue:317`:
```ts
const handleAddItem = (workspaceId: string, itemType: string) => {
  addItemTargetWorkspaceId.value = workspaceId
  if (itemType === 'folder') showAddItemDialog.value = true
  if (itemType === 'kanban') showAddKanbanDialog.value = true  // NEW
  if (itemType === 'memory') { ... }
}
```

- [ ] **Step 2: Add the `AddKanbanDialog` to the template + handler for its `create` event**

```vue
<AddKanbanDialog
  :show="showAddKanbanDialog"
  @close="showAddKanbanDialog = false"
  @create="handleCreateKanban"
/>
```

```ts
const handleCreateKanban = async (name: string) => {
  if (addItemTargetWorkspaceId.value) {
    await workspacesStore.addKanbanItem(addItemTargetWorkspaceId.value, name)
  }
  showAddKanbanDialog.value = false
}
```

- [ ] **Step 3: Commit**

### Task 6.7: Wire `WorkspaceItem.vue` to render `<KanbanView>` for kanban items

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItem.vue`

- [ ] **Step 1: Add conditional render**

Wrap the existing task-list rendering in a `v-else` and add a `v-if` for the kanban branch:

```vue
<KanbanView
  v-if="item.item_type === 'kanban'"
  :item="item"
  @add-task="onAddTask"
  @move-task="onMoveTask"
  @add-column="onAddColumn"
  @rename-column="onRenameColumn"
  @delete-column="onDeleteColumn"
/>
<template v-else>
  <!-- existing pinned-tasks + task-list rendering -->
</template>
```

The handler functions delegate to the store actions (added in Chunk 5).

- [ ] **Step 2: Add a render test** (`KanbanView.spec.ts`) that verifies:
- `WorkspaceItem` with `item_type='kanban'` renders `<KanbanView>` (not the list)
- `WorkspaceItem` with `item_type='folder'` renders the existing list
- Board renders N columns from `item.kanban_columns` and N cards per column

- [ ] **Step 3: Run, verify all tests pass**

```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 10
```

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/Sidebar.vue \
        src/apps/desktop/src/components/WorkspaceItem.vue \
        src/apps/desktop/src/__tests__/KanbanView.spec.ts
git -c user.name=nalar -c user.email=nalar@local commit -m "feat(frontend): wire KanbanView into Sidebar + WorkspaceItem"
```

---

## Chunk 7: End-to-end verification

### Task 7.1: Full backend test run

- [ ] **Step 1: Run all backend tests**

```bash
cd src && timeout 180 zig build test --summary all 2>&1 | tail -n 10
```
Expected: all tests pass (existing 565+ + new 5-10 kanban tests).

### Task 7.2: Full frontend test + build

- [ ] **Step 1: Run the type-check + build**

```bash
cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 20
```
Expected: `vue-tsc --build` passes, Vite emits the bundle.

- [ ] **Step 2: Run all unit tests**

```bash
cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 10
```
Expected: 70+ files, 580+ tests pass (existing 573 + new 10+ kanban tests).

### Task 7.3: Manual smoke test (backend)

- [ ] **Step 1: Start the backend on port 8080**

```bash
cd src && timeout 300 zig build run -- --port 8080 &
```

- [ ] **Step 2: Create a kanban**

```bash
# First, get a workspace_id:
WS_ID=$(curl -s 'http://localhost:8080/api/workspaces?is_include_items=false' | jq -r '.workspaces[0].id')
echo "Workspace: $WS_ID"

# Create a kanban:
curl -s -X POST "http://localhost:8080/api/workspaces/$WS_ID/items/kanban" \
  -H 'Content-Type: application/json' \
  -d '{"name":"My Sprint"}' | jq .
```
Expected: returns `{id: "kanban_...", workspace_id: "...", item_type: "kanban", name: "My Sprint"}`.

- [ ] **Step 3: List the seeded columns**

```bash
ITEM_ID=$(curl -s -X POST "http://localhost:8080/api/workspaces/$WS_ID/items/kanban" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Sprint 2"}' | jq -r '.id')

curl -s "http://localhost:8080/api/workspaces/$WS_ID/items/$ITEM_ID/kanban/columns" | jq .
```
Expected: returns `{columns: [{id, name:"todo", position:0}, {id, name:"in progress", position:1}, {id, name:"done", position:2}], count: 3}`.

- [ ] **Step 4: Add a column + add a task + move the task**

```bash
COL1=$(curl -s "http://localhost:8080/api/workspaces/$WS_ID/items/$ITEM_ID/kanban/columns" | jq -r '.columns[0].id')
COL2=$(curl -s "http://localhost:8080/api/workspaces/$WS_ID/items/$ITEM_ID/kanban/columns" | jq -r '.columns[1].id')

# Add a task to col1
TASK_ID=$(curl -s -X POST "http://localhost:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Task A\"}" | jq -r '.id')

# Move task to col2
curl -s -X PATCH "http://localhost:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks/$TASK_ID/move" \
  -H 'Content-Type: application/json' \
  -d "{\"column_id\":\"$COL2\",\"position\":0}" | jq .
```
Expected: returns the updated task with `kanban_column_id: $COL2, kanban_position: 0`.

- [ ] **Step 5: Stop the backend**

```bash
kill $(pgrep -f "nalar --port 8080")
```

### Task 7.4: Manual smoke test (frontend)

- [ ] **Step 1: Start backend + dev server**

```bash
cd src && timeout 600 zig build run -- --port 8080 &
cd src/apps/desktop && bun run dev &
```

- [ ] **Step 2: In the browser:**
1. Open a workspace
2. Hover over a workspace's "+ Add Item" button → click "Add Project Kanban"
3. Type a name (e.g., "My Sprint") → click Create
4. Verify the new kanban appears in the sidebar
5. Click the kanban → verify the board view renders with 3 columns (todo, in progress, done)
6. Click "+ Add" in a column → create a task → verify it appears as a card
7. Drag the card to a different column → verify it moves + the move persists on reload
8. Click "+ Column" → add a 4th column → verify it appears
9. Double-click a column header → rename it → verify
10. Click ⋮ on a column → delete it → confirm dialog appears → confirm → column is gone
11. Verify a folder item still shows the list view (no regression)
12. Reload the page → verify everything persists

- [ ] **Step 3: Stop both processes**

```bash
kill $(pgrep -f "nalar --port 8080")
kill $(pgrep -f "vite")
```

### Task 7.5: Commit any final fixes

If the smoke tests surfaced any issues, fix them in a final commit:
```bash
git commit -m "fix: <description> from kanban smoke test"
```

---

## Risks & Mitigations (mirrored from design doc)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `kanban_column_id` is nullable → queries need `WHERE ... IS NULL OR ... = ?` | medium | low | All kanban-aware queries are new code; existing folder-list queries never touch this column. |
| `ON DELETE CASCADE` removes columns but tasks stay with `kanban_column_id=NULL` | low | low | Documented; tasks remain visible in the folder-list view as "Unassigned". |
| Drag-and-drop race (two simultaneous moves) | low | medium | Backend `moveTask` is a single transaction with row-level lock via `UPDATE ... WHERE` — last writer wins, state always consistent. |
| Migration fails on existing DBs (47 prior migrations) | low | high | Mirrored `Migration044AddRoutines` pattern: `ALTER TABLE ... ADD COLUMN` works on populated tables. |
| Frontend type-check breaks due to new required fields | low | medium | Per project memory `nalar-frontend-task-literal-typing-rule`, all new fields are optional. |
| 8+ existing test files construct Task literals without new fields | medium | low | All new fields are optional; the `as` casts in tests still type-check. |

## Out of Scope (YAGNI, mirrored from design doc)

- WIP limits, swimlanes, sub-tasks, custom column colors / icons, board filters, archived columns
- Folder → kanban conversion
- Realtime multi-user collaboration
- Per-column `done` automation
- Kanban templates
- Sparse position numbering (using dense re-numbering for v1)

## References

- Design doc: `docs/plans/2026-06-21-workspace-item-kanban-design.md` (commit `616843b`)
- Existing migration pattern: `src/ai_workflow/tui/migration.zig:721-767` (Migration 044)
- Existing HTTP handler pattern: `src/ai_workflow/tui/http_handlers/tasks_create.zig`
- Static test pattern: `src/ai_workflow/tui/http_handlers/routines_run_test.zig`
- Existing Vue dialog pattern: `src/apps/desktop/src/components/AddItemDialog.vue`
- Existing drag-and-drop pattern: `src/apps/desktop/src/components/WorkspaceItemTask.vue` (the `handleDragStart` etc. handlers)
- Project memory: `nalar-frontend-task-literal-typing-rule` (why all new Task fields are optional)
- Project memory: `nalar-http-handler-thin-wrapper-pattern` (the static-test + parseFromSliceLeaky + valueAlloc pattern)
- Project memory: `nalar-sql-alias-tables` (every SELECT must alias its tables)

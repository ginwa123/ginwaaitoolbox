# Kanban Column Description + Settings Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `description` (free-text meaning) field to every kanban column, expose it through the existing add/rename PATCH endpoints, and provide a per-board **Kanban Settings** dialog (opened from a new ⚙ button on the kanban header) that lists all columns with their descriptions and lets the user add new columns (name + description) without leaving the board context.

**Architecture:** Backend (Zig + SQLite) gets a new Migration 053 adding a nullable `description TEXT` column to `kanban_columns` (NOT NULL with `DEFAULT ''` so existing rows remain valid; existing `seedDefaultColumns` and `addColumn` are extended to accept an optional description). The `KanbanColumn` struct, `listColumns` SELECT, and `KanbanColumnResponse` wire shape gain the new field. `renameColumn` is renamed to `updateColumn` and now accepts optional `name` + `description` (mirroring the PATCH endpoint's body shape). Frontend gets a new `description?: string | null` field on `KanbanColumn`, a description textarea inside `KanbanColumnEditor.vue` (for add and rename modes), a description tooltip under each `KanbanColumn` header, and a new `KanbanSettingsDialog.vue` mounted from `AppLayout.vue` that exposes a full-column-table view + an "Add Column" form with both fields.

**Tech Stack:** Zig 0.16 backend, SQLite (in-memory for tests), Vue 3 + TypeScript + Pinia + Vitest frontend, Tailwind utility classes, the project's existing `parseFromSliceLeaky` + `std.json.Stringify.valueAlloc` JSON conventions.

**Spec:** This plan is the implementation spec; no separate design doc exists.

---

## Context

### Current state

- `kanban_columns` table (Migration 051, `src/ai_workflow/tui/migration.zig:914-965`): `id`, `workspace_item_id`, `name`, `position`, `created_at`. No `description`.
- `KanbanColumn` struct (`src/ai_workflow/tui/kanban_model.zig:31-37`) has 5 fields; `addColumn` (`kanban_model.zig:120-149`) takes only `name`.
- POST handler `kanbanColumnsCreateHandler` (`src/ai_workflow/tui/http_handlers/kanban_columns_create.zig:36-141`) accepts `{name, position?}` via `parseFromSliceLeaky`.
- PATCH handler `kanbanColumnsUpdateHandler` (`http_handlers/kanban_columns_update.zig:40-143`) accepts `{name?, position?}`.
- Wire shape `KanbanColumnResponse` (`http_handlers/http_response.zig:21-66`) and frontend interface `KanbanColumn` (`src/apps/desktop/src/api/index.ts:117-123`) have 5 fields each.
- Frontend `KanbanColumnEditor.vue` (293 lines) is a single 3-mode modal (add / rename / delete). It shows only a `<input type="text">` for the name; no description field.
- `KanbanView.vue` (319 lines) is the board renderer; its header has only a `+ Column` button. There is no per-board settings UI.
- `SettingsView.vue` (135 lines) is a global fullscreen overlay with Nalar / Skills / Memories tabs. Adding a Kanban tab there is technically possible but requires the user to navigate away from the board — the user's request is clearly per-board.

### What this plan delivers

1. A new `kanban_columns.description TEXT NOT NULL DEFAULT ''` column (Migration 053).
2. Backend model + handler + response updates so every column row carries a description through CRUD.
3. Frontend `KanbanColumn` interface gains an optional `description?: string | null`.
4. `KanbanColumnEditor.vue` add/rename modes get a description textarea (optional; empty by default; 500-char limit enforced client-side).
5. `KanbanColumn.vue` shows the description as a 1-line truncated tooltip + a small grey subtitle below the column header.
6. A new `KanbanSettingsDialog.vue` accessible from a new ⚙ button on `KanbanView.vue`'s header. The dialog lists every column with name + description + edit/delete actions, and has an "Add Column" inline form (name + description).
7. SSE `kanban_column` events include the new description so other connected clients refresh in place.

### What's out of scope (deliberately)

- Column color / icon customisation.
- Markdown rendering in descriptions (plain text only; newlines preserved).
- AI-generated column suggestions.
- Bulk-import (CSV/JSON) of columns.
- Renaming the existing 3 default `todo / in progress / done` columns to ship with descriptions (the seed stays empty; users add descriptions when they open the Settings dialog).

---

## File Structure

### New backend files

| File | Responsibility |
|---|---|
| `src/ai_workflow/tui/kanban_model_test_description.zig` | Unit tests for `addColumn` with description + `updateColumn` (rename + description edit) |
| `src/ai_workflow/tui/migration_053_test.zig` | Up/down test for Migration 053 |

### Modified backend files

| File | Change |
|---|---|
| `src/ai_workflow/tui/migration.zig` | Add `Migration053AddKanbanColumnDescription` struct (version 53) + register in `Migrations` array |
| `src/ai_workflow/tui/kanban_model.zig` | Add `description: []u8` to `KanbanColumn`; `listColumns` SELECTs it; `addColumn` accepts `description` param; `freeColumns` frees it; `renameColumn` → `updateColumn(name: ?[]const u8, description: ?[]const u8)`; `seedDefaultColumns` passes `""` for description |
| `src/ai_workflow/tui/http_handlers/http_response.zig` | Add `description: []const u8` to `KanbanColumnResponse`; map it in `makeKanbanColumnResponse` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig` | Body struct gets `description: ?[]const u8 = null`; pass to `addColumn`; default to `""` when null |
| `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig` | Body struct: rename `name?` to keep semantics; add `description?: ?[]const u8 = null`; validate "at least one of name/description/position is set"; pass to `updateColumn` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_create_test.zig` | Add static-contract tests asserting the handler accepts `description` |
| `src/ai_workflow/tui/http_handlers/kanban_columns_update_test.zig` | Add static-contract tests asserting the handler forwards `description` |
| `src/ai_workflow/tui/on_event_sent_kanban.zig` | Extend `KanbanColumnEventPayload` with optional `new_description` |
| `src/ai_workflow/tui/test_runner.zig` | Register `migration_053_test.zig` + `kanban_model_test_description.zig` |

### New frontend files

| File | Responsibility |
|---|---|
| `src/apps/desktop/src/components/KanbanSettingsDialog.vue` | Modal listing every column of the active kanban + an "Add Column" form (name + description) + per-row edit/delete actions |
| `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts` | Vitest unit tests for the new dialog |
| `src/apps/desktop/src/__tests__/KanbanColumnDescription.spec.ts` | Vitest unit tests for description rendering in KanbanColumn header |

### Modified frontend files

| File | Change |
|---|---|
| `src/apps/desktop/src/api/index.ts` | `KanbanColumn` interface: add `description?: string \| null`. `addKanbanColumn` + `updateKanbanColumn` accept optional `description`. `KanbanColumnEvent` interface: add `new_description?`. |
| `src/apps/desktop/src/stores/workspaces.ts` | `addKanbanColumn` + `updateKanbanColumn` actions forward the description field |
| `src/apps/desktop/src/components/KanbanColumnEditor.vue` | Add `initialDescription?: string` prop; add a `<textarea>` below the name input in add/rename modes; emit `add(name, description)` and `rename(name, description)` |
| `src/apps/desktop/src/components/KanbanColumn.vue` | Display description below column name (1-line truncated + tooltip on hover) |
| `src/apps/desktop/src/components/KanbanView.vue` | Add ⚙ Settings button in header; emit `open-settings` upward; pass `column.description` to `<KanbanColumn>` |
| `src/apps/desktop/src/components/AppLayout.vue` | Mount `<KanbanSettingsDialog>`; `showKanbanSettingsDialog` ref + handlers; open from KanbanView emit |
| `src/apps/desktop/src/__tests__/KanbanColumnEditor.spec.ts` | New tests for description textarea (add + rename) |
| `src/apps/desktop/src/__tests__/kanbanApi.spec.ts` | Update mocks to assert description round-trips on addKanbanColumn + updateKanbanColumn |
| `src/apps/desktop/src/__tests__/kanbanStore.spec.ts` | Update store tests to forward description |

---


## Chunk 1: Backend — Migration 053 + model + handlers + response

> Smallest possible backend chunk. Every step is independently testable. Builds on top of the existing 051 migration.

### Task 1.1: Add Migration 053

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig` (append after `Migration052DropSessionIdFromWorkspaceItemTasks`, before the closing `};` of the array at line 1124)
- Create: `src/ai_workflow/tui/migration_053_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the new test)

- [ ] **Step 1: Write the failing test**

Create `src/ai_workflow/tui/migration_053_test.zig` (mirror the structure of `migration_test.zig:54-89` — `setupDb` pattern):

```zig
//! Static regression checks for Migration 053 (add kanban_column.description).
//!
//! Why this file exists
//! ────────────────────
//! Migration 053 introduces the optional `description` column on
//! `kanban_columns` so each column can carry a free-text "meaning"
//! alongside its display name. The migration must:
//!   1. ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''
//!   2. Be idempotent (use DEFAULT so existing rows survive)
//!   3. Add `description` to the pragma_table_info result set
//!
//! Plan: docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md
//!   (Chunk 1, Task 1.1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const Migration051AddKanban = @import("migration.zig").Migration051AddKanban;
const Migration053AddKanbanColumnDescription = @import("migration.zig").Migration053AddKanbanColumnDescription;

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Migration 051 creates kanban_columns — must run before 053.
    try Migration051AddKanban.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "migration 053 adds description column with default empty string" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Sanity: kanban_columns exists (051 seeded it).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q.deinit();
    const names_before: [4][]const u8 = .{ "id", "workspace_item_id", "name", "position" };
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < names_before.len);
        try testing.expectEqualStrings(names_before[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 4), idx);

    // Apply migration 053.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    // Re-check pragma_table_info — description is now present.
    var q2 = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('kanban_columns') ORDER BY cid
    , &.{});
    defer q2.deinit();
    const names_after: [5][]const u8 = .{ "id", "workspace_item_id", "name", "position", "description" };
    var idx2: usize = 0;
    while (try q2.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx2 < names_after.len);
        try testing.expectEqualStrings(names_after[idx2], row.values[0]);
        idx2 += 1;
    }
    try testing.expectEqual(@as(usize, 5), idx2);
}

test "migration 053 is safe on populated kanban_columns tables" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Insert one existing row (no description column yet).
    try ctx.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) " ++
        "VALUES ('col_pre_053', 'wi_1', 'todo', 0)",
        &.{},
    );

    // Apply migration 053 — the existing row should get description=''.
    try Migration053AddKanbanColumnDescription.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        "SELECT description FROM kanban_columns WHERE id = 'col_pre_053'",
        &.{},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}
```

- [ ] **Step 2: Register the test**

Add `_ = @import("migration_053_test.zig");` to `src/ai_workflow/tui/test_runner.zig` next to the other migration test registrations.

- [ ] **Step 3: Run test to verify it fails**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: compile error `Migration053AddKanbanColumnDescription not found` (the migration struct doesn't exist yet).

- [ ] **Step 4: Implement the migration**

In `src/ai_workflow/tui/migration.zig`, after `Migration052DropSessionIdFromWorkspaceItemTasks` (around line 967), add:

```zig
pub const Migration053AddKanbanColumnDescription = struct {
    pub const version: u32 = 53;
    pub const name = "add_kanban_column_description";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Kanban column description — Chunk 1 of the
        // kanban-column-description-settings plan. Each kanban
        // column gains a free-text "meaning" field that the
        // Settings UI displays and edits. NOT NULL with DEFAULT ''
        // so existing rows (which have no description) survive the
        // ALTER TABLE without backfill. The frontend uses the
        // empty string as the "no description" sentinel — the
        // Settings UI shows "Add a description…" placeholder for
        // empty descriptions.
        //
        // Why NOT NULL (vs nullable):
        //   1. The application always reads description as
        //      []const u8 (never ?[]const u8) — a nullable column
        //      would force every SELECT to COALESCE and every
        //      INSERT to handle NULL explicitly.
        //   2. The DB-level NOT NULL is a defensive check; the
        //      application layer never writes NULL.
        //   3. Mirrors the project's convention for short text
        //      fields with a sentinel "absent" value.
        try db.exec(allocator,
            "ALTER TABLE kanban_columns ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            &[_][]const u8{},
        );
    }
};
```

Then in the `Migrations` array (around line 1123), append:

```zig
.{ .version = Migration053AddKanbanColumnDescription.version, .name = Migration053AddKanbanColumnDescription.name, .up = Migration053AddKanbanColumnDescription.up },
```

- [ ] **Step 5: Run test to verify it passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 2 new tests pass; no regressions.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/migration.zig \
        src/ai_workflow/tui/migration_053_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "feat(kanban): add Migration053 — kanban_columns.description"
```

### Task 1.2: Extend `KanbanColumn` struct + `listColumns` + `addColumn` + `freeColumns`

**Files:**
- Modify: `src/ai_workflow/tui/kanban_model.zig:31-90, 120-191`

- [ ] **Step 1: Update the `KanbanColumn` struct**

In `kanban_model.zig:31-37`, change:

```zig
pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    position: i64,
    created_at: []u8,
};
```

to:

```zig
pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    description: []u8,
    position: i64,
    created_at: []u8,
};
```

- [ ] **Step 2: Update `freeColumns` (line 40-48)**

Add `allocator.free(c.description);` between `c.name` and `c.position`:

```zig
pub fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.description);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}
```

- [ ] **Step 3: Update `listColumns` SELECT + `KanbanColumn` literal (line 60-89)**

Change the query string:

```zig
var q = try db.query(allocator,
    \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.position, COALESCE(kc.created_at, '')
    \\FROM kanban_columns kc
    \\WHERE kc.workspace_item_id = ?
    \\ORDER BY kc.position ASC
, &.{workspace_item_id});
```

to:

```zig
var q = try db.query(allocator,
    \\SELECT kc.id, kc.workspace_item_id, kc.name, kc.description, kc.position, COALESCE(kc.created_at, '')
    \\FROM kanban_columns kc
    \\WHERE kc.workspace_item_id = ?
    \\ORDER BY kc.position ASC
, &.{workspace_item_id});
```

Note `description` is NOT NULL with DEFAULT '' so no `COALESCE` is needed.

Change the row literal (line 81-87):

```zig
try rows.append(allocator, .{
    .id = try allocator.dupe(u8, row.values[0]),
    .workspace_item_id = try allocator.dupe(u8, row.values[1]),
    .name = try allocator.dupe(u8, row.values[2]),
    .position = std.fmt.parseInt(i64, row.values[3], 10) catch 0,
    .created_at = try allocator.dupe(u8, row.values[4]),
});
```

to:

```zig
try rows.append(allocator, .{
    .id = try allocator.dupe(u8, row.values[0]),
    .workspace_item_id = try allocator.dupe(u8, row.values[1]),
    .name = try allocator.dupe(u8, row.values[2]),
    .description = try allocator.dupe(u8, row.values[3]),
    .position = std.fmt.parseInt(i64, row.values[4], 10) catch 0,
    .created_at = try allocator.dupe(u8, row.values[5]),
});
```

Also update the `errdefer` block (line 69-77) to add `allocator.free(c.description);` (mirror the `freeColumns` change).

- [ ] **Step 4: Update `addColumn` (line 120-149)**

Change the signature + body to accept description:

```zig
pub fn addColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    description: []const u8,
    position: ?i64,
) ![]u8 {
    const id = try generateColumnId(allocator);
    defer allocator.free(id);

    const pos = position orelse blk: {
        var q = try db.query(allocator,
            \\SELECT COALESCE(MAX(kc.position), -1) + 1
            \\FROM kanban_columns kc
            \\WHERE kc.workspace_item_id = ?
        , &.{workspace_item_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoMaxPosition;
        defer row.deinit(allocator);
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };

    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{pos});
    defer allocator.free(pos_str);

    try db.exec(allocator,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, description, position) " ++
        "VALUES (?, ?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, description, pos_str });
    return allocator.dupe(u8, id);
}
```

- [ ] **Step 5: Update `seedDefaultColumns` (line 155-175)**

Pass `""` as the description for each seeded column:

```zig
{
    const id = try addColumn(allocator, db, workspace_item_id, "todo", "", 0);
    defer allocator.free(id);
}
{
    const id = try addColumn(allocator, db, workspace_item_id, "in progress", "", 1);
    defer allocator.free(id);
}
{
    const id = try addColumn(allocator, db, workspace_item_id, "done", "", 2);
    defer allocator.free(id);
}
```

- [ ] **Step 6: Rename `renameColumn` → `updateColumn` with optional name + description**

Replace `renameColumn` (line 180-191) with:

```zig
/// Update an existing column. `name` and `description` are both
/// optional; at least one must be non-null (validated at the HTTP
/// handler layer). Only non-null fields are written — a null
/// `name` leaves the existing name unchanged, a null
/// `description` leaves the existing description unchanged.
///
/// `workspace_item_id` is accepted for symmetry with the other
/// column-mutators but the WHERE clause matches only on `id`
/// (column ids are globally unique within the schema).
pub fn updateColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
    name: ?[]const u8,
    description: ?[]const u8,
) !void {
    _ = workspace_item_id;
    if (name) |n| {
        try db.exec(allocator,
            "UPDATE kanban_columns SET name = ? WHERE id = ?",
            &.{ n, column_id });
    }
    if (description) |d| {
        try db.exec(allocator,
            "UPDATE kanban_columns SET description = ? WHERE id = ?",
            &.{ d, column_id });
    }
}
```

- [ ] **Step 7: Run tests to verify the rename compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | rg -A2 "error:" | head -n 30`
Expected: 2 files have compile errors: `kanban_columns_create.zig` and `kanban_columns_update.zig`. That's expected — Chunk 1 fixes them in Task 1.3 + 1.4.

- [ ] **Step 8: Commit**

```bash
git add src/ai_workflow/tui/kanban_model.zig
git commit -m "feat(kanban): extend KanbanColumn with description + generalize rename to update"
```

### Task 1.3: Update POST handler to accept description

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig`
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_create_test.zig`

- [ ] **Step 1: Add `description` to the request body struct (line 31-34)**

Change:

```zig
const CreateColumnBody = struct {
    name: []const u8,
    position: ?i64 = null,
};
```

to:

```zig
const CreateColumnBody = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    position: ?i64 = null,
};
```

- [ ] **Step 2: Default description to `""` when null and pass to `addColumn` (line 79)**

Change:

```zig
const new_id = kanban_model.addColumn(allocator, sqlite_db, item_id, parsed.name, parsed.position) catch {
```

to:

```zig
// Empty string is the "no description" sentinel (the DB column is
// NOT NULL DEFAULT '', and the frontend renders "" as the
// "Add a description..." placeholder).
const description = parsed.description orelse "";
const new_id = kanban_model.addColumn(allocator, sqlite_db, item_id, parsed.name, description, parsed.position) catch {
```

- [ ] **Step 3: Pass `description` to the `KanbanColumnResponse` (line 120-130)**

Change:

```zig
return res.jsonResponse(.{
    .status_code = 201,
    .data = try std.json.Stringify.valueAlloc(
        allocator,
        http_response.KanbanColumnResponse{
            .id = c.id,
            .workspace_item_id = c.workspace_item_id,
            .name = c.name,
            .position = c.position,
            .created_at = c.created_at,
        },
        .{},
    ),
});
```

to:

```zig
return res.jsonResponse(.{
    .status_code = 201,
    .data = try std.json.Stringify.valueAlloc(
        allocator,
        http_response.KanbanColumnResponse{
            .id = c.id,
            .workspace_item_id = c.workspace_item_id,
            .name = c.name,
            .description = c.description,
            .position = c.position,
            .created_at = c.created_at,
        },
        .{},
    ),
});
```

Note: `KanbanColumnResponse.description` is added in Task 1.5. The compile will fail until then.

- [ ] **Step 4: Add a static-contract test**

Append to `src/ai_workflow/tui/http_handlers/kanban_columns_create_test.zig`:

```zig
test "kanban_columns_create handler extracts description from parsed body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must extract `description` from the parsed body
    // (defaulting to empty string when null) and pass it to
    // kanban_model.addColumn.
    if (std.mem.indexOf(u8, source, "parsed.description") == null) {
        std.debug.print(
            "\n!! {s} does not extract .description from the parsed body !!\n" ++
                "   The handler must reference `parsed.description` (or default to \"\") for the new column.\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionExtractionMissing;
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/kanban_columns_create.zig \
        src/ai_workflow/tui/http_handlers/kanban_columns_create_test.zig
git commit -m "feat(kanban): POST /kanban/columns accepts description"
```

### Task 1.4: Update PATCH handler to accept description (and switch from `renameColumn` to `updateColumn`)

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_update.zig`
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_update_test.zig`

- [ ] **Step 1: Add `description` to the request body struct (line 35-38)**

Change:

```zig
const UpdateColumnBody = struct {
    name: ?[]const u8 = null,
    position: ?i64 = null,
};
```

to:

```zig
const UpdateColumnBody = struct {
    name: ?[]const u8 = null,
    /// New description (only set when the caller wants to change it;
    /// null leaves the existing description unchanged).
    description: ?[]const u8 = null,
    position: ?i64 = null,
};
```

- [ ] **Step 2: Update the validation message (line 83-88)**

Change:

```zig
if (parsed.name == null and parsed.position == null) {
    return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "At least one of name or position is required" }),
    });
}
```

to:

```zig
if (parsed.name == null and parsed.description == null and parsed.position == null) {
    return res.jsonResponse(.{
        .status_code = 400,
        .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "At least one of name, description, or position is required" }),
    });
}
```

- [ ] **Step 3: Switch from `renameColumn` to `updateColumn` (line 90-106)**

Change:

```zig
if (parsed.name) |new_name| {
    kanban_model.renameColumn(allocator, sqlite_db, item_id, column_id, new_name) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to rename column" }),
        });
    };
}

if (parsed.position) |new_pos| {
    kanban_model.reorderColumn(allocator, sqlite_db, item_id, column_id, new_pos) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder column" }),
        });
    };
}
```

to:

```zig
if (parsed.name != null or parsed.description != null) {
    kanban_model.updateColumn(allocator, sqlite_db, item_id, column_id, parsed.name, parsed.description) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update column" }),
        });
    };
}

if (parsed.position) |new_pos| {
    kanban_model.reorderColumn(allocator, sqlite_db, item_id, column_id, new_pos) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder column" }),
        });
    };
}
```

Note: we call `updateColumn` once with both optionals; the model writes only the non-null fields.

- [ ] **Step 4: Extend the SSE emit (line 124-137)**

Change the `KanbanColumnEventPayload` literal:

```zig
const action: []const u8 = if (parsed.position != null) "reordered" else "updated";
on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
    .action = action,
    .workspace_id = ws_id,
    .item_id = item_id,
    .column_id = column_id,
    .new_name = parsed.name,
    .new_description = parsed.description,
    .new_position = parsed.position,
}) catch |err| {
    std.log.warn(
        "kanban_columns_update: SSE emit failed (non-fatal): {s}",
        .{@errorName(err)},
    );
};
```

- [ ] **Step 5: Add a static-contract test**

Append to `src/ai_workflow/tui/http_handlers/kanban_columns_update_test.zig`:

```zig
test "kanban_columns_update handler forwards description to kanban_model.updateColumn" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "parsed.description") == null) {
        std.debug.print(
            "\n!! {s} does not extract .description from the parsed body !!\n" ++
                "   The PATCH endpoint must accept `description` so the Settings UI can edit meanings.\n",
            .{HANDLER_PATH},
        );
        return error.DescriptionExtractionMissing;
    }
    if (std.mem.indexOf(u8, source, "kanban_model.updateColumn") == null) {
        std.debug.print(
            "\n!! {s} still calls renameColumn instead of updateColumn !!\n" ++
                "   Migrate the handler from renameColumn to updateColumn.\n",
            .{HANDLER_PATH},
        );
        return error.UpdateColumnCallMissing;
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/kanban_columns_update.zig \
        src/ai_workflow/tui/http_handlers/kanban_columns_update_test.zig
git commit -m "feat(kanban): PATCH /kanban/columns accepts description via updateColumn"
```

### Task 1.5: Add `description` to `KanbanColumnResponse` + mapper

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`

- [ ] **Step 1: Extend `KanbanColumnResponse` (line 21-27)**

Change:

```zig
pub const KanbanColumnResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    position: i64,
    created_at: []const u8,
};
```

to:

```zig
pub const KanbanColumnResponse = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    name: []const u8,
    /// Free-text description of what the column means. Empty
    /// string when the column has no description set. The frontend
    /// renders "" as the "Add a description..." placeholder.
    description: []const u8,
    position: i64,
    created_at: []const u8,
};
```

- [ ] **Step 2: Update the mapper (line 33-41)**

Change:

```zig
pub fn makeKanbanColumnResponse(col: anytype) KanbanColumnResponse {
    return .{
        .id = col.id,
        .workspace_item_id = col.workspace_item_id,
        .name = col.name,
        .position = col.position,
        .created_at = col.created_at,
    };
}
```

to:

```zig
pub fn makeKanbanColumnResponse(col: anytype) KanbanColumnResponse {
    return .{
        .id = col.id,
        .workspace_item_id = col.workspace_item_id,
        .name = col.name,
        .description = col.description,
        .position = col.position,
        .created_at = col.created_at,
    };
}
```

Note: `anytype` keeps the helper decoupled from `kanban_model.KanbanColumn`. Any future column struct must expose `description: []const u8` or this mapper will not type-check.

- [ ] **Step 3: Verify the build is clean**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: all tests pass; no compile errors.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(kanban): add description to KanbanColumnResponse wire shape"
```

### Task 1.6: Extend `KanbanColumnEventPayload` with `new_description`

**Files:**
- Modify: `src/ai_workflow/tui/on_event_sent_kanban.zig`
- Modify: `src/ai_workflow/tui/http_handlers/kanban_columns_create.zig`

- [ ] **Step 1: Add the field to the payload struct (line 51-61)**

Change:

```zig
pub const KanbanColumnEventPayload = struct {
    /// "created" | "updated" | "deleted" | "reordered"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    column_id: []const u8,
    /// New column name (only set for "updated"; null otherwise).
    new_name: ?[]const u8 = null,
    /// New position (only set for "updated" / "reordered"; null otherwise).
    new_position: ?i64 = null,
};
```

to:

```zig
pub const KanbanColumnEventPayload = struct {
    /// "created" | "updated" | "deleted" | "reordered"
    action: []const u8,
    workspace_id: []const u8,
    item_id: []const u8,
    column_id: []const u8,
    /// New column name (only set for "updated"; null otherwise).
    new_name: ?[]const u8 = null,
    /// New column description (only set for "updated"; null
    /// otherwise). The frontend ignores nulls and re-fetches the
    /// full column list anyway, but carrying the value lets future
    /// in-place patch optimisations skip the GET.
    new_description: ?[]const u8 = null,
    /// New position (only set for "updated" / "reordered"; null otherwise).
    new_position: ?i64 = null,
};
```

- [ ] **Step 2: Update the `created` event in `kanban_columns_create.zig`**

The POST handler also emits a `created` event (around line 109-119). Set `new_description` to the newly created column's description:

```zig
on_event_sent_kanban.onEventSendKanbanColumn(allocator, .{
    .action = "created",
    .workspace_id = ws_id,
    .item_id = item_id,
    .column_id = c.id,
    .new_description = c.description,
}) catch |err| {
    std.log.warn(...);
};
```

The `new_name` and `new_position` remain null on `created`; the frontend re-fetches the full row to populate them.

- [ ] **Step 3: Verify the build is clean**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: all tests pass. No regressions.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/on_event_sent_kanban.zig \
        src/ai_workflow/tui/http_handlers/kanban_columns_create.zig
git commit -m "feat(kanban): SSE kanban_column event carries new_description"
```

### Task 1.7: Add in-memory model tests for description

**Files:**
- Create: `src/ai_workflow/tui/kanban_model_test_description.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/ai_workflow/tui/kanban_model_test_description.zig`:

```zig
//! Unit tests for kanban column description (Chunk 1 of
//! kanban-column-description-settings plan).
//!
//! Covers:
//!   1. `addColumn` writes the description
//!   2. `listColumns` returns the description
//!   3. `updateColumn` with only description (no name) leaves the
//!      name unchanged
//!   4. `updateColumn` with only name (no description) leaves the
//!      description unchanged
//!   5. `updateColumn` with both writes both
//!   6. `seedDefaultColumns` writes empty descriptions (NOT NULL
//!      default constraint holds)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const kanban_model = @import("kanban_model.zig");

fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    const migration = @import("migration.zig");
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

test "addColumn writes description to the new row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "in_review", "Awaiting code review", 0,
    );
    defer alloc.free(id);

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("in_review", cols[0].name);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "updateColumn with only description leaves name unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(
        alloc, &ctx.db, "wi_1", id, null, "Not started yet — work in queue",
    );

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("Not started yet — work in queue", cols[0].description);
}

test "updateColumn with only name leaves description unchanged" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "Not started", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(alloc, &ctx.db, "wi_1", id, "backlog", null);

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Not started", cols[0].description);
}

test "updateColumn with both name and description writes both" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const id = try kanban_model.addColumn(
        alloc, &ctx.db, "wi_1", "todo", "old", 0,
    );
    defer alloc.free(id);

    try kanban_model.updateColumn(
        alloc, &ctx.db, "wi_1", id, "backlog", "Newly triaged items",
    );

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqualStrings("backlog", cols[0].name);
    try testing.expectEqualStrings("Newly triaged items", cols[0].description);
}

test "seedDefaultColumns writes empty descriptions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try kanban_model.seedDefaultColumns(alloc, &ctx.db, "wi_1");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_1");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    for (cols) |c| {
        try testing.expectEqualStrings("", c.description);
    }
}
```

- [ ] **Step 2: Register the test**

Add `_ = @import("kanban_model_test_description.zig");` to `src/ai_workflow/tui/test_runner.zig` (next to the existing `kanban_model_test.zig` import).

- [ ] **Step 3: Run test to verify they pass**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 10`
Expected: 5 new tests pass; no regressions.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/kanban_model_test_description.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "test(kanban): cover addColumn/updateColumn description round-trip"
```

---
## Chunk 2: Frontend API + types + store + KanbanColumnEditor description field + KanbanColumn display

> Pure frontend chunk. All pieces ship together so the frontend never sees a half-updated schema.

### Task 2.1: Extend the `KanbanColumn` interface + API wrappers

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add `description` to the interface (line 117-123)**

Change:

```ts
export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  position: number
  created_at: string
}
```

to:

```ts
export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /**
   * Free-text description of the column's meaning (e.g. "Awaiting
   * code review — tasks here must pass CI before merge"). Empty
   * string when no description has been set. The Settings UI
   * renders an "Add a description..." placeholder for empty
   * values. Optional for backwards compat with legacy column
   * literals in test files (see nalar-frontend-task-literal-typing-rule).
   */
  description?: string | null
  position: number
  created_at: string
}
```

- [ ] **Step 2: Update `addKanbanColumn` (line 1124-1137)**

Change:

```ts
export async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  position?: number,
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
    {
      method: 'POST',
      body: { name, position },
    },
  )
}
```

to:

```ts
export async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  description?: string,
  position?: number,
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
    {
      method: 'POST',
      body: { name, description: description ?? '', position },
    },
  )
}
```

Note: `description ?? ''` matches the backend's "empty string is the no-description sentinel" convention.

- [ ] **Step 3: Update `updateKanbanColumn` (line 1146-1159)**

Change:

```ts
export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; position?: number },
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    {
      method: 'PATCH',
      body: patch,
    },
  )
}
```

to:

```ts
export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; description?: string; position?: number },
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    {
      method: 'PATCH',
      body: patch,
    },
  )
}
```

- [ ] **Step 4: Extend `KanbanColumnEvent` (around line 1864)**

Change:

```ts
export interface KanbanColumnEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  column_id: string
  new_name?: string | null
  new_position?: number | null
}
```

to:

```ts
export interface KanbanColumnEvent {
  action: 'created' | 'updated' | 'deleted' | 'reordered'
  workspace_id: string
  item_id: string
  column_id: string
  new_name?: string | null
  new_description?: string | null
  new_position?: number | null
}
```

- [ ] **Step 5: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build (vue-tsc passes).

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(desktop): KanbanColumn type + API wrappers accept description"
```

### Task 2.2: Update Pinia store actions to forward description

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 1: Update `addKanbanColumn` action (line 724-736)**

Change:

```ts
async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
): Promise<void> {
  const col = await api.addKanbanColumn(workspaceId, itemId, name)
  const item = findItem(workspaceId, itemId)
  if (item) {
    item.kanban_columns = [...(item.kanban_columns ?? []), col].sort(
      (a, b) => a.position - b.position,
    )
  }
}
```

to:

```ts
async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  description: string = '',
): Promise<void> {
  const col = await api.addKanbanColumn(workspaceId, itemId, name, description)
  const item = findItem(workspaceId, itemId)
  if (item) {
    item.kanban_columns = [...(item.kanban_columns ?? []), col].sort(
      (a, b) => a.position - b.position,
    )
  }
}
```

Note: the `description: string = ''` default keeps the existing call sites in `AppLayout.vue` (which only pass `name`) working unchanged.

- [ ] **Step 2: Update `updateKanbanColumn` action (line 742-754)**

Change:

```ts
async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; position?: number },
): Promise<void> {
  const col = await api.updateKanbanColumn(workspaceId, itemId, columnId, patch)
  const item = findItem(workspaceId, itemId)
  if (item && item.kanban_columns) {
    const i = item.kanban_columns.findIndex((c) => c.id === columnId)
    if (i !== -1) item.kanban_columns[i] = col
  }
}
```

to:

```ts
async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; description?: string; position?: number },
): Promise<void> {
  const col = await api.updateKanbanColumn(workspaceId, itemId, columnId, patch)
  const item = findItem(workspaceId, itemId)
  if (item && item.kanban_columns) {
    const i = item.kanban_columns.findIndex((c) => c.id === columnId)
    if (i !== -1) item.kanban_columns[i] = col
  }
}
```

- [ ] **Step 3: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(desktop): workspaces store forwards column description"
```

### Task 2.3: Add description textarea to `KanbanColumnEditor.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanColumnEditor.vue`
- Modify: `src/apps/desktop/src/__tests__/KanbanColumnEditor.spec.ts`

- [ ] **Step 1: Extend the component props + emits**

Change the props:

```ts
const props = defineProps<{
  show: boolean
  mode: Mode
  initialName?: string
}>()

const emit = defineEmits<{
  close: []
  add: [name: string]
  rename: [name: string]
  delete: []
}>()
```

to:

```ts
const props = defineProps<{
  show: boolean
  mode: Mode
  initialName?: string
  /** Pre-fill the description field. Only used in 'add' (rarely)
   * and 'rename' modes. Empty string when absent. */
  initialDescription?: string
}>()

const emit = defineEmits<{
  close: []
  add: [name: string, description: string]
  rename: [name: string, description: string]
  delete: []
}>()
```

- [ ] **Step 2: Add a `description` ref + seed it**

After the `name` ref (line 40-41), add:

```ts
const description = ref('')
const descriptionInput = ref<HTMLTextAreaElement | null>(null)

// 500-char cap matches the project's convention for short text
// fields. The textarea enforces it via `maxlength`; the backend
// does NOT re-validate the cap (Zig error sets grow with every
// constraint; we accept "client says 500, server trusts it" for v1).
const DESCRIPTION_MAX = 500
```

- [ ] **Step 3: Update the watch to seed description on open**

Change the existing `watch(() => props.show, ...)` block (line 124-138) to also seed `description`:

```ts
name.value = props.initialName ?? ''
watch(
  () => props.show,
  async (show) => {
    if (show) {
      name.value = props.initialName ?? ''
      description.value = props.initialDescription ?? ''
      await nextTick()
      // Focus the name input when it exists; in delete mode there is
      // no input to focus, but focusing the dialog itself is harmless.
      if (showNameInput.value) {
        nameInput.value?.focus()
        nameInput.value?.select()
      }
    }
  },
)
```

- [ ] **Step 4: Update the submit handler to emit description**

Change:

```ts
const handleSubmit = () => {
  if (props.mode === 'delete') {
    emit('delete')
    handleClose()
    return
  }
  const trimmed = name.value.trim()
  if (!trimmed) return
  if (props.mode === 'add') {
    emit('add', trimmed)
  } else if (props.mode === 'rename') {
    // For rename, we still emit even if the name equals the initial
    // — the parent can choose to no-op. We deliberately do NOT skip
    // the emit because the user explicitly clicked Save.
    emit('rename', trimmed)
  }
  handleClose()
}
```

to:

```ts
const handleSubmit = () => {
  if (props.mode === 'delete') {
    emit('delete')
    handleClose()
    return
  }
  const trimmed = name.value.trim()
  if (!trimmed) return
  // Description is optional; trim but allow empty (the backend's
  // "no description" sentinel is the empty string).
  const trimmedDescription = description.value.trim()
  if (props.mode === 'add') {
    emit('add', trimmed, trimmedDescription)
  } else if (props.mode === 'rename') {
    // For rename, we still emit even if the name equals the initial
    // — the parent can choose to no-op. We deliberately do NOT skip
    // the emit because the user explicitly clicked Save.
    emit('rename', trimmed, trimmedDescription)
  }
  handleClose()
}
```

- [ ] **Step 5: Add the description textarea to the template**

Inside the `<div v-if="showNameInput" class="px-5 pb-4">` block (line 196-217), after the existing `<input ref="nameInput" ...>`, add:

```vue
<label
  class="block text-xs font-medium mb-2 mt-3"
  style="color: var(--semantic-text-dim);"
>
  Description
  <span
    class="ml-1 text-[10px]"
    style="color: var(--semantic-text-dim);"
  >(optional — what this column means)</span>
</label>
<textarea
  ref="descriptionInput"
  v-model="description"
  :maxlength="DESCRIPTION_MAX"
  rows="3"
  :placeholder="mode === 'add' ? 'e.g. Awaiting code review — must pass CI before merge' : ''"
  :data-testid="`kanban-column-editor-${mode}-description`"
  class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200 resize-y"
  style="
    background-color: var(--semantic-sidebar-bg);
    border: 1px solid var(--color-border);
    color: var(--semantic-text);
    font-family: inherit;
  "
></textarea>
<div
  class="text-[10px] mt-1 text-right"
  style="color: var(--semantic-text-dim);"
  :data-testid="`kanban-column-editor-${mode}-description-counter`"
>
  {{ description.length }} / {{ DESCRIPTION_MAX }}
</div>
```

- [ ] **Step 6: Update the test file**

Add these tests to `src/apps/desktop/src/__tests__/KanbanColumnEditor.spec.ts`:

```ts
describe('KanbanColumnEditor description field', () => {
  it('shows a description textarea in add mode', () => {
    const wrapper = mount(KanbanColumnEditor, {
      props: { show: true, mode: 'add' },
      attachTo: document.body,
    })
    const desc = wrapper.find('[data-testid="kanban-column-editor-add-description"]')
    expect(desc.exists()).toBe(true)
    expect((desc.element as HTMLTextAreaElement).tagName).toBe('TEXTAREA')
    wrapper.unmount()
  })

  it('emits add with the description when Add is clicked', async () => {
    const wrapper = mount(KanbanColumnEditor, {
      props: { show: true, mode: 'add' },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="kanban-column-editor-add-name"]').setValue('Review')
    await wrapper
      .find('[data-testid="kanban-column-editor-add-description"]')
      .setValue('Awaiting code review — must pass CI')
    await wrapper.find('[data-testid="kanban-column-editor-add-submit"]').trigger('click')
    const emitted = wrapper.emitted('add')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Review', 'Awaiting code review — must pass CI'])
    wrapper.unmount()
  })

  it('emits rename with the description when Save is clicked', async () => {
    const wrapper = mount(KanbanColumnEditor, {
      props: {
        show: true,
        mode: 'rename',
        initialName: 'todo',
        initialDescription: 'Not started',
      },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="kanban-column-editor-rename-name"]').setValue('backlog')
    await wrapper
      .find('[data-testid="kanban-column-editor-rename-description"]')
      .setValue('Newly triaged items')
    await wrapper.find('[data-testid="kanban-column-editor-rename-submit"]').trigger('click')
    const emitted = wrapper.emitted('rename')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['backlog', 'Newly triaged items'])
    wrapper.unmount()
  })

  it('seeds description from initialDescription prop on open', async () => {
    const wrapper = mount(KanbanColumnEditor, {
      props: {
        show: false,
        mode: 'rename',
        initialDescription: 'Pre-existing meaning',
      },
      attachTo: document.body,
    })
    await wrapper.setProps({ show: true })
    await nextTick()
    const descInput = wrapper.find(
      '[data-testid="kanban-column-editor-rename-description"]',
    ).element as HTMLTextAreaElement
    expect(descInput.value).toBe('Pre-existing meaning')
    wrapper.unmount()
  })
})
```

Note: existing tests that assert `wrapper.emitted('add')[0]` equals `['Todo']` (a single-string array) need to be updated to `['Todo', '']`.

- [ ] **Step 7: Run tests + type-check**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run KanbanColumnEditor 2>&1 | tail -n 20`
Expected: 4 new tests pass; existing tests pass (after the single-string → pair update).

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 8: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanColumnEditor.vue \
        src/apps/desktop/src/__tests__/KanbanColumnEditor.spec.ts
git commit -m "feat(desktop): KanbanColumnEditor add/rename modes carry description"
```

### Task 2.4: Display description in `KanbanColumn.vue` header

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanColumn.vue`
- Create: `src/apps/desktop/src/__tests__/KanbanColumnDescription.spec.ts`

- [ ] **Step 1: Find the header template**

Read `src/apps/desktop/src/components/KanbanColumn.vue` around the header section (after line 120). Look for the `<header>` block that renders the column name + count badge + menu button.

- [ ] **Step 2: Add the description subtitle**

After the existing name-rendering block (the `<h3>` or `<div>` that contains `{{ column.name }}`), add:

```vue
<p
  v-if="column.description"
  class="text-[11px] mt-0.5 truncate"
  style="color: var(--semantic-text-dim);"
  :title="column.description"
  :data-testid="`kanban-column-${column.id}-description`"
>
  {{ column.description }}
</p>
```

`truncate` (Tailwind) renders one line with ellipsis; the `title` attribute surfaces the full text on hover. The `v-if="column.description"` guard prevents the empty-line artifact when no description is set (the description is `""` or `null` or `undefined` — all three falsy in v-if).

- [ ] **Step 3: Add the unit test**

Create `src/apps/desktop/src/__tests__/KanbanColumnDescription.spec.ts`:

```ts
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import KanbanColumn from '@/components/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnT, Task } from '@/api'

const baseColumn: KanbanColumnT = {
  id: 'col_test',
  workspace_item_id: 'wi_test',
  name: 'in_review',
  description: 'Awaiting code review',
  position: 0,
  created_at: '2026-06-26T10:00:00Z',
}

const baseTask: Task = {
  id: 'task_test',
  name: 'test task',
  kanban_column_id: null,
  kanban_position: 0,
}

describe('KanbanColumn description display', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders the description under the column name when present', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: baseColumn,
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(true)
    expect(desc.text()).toBe('Awaiting code review')
    expect((desc.element as HTMLParagraphElement).title).toBe('Awaiting code review')
    wrapper.unmount()
  })

  it('does not render the description element when description is empty', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: { ...baseColumn, description: '' },
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does not render the description element when description is null', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: { ...baseColumn, description: null },
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does not render the description element when description is undefined', () => {
    const columnWithoutDescription: KanbanColumnT = { ...baseColumn }
    delete columnWithoutDescription.description
    const wrapper = mount(KanbanColumn, {
      props: {
        column: columnWithoutDescription,
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })
})
```

- [ ] **Step 4: Run tests + type-check**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run KanbanColumnDescription 2>&1 | tail -n 20`
Expected: 4 new tests pass.

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanColumn.vue \
        src/apps/desktop/src/__tests__/KanbanColumnDescription.spec.ts
git commit -m "feat(desktop): KanbanColumn header shows description subtitle"
```

### Task 2.5: Wire `AppLayout.vue` handlers to forward description to/from the editor

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue`

- [ ] **Step 1: Track `initialDescription` for the editor**

After `kanbanColumnEditorInitialName` (line 620), add:

```ts
const kanbanColumnEditorInitialDescription = ref<string>('')
```

- [ ] **Step 2: Set it when opening in rename mode**

In `handleKanbanRequestRenameColumn` (line 639-646), change:

```ts
const handleKanbanRequestRenameColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'rename'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  showKanbanColumnEditor.value = true
}
```

to:

```ts
const handleKanbanRequestRenameColumn = (columnId: string) => {
  const col = findKanbanColumn(columnId)
  if (!col) return
  kanbanColumnEditorMode.value = 'rename'
  kanbanColumnEditorTargetId.value = columnId
  kanbanColumnEditorInitialName.value = col.name
  kanbanColumnEditorInitialDescription.value = col.description ?? ''
  showKanbanColumnEditor.value = true
}
```

- [ ] **Step 3: Update the add + rename handlers to forward description**

Change:

```ts
const handleKanbanColumnEditorAdd = (name: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(ws.id, activeWorkspaceItem.value.id, name)
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorRename = (name: string) => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
    { name },
  )
  showKanbanColumnEditor.value = false
}
```

to:

```ts
const handleKanbanColumnEditorAdd = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    name,
    description,
  )
  showKanbanColumnEditor.value = false
}

const handleKanbanColumnEditorRename = (name: string, description: string) => {
  if (!activeWorkspaceItem.value || !kanbanColumnEditorTargetId.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    kanbanColumnEditorTargetId.value,
    { name, description },
  )
  showKanbanColumnEditor.value = false
}
```

- [ ] **Step 4: Bind the new prop in the editor template**

Change:

```vue
<KanbanColumnEditor
  :show="showKanbanColumnEditor"
  :mode="kanbanColumnEditorMode"
  :initial-name="kanbanColumnEditorInitialName"
  @close="handleKanbanColumnEditorClose"
  @add="handleKanbanColumnEditorAdd"
  @rename="handleKanbanColumnEditorRename"
  @delete="handleKanbanColumnEditorDelete"
/>
```

to:

```vue
<KanbanColumnEditor
  :show="showKanbanColumnEditor"
  :mode="kanbanColumnEditorMode"
  :initial-name="kanbanColumnEditorInitialName"
  :initial-description="kanbanColumnEditorInitialDescription"
  @close="handleKanbanColumnEditorClose"
  @add="handleKanbanColumnEditorAdd"
  @rename="handleKanbanColumnEditorRename"
  @delete="handleKanbanColumnEditorDelete"
/>
```

- [ ] **Step 5: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 6: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(desktop): forward description through KanbanColumnEditor to store"
```

---## Chunk 3: New `KanbanSettingsDialog.vue` + ⚙ button in `KanbanView.vue`

> Adds the per-board settings surface. The ⚙ button on the kanban header opens a dialog listing every column (name + description) with per-row edit/delete actions, and exposes an "Add Column" form.

### Task 3.1: Create `KanbanSettingsDialog.vue`

**Files:**
- Create: `src/apps/desktop/src/components/KanbanSettingsDialog.vue`
- Create: `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts`

- [ ] **Step 1: Create the component file**

Create `src/apps/desktop/src/components/KanbanSettingsDialog.vue`:

```vue
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
import type { WorkspaceItem } from '../stores/workspaces'

const props = defineProps<{
  show: boolean
  item: WorkspaceItem | null
}>()

const emit = defineEmits<{
  close: []
  addColumn: [name: string, description: string]
  editColumn: [
    payload: { columnId: string; name: string; description: string },
  ]
  deleteColumn: [columnId: string]
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

const handleClose = () => {
  emit('close')
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
                <span
                  v-if="item"
                  class="text-sm font-normal ml-1"
                  style="color: var(--semantic-text-muted);"
                >— {{ item.name }}</span>
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
```

- [ ] **Step 2: Write tests for the dialog**

Create `src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts`:

```ts
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import KanbanSettingsDialog from '@/components/KanbanSettingsDialog.vue'
import type { WorkspaceItem } from '@/stores/workspaces'

const baseItem: WorkspaceItem = {
  id: 'wi_test',
  name: 'Sprint 12',
  item_type: 'kanban',
  path: null,
  kanban_columns: [
    {
      id: 'col_a',
      workspace_item_id: 'wi_test',
      name: 'todo',
      description: 'Not started',
      position: 0,
      created_at: '2026-06-26T10:00:00Z',
    },
    {
      id: 'col_b',
      workspace_item_id: 'wi_test',
      name: 'done',
      description: '',
      position: 1,
      created_at: '2026-06-26T10:00:00Z',
    },
  ],
}

describe('KanbanSettingsDialog', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders the kanban name in the header', () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    expect(wrapper.text()).toContain('Sprint 12')
    wrapper.unmount()
  })

  it('renders one row per column sorted by position', () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    const rows = wrapper.findAll('[data-testid^="kanban-settings-column-row-"]')
    expect(rows).toHaveLength(2)
    expect((rows[0].find('[data-testid="kanban-settings-column-name-col_a"]').element as HTMLElement).textContent).toContain('todo')
    expect((rows[1].find('[data-testid="kanban-settings-column-name-col_b"]').element as HTMLElement).textContent).toContain('done')
    wrapper.unmount()
  })

  it('shows "No description" for columns with empty description', () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    const descEl = wrapper.find('[data-testid="kanban-settings-column-description-col_b"]')
    expect(descEl.text()).toBe('No description')
    wrapper.unmount()
  })

  it('emits addColumn with name + description when Add is clicked', async () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="kanban-settings-add-name"]').setValue('Review')
    await wrapper.find('[data-testid="kanban-settings-add-description"]').setValue('Awaiting code review')
    await wrapper.find('[data-testid="kanban-settings-add-submit"]').trigger('click')
    const emitted = wrapper.emitted('addColumn')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['Review', 'Awaiting code review'])
    wrapper.unmount()
  })

  it('emits close when the close button is clicked', async () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="kanban-settings-close"]').trigger('click')
    expect(wrapper.emitted('close')).toBeTruthy()
    wrapper.unmount()
  })

  it('emits deleteColumn when Delete is clicked on a row', async () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="kanban-settings-delete-col_a"]').trigger('click')
    // After click, the KanbanColumnEditor (delete mode) opens; we
    // confirm by clicking the editor's submit button.
    await flushPromises()
    await wrapper.find('[data-testid="kanban-column-editor-delete-submit"]').trigger('click')
    const emitted = wrapper.emitted('deleteColumn')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual(['col_a'])
    wrapper.unmount()
  })

  it('emits editColumn when Edit is clicked and Save is confirmed', async () => {
    const wrapper = mount(KanbanSettingsDialog, {
      props: { show: true, item: baseItem },
      attachTo: document.body,
    })
    await wrapper.find('[data-testid="kanban-settings-edit-col_a"]').trigger('click')
    await flushPromises()
    await wrapper.find('[data-testid="kanban-column-editor-rename-name"]').setValue('backlog')
    await wrapper.find('[data-testid="kanban-column-editor-rename-description"]').setValue('Newly triaged')
    await wrapper.find('[data-testid="kanban-column-editor-rename-submit"]').trigger('click')
    const emitted = wrapper.emitted('editColumn')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      { columnId: 'col_a', name: 'backlog', description: 'Newly triaged' },
    ])
    wrapper.unmount()
  })
})
```

- [ ] **Step 3: Run tests + type-check**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run KanbanSettingsDialog 2>&1 | tail -n 20`
Expected: 7 new tests pass.

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanSettingsDialog.vue \
        src/apps/desktop/src/__tests__/KanbanSettingsDialog.spec.ts
git commit -m "feat(desktop): new KanbanSettingsDialog with column list + add form"
```

### Task 3.2: Add the ⚙ Settings button to `KanbanView.vue` header

**Files:**
- Modify: `src/apps/desktop/src/components/KanbanView.vue`

- [ ] **Step 1: Add `open-settings` to emits**

Change the `defineEmits` block (line 94-115). Add a new event:

```ts
const emit = defineEmits<{
  addColumn: []
  addTask: [{ columnId: string }]
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  openSettings: []
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  editRoutine: [workspaceId: string, itemId: string, taskId: string]
  runRoutine: [workspaceId: string, itemId: string, taskId: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
}>()
```

- [ ] **Step 2: Add a handler for the button**

After `handleAddColumn` (line 134-136), add:

```ts
const handleOpenSettings = () => {
  emit('openSettings')
}
```

- [ ] **Step 3: Add the button to the header**

Find the existing `+ Column` button (line 231-243) in the template. BEFORE that button (so ⚙ Settings is to the LEFT of + Column), add a sibling button:

```vue
<button
  type="button"
  class="px-2 py-1 rounded text-xs font-medium hover:opacity-80 transition-opacity"
  style="
    background-color: var(--semantic-sidebar-bg);
    border: 1px solid var(--color-border);
    color: var(--semantic-text-muted);
  "
  :data-testid="`kanban-view-${item.id}-open-settings`"
  @click="handleOpenSettings"
  title="Open board settings (add columns, edit descriptions)"
>
  <span aria-hidden="true">⚙️</span>
  <span class="ml-1">Settings</span>
</button>
```

- [ ] **Step 4: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build (the new emit is forwarded upward but not yet consumed — that's Task 3.3).

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/KanbanView.vue
git commit -m "feat(desktop): KanbanView header gains Settings button"
```

### Task 3.3: Mount `KanbanSettingsDialog` in `AppLayout.vue` and wire its events

**Files:**
- Modify: `src/apps/desktop/src/components/AppLayout.vue`

- [ ] **Step 1: Add import + state**

At the top of `<script setup>` (next to the existing `KanbanColumnEditor` import at line 14), add:

```ts
import KanbanSettingsDialog from './KanbanSettingsDialog.vue'
```

Near the existing `showKanbanColumnEditor` ref block (line 611-620), add:

```ts
// KanbanSettingsDialog — per-board column management.
const showKanbanSettingsDialog = ref(false)

const handleOpenKanbanSettings = () => {
  showKanbanSettingsDialog.value = true
}

const handleCloseKanbanSettings = () => {
  showKanbanSettingsDialog.value = false
}

const handleKanbanSettingsAddColumn = (name: string, description: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.addKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    name,
    description,
  )
  // Dialog stays open so the user can add more columns in succession.
}

const handleKanbanSettingsEditColumn = (payload: {
  columnId: string
  name: string
  description: string
}) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.updateKanbanColumn(
    ws.id,
    activeWorkspaceItem.value.id,
    payload.columnId,
    { name: payload.name, description: payload.description },
  )
}

const handleKanbanSettingsDeleteColumn = (columnId: string) => {
  if (!activeWorkspaceItem.value) return
  const ws = activeWorkspace.value
  if (!ws) return
  void workspacesStore.deleteKanbanColumn(ws.id, activeWorkspaceItem.value.id, columnId)
}
```

- [ ] **Step 2: Forward `openSettings` from `<KanbanView>` to the dialog**

Find the existing `<KanbanView>` element in the template (around line 1132 or 1215; there are two — the recent one with `v-if="activeWorkspaceItem"`). Add `@open-settings="handleOpenKanbanSettings"`:

```vue
<KanbanView
  ...existing props...
  ...existing emits...
  @open-settings="handleOpenKanbanSettings"
/>
```

- [ ] **Step 3: Mount the dialog in the template**

After the existing `<KanbanColumnEditor>` element (around line 1356-1364), add:

```vue
<KanbanSettingsDialog
  :show="showKanbanSettingsDialog"
  :item="activeWorkspaceItem"
  @close="handleCloseKanbanSettings"
  @add-column="handleKanbanSettingsAddColumn"
  @edit-column="handleKanbanSettingsEditColumn"
  @delete-column="handleKanbanSettingsDeleteColumn"
/>
```

- [ ] **Step 4: Verify the type-check passes**

Run: `cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
git add src/apps/desktop/src/components/AppLayout.vue
git commit -m "feat(desktop): AppLayout mounts KanbanSettingsDialog + wires openSettings"
```

---## Chunk 4: End-to-end smoke test + regression checks

> Final chunk: verify all pieces work together (backend + frontend). Mirrors the regression-test pattern from the workspace-item-kanban plan.

### Task 4.1: Run the full Zig test suite + install:linux build

- [ ] **Step 1: Run the full test suite**

Run: `timeout 240 zig build test --summary all 2>&1 | tail -n 10`
Expected: all tests pass. Test count grows by 7 (2 migration + 1 model description + 2 handler tests + 2 backend handler integration if applicable).

- [ ] **Step 2: Run the install:linux build to verify the binary compiles**

Run: `timeout 240 zig build install:linux:system 2>&1 | tail -n 15`
Expected: 4/6 steps succeed (the cp to /usr/local/bin/nalar fails harmlessly with "Permission denied"). The crucial step "compile exe nalar" must succeed with no errors.

- [ ] **Step 3: Manually smoke-test the column-description end-to-end on port 8080**

> Use port 8080 (NOT 8081) — port 8081 has another `nalar` process running for the dev workflow.

The smoke test below uses a temp file to capture the background PID (instead of `$!` directly) so the command can be pasted into any shell.

```bash
# 1. Start nalar on 8080 in the background.
./zig-out/bin/nalar --port 8080 &
echo $! > /tmp/nalar-smoke.pid
sleep 2

# 2. Substitute these for your workspace + kanban item.
WS_ID="ws_<your-workspace-id>"
ITEM_ID="item_<your-kanban-item-id>"

# 3. Add a column WITH a description.
curl -sS -X POST "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}/kanban/columns" \
  -H "Content-Type: application/json" \
  -d '{"name":"in_review","description":"Awaiting code review — must pass CI"}' \
  | jq .

# 4. Verify the description round-trips.
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}/kanban/columns" \
  | jq '.columns[] | {id, name, description}'

# 5. PATCH the column to update ONLY the description.
COL_ID="<id-from-step-3>"
curl -sS -X PATCH "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}/kanban/columns/${COL_ID}" \
  -H "Content-Type: application/json" \
  -d '{"description":"Awaiting code review — must pass CI AND have 2 approvals"}' \
  | jq .

# 6. Verify the description updated but the name stayed the same.
curl -sS "http://127.0.0.1:8080/api/workspaces/${WS_ID}/items/${ITEM_ID}/kanban/columns" \
  | jq ".columns[] | select(.id == \"${COL_ID}\") | {name, description}"

# 7. Stop nalar.
kill "$(cat /tmp/nalar-smoke.pid)"
rm /tmp/nalar-smoke.pid
```

Expected: every command returns valid JSON; step 4 shows `description: "Awaiting code review — must pass CI"`; step 6 shows the description updated and the name unchanged.

- [ ] **Step 4: Commit (no code changes — verification only)**

If the smoke test passed, no commit is needed. If it failed, document the failure in NALAR.md and create a fix-up plan.

### Task 4.2: Run the full frontend type-check + test suite

- [ ] **Step 1: Run `bun run build` (vue-tsc + bundle)**

Run: `cd src/apps/desktop && timeout 180 bun run build 2>&1 | tail -n 15`
Expected: clean build. 0 TypeScript errors.

- [ ] **Step 2: Run the full Vitest suite**

Run: `cd src/apps/desktop && timeout 180 bunx vitest run 2>&1 | tail -n 15`
Expected: all tests pass. Test count grows by 15 (4 from Task 2.3 + 4 from Task 2.4 + 7 from Task 3.1).

- [ ] **Step 3: Manually smoke-test the KanbanSettingsDialog in the dev server**

```bash
# 1. Start nalar on 8080 in the background.
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
echo $! > /tmp/nalar-dev.pid
sleep 2

# 2. Start the Vite dev server.
cd src/apps/desktop
bun run dev &
echo $! > /tmp/vite-dev.pid
sleep 5

# 3. Open the dev server in nalar_browser. Manual: navigate to the
#    kanban view, click ⚙ Settings, add a column with description,
#    verify it persists via the GET endpoint.

# 4. Stop both processes.
kill "$(cat /tmp/nalar-dev.pid)"
kill "$(cat /tmp/vite-dev.pid)"
rm /tmp/nalar-dev.pid /tmp/vite-dev.pid
```

Expected: the ⚙ Settings button is visible in the kanban header; clicking it opens the modal; the Add form has name + description fields; submitting persists to the backend (verify with the curl smoke test from Task 4.1 step 3).

- [ ] **Step 4: Final commit (any smoke-test fixes)**

If you discovered any frontend-only bugs during the smoke test, commit them on a fix-up commit. Otherwise no commit.

---

## Verification

After all chunks land:

```bash
# Backend
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
timeout 240 zig build test --summary all 2>&1 | tail -n 5
# Expected: "test success"; test count grows by 7+.

timeout 240 zig build install:linux:system 2>&1 | tail -n 15
# Expected: 4/6 steps succeed; the binary at zig-out/bin/nalar is rebuilt.

# Frontend
cd src/apps/desktop
timeout 180 bun run build 2>&1 | tail -n 5
# Expected: clean build; 0 TypeScript errors.

timeout 180 bunx vitest run 2>&1 | tail -n 5
# Expected: all tests pass; test count grows by 15+.
```

End-to-end manual smoke test (per Task 4.1 step 3) confirms the description round-trips through POST → DB → GET → PATCH → DB → GET. The frontend smoke test (per Task 4.2 step 3) confirms the ⚙ Settings button opens the dialog and the Add form persists to the backend.

---

## Plan Review Loop

After completing each chunk:

1. Dispatch a sub-agent for plan-document-review with the chunk content
2. If ❌ Issues Found: fix them in this plan, re-dispatch reviewer
3. Repeat until ✅ Approved
4. Proceed to next chunk

**Chunk boundaries:** Chunks 1-4 are ≤1000 lines each and logically self-contained. Chunk 1 is pure backend; Chunk 2 is frontend API + types + components; Chunk 3 is the new dialog; Chunk 4 is end-to-end verification.

---

## Execution Handoff

After all chunks are approved:

**"Plan complete and saved to `docs/superpowers/plans/2026-06-27-kanban-column-description-settings.md`. Ready to execute?"**

**Execution path:** This codebase uses `superpowers:subagent-driven-development` (per the project memory `nalar-core`). Use the existing sub-agent infrastructure to spawn one sub-agent per task with two-stage review. Each sub-agent gets the specific task content + the project memory files + the relevant pre-loaded skills (`zig-expert`, `desktop-frontend-build`).
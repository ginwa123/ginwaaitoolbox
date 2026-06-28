# Pinned Workspace Item Tasks Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users pin a `workspace_item_tasks` row so it stays at the top of the per-item task list, and let users reorder the pinned subset via drag-and-drop.

**Architecture:** This plan follows the `workspaces_reorder` and `workspace_items_reorder` patterns end-to-end, scoped to a single workspace item's tasks. Pinned tasks are surfaced first (in user-defined order), then unpinned tasks follow in the existing sort order (`updated_at DESC, id DESC` by default). The feature reuses the `position` formula (`count - 1 - i`) for the pinned subset, so pinned rows have `pinned_position` values that drive a separate `ORDER BY pinned_position DESC, id DESC` for pinned rows and a fallback to the existing sort for unpinned rows.

**Tech Stack:** Zig 0.16 (backend, handler use cases in `workspace_items_reorder.zig` style), Vue 3 + TypeScript + Pinia (frontend), SQLite (storage). Tests follow the project's static-check pattern (no in-process DB) for the backend and `vitest` for the frontend.

---

## File Structure

Files to create:
- `src/ai_workflow/tui/http_handlers/task_pin.zig` — HTTP handler `POST /api/.../tasks/:task_id/pin`
- `src/ai_workflow/tui/http_handlers/tasks_reorder_pinned.zig` — HTTP handler `POST /api/.../tasks/reorder_pinned`
- `src/ai_workflow/tui/http_handlers/task_pin_test.zig` — static-check tests for the pin handler
- `src/ai_workflow/tui/http_handlers/tasks_reorder_pinned_test.zig` — static-check tests for the pinned-reorder handler
- `src/apps/desktop/src/__tests__/workspacesStorePinTask.spec.ts` — store-level test for `pinTask`
- `src/apps/desktop/src/__tests__/workspacesStoreReorderPinnedTasks.spec.ts` — store-level test for `reorderPinnedTasks`
- `src/apps/desktop/src/__tests__/workspaceItemTaskPin.spec.ts` — component-level test for the pin button in `WorkspaceItemTask.vue`

Files to modify:
- `src/ai_workflow/tui/migration.zig` — add `Migration050AddPinnedToWorkspaceItemTasks` and register it
- `src/ai_workflow/tui/llm_history.zig` — extend `WorkspaceItemTaskInfo` with `is_pinned` + `pinned_position`; update list SELECTs and ORDER BY; add `setTaskPinned` and `reorderPinnedTasks` use cases
- `src/ai_workflow/tui/http_handlers/http_response.zig` — add `TaskPinResponse`, `TasksReorderPinnedResponse` + `makeTaskPinResponse` and `makeTasksReorderPinnedResponse` helpers
- `src/ai_workflow/tui/http_handlers/mod.zig` — re-export `taskPinHandler` and `tasksReorderPinnedHandler`
- `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` — add a static test that the list SELECT includes `is_pinned` + `pinned_position` and orders pinned rows first
- `src/ai_workflow/tui/test_runner.zig` — register `task_pin_test.zig` and `tasks_reorder_pinned_test.zig`
- `src/main.zig` — register the two new routes
- `src/apps/desktop/src/api/index.ts` — extend `Task` interface with `is_pinned` + `pinned_position`; add `pinTask()` and `reorderPinnedTasks()` API functions
- `src/apps/desktop/src/stores/workspaces.ts` — add `pinTask()` and `reorderPinnedTasks()` actions (optimistic + rollback)
- `src/apps/desktop/src/components/WorkspaceItemTask.vue` — add a pin/unpin toggle button + a persistent 📌 indicator when `is_pinned`; emit `pinTask` event
- `src/apps/desktop/src/components/WorkspaceItem.vue` — split the task list into a pinned region and an unpinned region; emit `pinTask` and `reorderPinnedTasks` events up to `WorkspaceList`
- `src/apps/desktop/src/components/WorkspaceList.vue` — re-emit `pinTask` and `reorderPinnedTasks` to Sidebar
- `src/apps/desktop/src/components/Sidebar.vue` — handle `pinTask` and `reorderPinnedTasks` events

---

## Chunk 1: Backend — migration, model fields, response types

### Task 1.1: Add `Migration050AddPinnedToWorkspaceItemTasks`

**Files:**
- Modify: `src/ai_workflow/tui/migration.zig` (insert new struct after `Migration049AddDefensiveIndexes`, register in `allMigrations`)

- [ ] **Step 1: Write the failing static test for the new migration**

Open `src/ai_workflow/tui/http_handlers/workspace_items_reorder_test.zig` and add a new test at the bottom (the file already contains the `Migration045...` test, so follow the same static-substring pattern):

```zig
test "migration 050 adds workspace_item_tasks.is_pinned and pinned_position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    const has_version = std.mem.indexOf(u8, source, "Migration050AddPinnedToWorkspaceItemTasks") != null;
    const has_is_pinned = std.mem.indexOf(u8, source, "is_pinned") != null;
    const has_pinned_position = std.mem.indexOf(u8, source, "pinned_position") != null;
    if (!has_version or !has_is_pinned or !has_pinned_position) {
        std.debug.print(
            "\n!! {s} is missing Migration 050 or its columns !!\n" ++
                "   Fresh databases will not have an is_pinned column,\n" ++
                "   and the pin handler will fail at ALTER TABLE.\n" ++
                "   Add Migration050AddPinnedToWorkspaceItemTasks with\n" ++
                "   ALTER TABLE workspace_item_tasks ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0\n" ++
                "   and pinned_position INTEGER NOT NULL DEFAULT 0.\n",
            .{MIGRATION_PATH},
        );
        return error.Migration050Missing;
    }
}
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `error.Migration050Missing` from the new test.

- [ ] **Step 3: Add the migration struct after `Migration049AddDefensiveIndexes`**

In `src/ai_workflow/tui/migration.zig` (around line 856, right after the closing brace of `Migration049AddDefensiveIndexes`), insert:

```zig
pub const Migration050AddPinnedToWorkspaceItemTasks = struct {
    pub const version: u32 = 50;
    pub const name = "add_pinned_to_workspace_item_tasks";

    pub fn up(db: *SqliteBackend, allocator: std.mem.Allocator) anyerror!void {
        // Two new columns:
        //   is_pinned:        0/1 flag, default 0 (unpinned). Nullable
        //                     would also work, but NOT NULL DEFAULT 0 is
        //                     consistent with the convention used by
        //                     `git_worktree_cwd` etc. and makes the
        //                     "is this row pinned?" branch in the
        //                     listers a simple `t.is_pinned = 1` check
        //                     (no COALESCE noise).
        //   pinned_position:  integer, default 0. Used to order pinned
        //                     rows within a single workspace_item.
        //                     Mirrors `workspace_items.position`
        //                     (Migration045) and `workspaces.position`
        //                     (Migration043): higher = higher in the
        //                     list.
        //
        // No backfill is needed: every existing row is unpinned by
        // default (is_pinned=0) and any pinned_position is irrelevant
        // for unpinned rows.
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{});
        try db.exec(allocator,
            "ALTER TABLE workspace_item_tasks ADD COLUMN pinned_position INTEGER NOT NULL DEFAULT 0",
            &[_][]const u8{});

        // Index on (workspace_item_id, is_pinned DESC, pinned_position DESC)
        // so the lister can use a single index range scan for the
        // pinned-first branch.
        try db.exec(allocator,
            "CREATE INDEX IF NOT EXISTS idx_workspace_item_tasks_pinned " ++
            "ON workspace_item_tasks(workspace_item_id, is_pinned DESC, pinned_position DESC)",
            &[_][]const u8{});

        try db.exec(allocator, "ANALYZE", &[_][]const u8{});
    }
};
```

- [ ] **Step 4: Register the migration in `allMigrations`**

In the same file, inside the `pub const allMigrations` slice, add a new entry between the existing `Migration049` line and the closing `};`:

```zig
    .{ .version = Migration050AddPinnedToWorkspaceItemTasks.version, .name = Migration050AddPinnedToWorkspaceItemTasks.name, .up = Migration050AddPinnedToWorkspaceItemTasks.up },
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`. The static test now finds the migration and columns.

- [ ] **Step 6: Commit**

```bash
git add src/ai_workflow/tui/migration.zig \
        src/ai_workflow/tui/http_handlers/workspace_items_reorder_test.zig
git commit -m "feat(tasks): Migration050 adds is_pinned and pinned_position columns"
```

### Task 1.2: Extend `WorkspaceItemTaskInfo` and update the list SELECTs

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (add fields to `WorkspaceItemTaskInfo`; update `listWorkspaceItemTasks` and `listWorkspaceItemTasksWithCursor` SELECTs + ORDER BY)

- [ ] **Step 1: Add `is_pinned` and `pinned_position` to `WorkspaceItemTaskInfo`**

In `src/ai_workflow/tui/llm_history.zig` around line 2635 (the `WorkspaceItemTaskInfo` struct), add two new fields just after `updated_at`:

```zig
/// Pin flag. `true` when the user has pinned this task; the lister
/// surfaces pinned tasks first (in `pinned_position` order, DESC),
/// then unpinned tasks in the existing sort order.
is_pinned: bool = false,
/// Position within the pinned subset of a single workspace item.
/// Higher = higher in the pinned region. Only meaningful when
/// `is_pinned == true`. Mirrors the `position` columns on
/// `workspaces` and `workspace_items` (Migrations043/045).
pinned_position: i64 = 0,
```

No `deinit` change is needed (both fields are value types — `bool` and `i64`).

- [ ] **Step 2: Update `listWorkspaceItemTasks` SELECT and row construction**

In the same file, find `listWorkspaceItemTasks` (around line 2777). Update its SELECT to include the new columns:

```zig
const sql =
    \\SELECT t.id, t.name, t.workspace_item_id, t.session_id, t.created_at, t.updated_at, t.task_type,
    \\       COALESCE(t.is_pinned, 0) AS is_pinned, COALESCE(t.pinned_position, 0) AS pinned_position,
    \\       r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error
    \\FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id
    \\WHERE t.workspace_item_id = ?
    \\ORDER BY t.is_pinned DESC, t.pinned_position DESC, t.updated_at DESC, t.id DESC
;
```

The column indices shift: task core is still 0-5, but `is_pinned` is now at index 6, `task_type` moves to index 7, and the routine fields start at index 8 (was 7). Update the `task_type` read:

```zig
// row.values[6] is now is_pinned; row.values[7] is task_type.
const is_pinned_int = row.values[6];
const task_type = if (row.values[7].len > 0)
    try allocator.dupe(u8, row.values[7])
else
    try allocator.dupe(u8, "standard");
const has_routine = row.values[8].len > 0;  // was 7
const routine_meta: ?RoutineMeta = if (has_routine) blk: {
    const v = row.values[13];  // was 12
    // ... same logic, but:
    .schedule = try allocator.dupe(u8, row.values[8]),    // was 7
    .initial_prompt = try allocator.dupe(u8, row.values[9]),    // was 8
    .enabled = std.mem.eql(u8, row.values[10], "1"),    // was 9
    .last_run_at = if (row.values[11].len > 0) try allocator.dupe(u8, row.values[11]) else null,    // was 10
    .next_run_at = try allocator.dupe(u8, row.values[12]),    // was 11
    .last_status = last_status,
    .last_error = if (row.values[14].len > 0) try allocator.dupe(u8, row.values[14]) else null,    // was 13
};
```

And the `WorkspaceItemTaskInfo` construction at the bottom of the loop adds the two new fields:

```zig
const task = WorkspaceItemTaskInfo{
    // ... existing fields ...
    .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
    .pinned_position = std.fmt.parseInt(i64, row.values[7 + 1 - 1], 10) catch 0,
    // NOTE: The pinned_position column index is 1 (after the leading
    // t.* / r.* columns). Read it directly:
    //   row.values[<after task_type>] holds the pinned_position TEXT.
};
```

To avoid confusion, prefer the cleaner form: read `pinned_position` from a dedicated column index by adding a 16th SELECT column, OR compute it from the existing SELECT by knowing task_type is at index 7 and pinned_position follows at index... actually since the SELECT order is `task core (0-5), is_pinned (6), task_type (7), pinned_position (8), routine fields (9-15)`, add `pinned_position` to the SELECT as a separate column:

```zig
const sql =
    \\SELECT t.id, t.name, t.workspace_item_id, t.session_id, t.created_at, t.updated_at, t.task_type,
    \\       COALESCE(t.is_pinned, 0), COALESCE(t.pinned_position, 0),
    \\       r.schedule, r.initial_prompt, r.enabled, r.last_run_at, r.next_run_at, r.last_status, r.last_error
    \\FROM workspace_item_tasks t LEFT JOIN routines r ON r.task_id = t.id
    \\WHERE t.workspace_item_id = ?
    \\ORDER BY t.is_pinned DESC, t.pinned_position DESC, t.updated_at DESC, t.id DESC
;
```

Then the column indices become:
- 0-5: task core (id, name, workspace_item_id, session_id, created_at, updated_at)
- 6: task_type
- 7: is_pinned
- 8: pinned_position
- 9-15: routine fields (schedule, initial_prompt, enabled, last_run_at, next_run_at, last_status, last_error)

So:
```zig
const is_pinned_int = row.values[7];
const pinned_position_str = row.values[8];
const has_routine = row.values[9].len > 0;
// ... routine_meta reads from row.values[9..16] ...
```

And the `WorkspaceItemTaskInfo`:
```zig
const task = WorkspaceItemTaskInfo{
    .id = try allocator.dupe(u8, row.values[0]),
    .name = try allocator.dupe(u8, row.values[1]),
    .workspace_item_id = try allocator.dupe(u8, row.values[2]),
    .session_id = if (row.values[3].len > 0) try allocator.dupe(u8, row.values[3]) else null,
    .created_at = if (row.values[4].len > 0) try allocator.dupe(u8, row.values[4]) else null,
    .updated_at = if (row.values[5].len > 0) try allocator.dupe(u8, row.values[5]) else null,
    .task_type = if (row.values[6].len > 0) try allocator.dupe(u8, row.values[6]) else try allocator.dupe(u8, "standard"),
    .is_pinned = std.mem.eql(u8, is_pinned_int, "1"),
    .pinned_position = std.fmt.parseInt(i64, pinned_position_str, 10) catch 0,
    .routine = routine_meta,
};
```

- [ ] **Step 3: Update `listWorkspaceItemTasksWithCursor` SELECT and row construction**

Find `listWorkspaceItemTasksWithCursor` (around line 2859). Apply the same changes to the SELECT (add `is_pinned`, `pinned_position` columns; update the `ORDER BY` to put pinned first; update the `sort_col` switch — the `sort_col` only applies to the unpinned branch, so wrap it in a `CASE` for the ORDER BY; see Step 4).

- [ ] **Step 4: Update the `ORDER BY` to branch on the pin flag**

The cursor-based path needs the `ORDER BY` to first sort by `is_pinned DESC, pinned_position DESC, <sort_field> <sort_dir>, t.id <sort_dir>`. The cleanest approach is to compute the ORDER BY based on whether pinned rows are involved. Since `sort_col` is the unpinned branch's column, build the order by as:

```zig
const sort_col = switch (sort_field) {
    .created_at => "t.created_at",
    .updated_at => "t.updated_at",
    .name => "t.name",
};
const sort_dir_str = switch (sort_direction) {
    .asc => "ASC",
    .desc => "DESC",
};
// Pinned rows always sort by pinned_position DESC, id DESC (independent
// of the user's sort_field — pinning is a stronger ordering signal).
// Unpinned rows use the user's sort_field. The cursor is encoded with
// the last row's `is_pinned` flag so we know which branch to apply.
const order_by = try std.fmt.allocPrint(
    allocator,
    "ORDER BY t.is_pinned DESC, t.pinned_position DESC, t.id DESC, " ++
        "CASE WHEN t.is_pinned = 1 THEN NULL ELSE {s} END {s}, " ++
        "CASE WHEN t.is_pinned = 1 THEN NULL ELSE t.id END {s}",
    .{ sort_col, sort_dir_str, sort_dir_str },
);
defer allocator.free(order_by);
```

And the cursor filter needs to apply only to unpinned rows. The simplest fix is to encode the pin state into the cursor (like the `<sort_value>|<id>` format, with a leading `0` for unpinned and `1` for pinned). The cursor format becomes `<is_pinned>|<sort_value>|<id>`.

**Important:** changing the cursor format is a breaking change for in-flight pagination. Acceptable here because the cursor is client-state only (the client discards it on reload) and the new format goes out with this feature.

- [ ] **Step 5: Update the cursor encoder/decoder in `tasks_list.zig` (chunk 2 wires the handler; chunk 2 is described later, but the static tests below fail until both backend and handler are consistent)**

The handler change is in `tasks_list.zig` (Task 3.2 of this plan). For now, just update the `listWorkspaceItemTasksWithCursor` to use the new cursor format. The static tests in `tasks_list_test.zig` (Chunk 2, Task 2.1) cover the new fields.

- [ ] **Step 6: Run the build to verify Zig compiles**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`. If you see `error: index 7 outside of bounds` or `error: ambiguous column`, fix the column indices and rerun.

- [ ] **Step 7: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(tasks): include is_pinned and pinned_position in WorkspaceItemTaskInfo"
```

### Task 1.3: Add `setTaskPinned` and `reorderPinnedTasks` use cases

**Files:**
- Modify: `src/ai_workflow/tui/llm_history.zig` (add two new public functions near `updateWorkspaceItemTask` and `deleteWorkspaceItemTask`)

- [ ] **Step 1: Add `setTaskPinned` after `updateWorkspaceItemTask`**

```zig
/// Set or clear the `is_pinned` flag for a single task. When
/// `is_pinned` is true, the row's `pinned_position` is bumped to
/// (MAX(pinned_position WHERE is_pinned=1) + 1) so a newly-pinned
/// task appears at the bottom of the pinned region (the user can
/// drag it to a different position afterwards). When `is_pinned`
/// is false, the row's `pinned_position` is reset to 0 (the
/// default; the value is irrelevant for unpinned rows).
///
/// Returns the new `pinned_position` so the caller can echo it
/// back to the client (useful for the optimistic-update rollback
/// path: the store captures the previous position before calling).
pub fn setTaskPinned(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    id: []const u8,
    is_pinned: bool,
) !i64 {
    if (is_pinned) {
        // Bump pinned_position to MAX+1 for the relevant
        // workspace_item. We can't use a literal subquery in a
        // parameterized position because MAX() returns a scalar;
        // the safest portable approach is two execs.
        var max_q = try db.query(
            allocator,
            "SELECT COALESCE(MAX(t.pinned_position), -1) FROM workspace_item_tasks t WHERE t.is_pinned = 1 AND t.workspace_item_id = (SELECT workspace_item_id FROM workspace_item_tasks WHERE id = ?)",
            &.{id},
        );
        defer max_q.deinit();
        const max_row = (try max_q.next()) orelse {
            return error.TaskNotFound;
        };
        defer max_row.deinit(allocator);
        const max_pos = std.fmt.parseInt(i64, max_row.values[0], 10) catch 0;
        const new_pos = max_pos + 1;
        const new_pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_pos});
        defer allocator.free(new_pos_str);
        try db.exec(allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 1, pinned_position = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ new_pos_str, id },
        );
        return new_pos;
    } else {
        try db.exec(allocator,
            "UPDATE workspace_item_tasks SET is_pinned = 0, pinned_position = 0, updated_at = datetime('now') WHERE id = ?",
            &.{id},
        );
        return 0;
    }
}
```

- [ ] **Step 2: Add `reorderPinnedTasks` after `setTaskPinned`**

```zig
/// Reorder the pinned subset of a single workspace item. The
/// `ordered_ids` array is the full ordered list of pinned task
/// IDs for that workspace item (top-to-bottom display order, the
/// same convention as `workspaces_reorder` and
/// `workspace_items_reorder`). Each row's `pinned_position` is
/// set to `count - 1 - i` so the first id gets the highest
/// position (sorted to the top with `ORDER BY pinned_position
/// DESC`). The list lister's `ORDER BY is_pinned DESC,
/// pinned_position DESC, id DESC` then renders them in the
/// user's chosen order.
///
/// Defense in depth: the use case scopes every UPDATE by
/// `workspace_item_id` (derived from the URL) AND `is_pinned = 1`,
/// so a stale or out-of-range id is a silent no-op (matches the
/// "unknown IDs are silently skipped" contract from the
/// workspace reorder endpoints). A row that isn't pinned (e.g. a
/// `is_pinned = 0` row in the payload) is silently skipped too
/// — the WHERE clause filters it out.
pub fn reorderPinnedTasks(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    ordered_ids: []const []const u8,
) !void {
    if (ordered_ids.len == 0) return;

    const count: i64 = @intCast(ordered_ids.len);
    var buf: [32]u8 = undefined;

    for (ordered_ids, 0..) |id_str, i| {
        const new_pos: i64 = count - 1 - @as(i64, @intCast(i));
        const pos_str = std.fmt.bufPrint(&buf, "{d}", .{new_pos}) catch {
            return error.IntegerTooLarge;
        };
        try db.exec(allocator,
            "UPDATE workspace_item_tasks SET pinned_position = ?, updated_at = datetime('now') " ++
                "WHERE id = ? AND workspace_item_id = ? AND is_pinned = 1",
            &.{ pos_str, id_str, workspace_item_id },
        );
    }
}
```

- [ ] **Step 3: Run the build to verify**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/llm_history.zig
git commit -m "feat(tasks): add setTaskPinned and reorderPinnedTasks use cases"
```

### Task 1.4: Add response types and helpers in `http_response.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/http_response.zig`

- [ ] **Step 1: Add `TaskPinResponse` and the helper after `WorkspaceItemReorderResponse`**

```zig
/// Typed response for `POST /api/.../tasks/:task_id/pin`. Returns the
/// new `pinned_position` so the client can confirm the row landed at
/// the bottom of the pinned region (the next id in the drag-reorder
/// list). `is_pinned` echoes the requested state.
pub const TaskPinResponse = struct {
    success: bool = true,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
};

pub fn makeTaskPinResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    is_pinned: bool,
    pinned_position: i64,
) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        TaskPinResponse{
            .id = id,
            .is_pinned = is_pinned,
            .pinned_position = pinned_position,
        },
        .{},
    );
}

/// Typed response for `POST /api/.../tasks/reorder_pinned`. Returns
/// the number of rows actually updated (a row that's not pinned is
/// silently skipped, so the count can be < ordered_ids.len).
pub const TasksReorderPinnedResponse = struct {
    success: bool = true,
    count: usize,
};

pub fn makeTasksReorderPinnedResponse(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return std.json.Stringify.valueAlloc(
        allocator,
        TasksReorderPinnedResponse{ .count = count },
        .{},
    );
}
```

- [ ] **Step 2: Run the build**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`.

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/http_response.zig
git commit -m "feat(tasks): add TaskPinResponse and TasksReorderPinnedResponse types"
```

---

## Chunk 2: Backend — HTTP handlers and tests

### Task 2.1: Write the `task_pin` HTTP handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/task_pin.zig`

- [ ] **Step 1: Write the handler**

Follow the `workspace_items_reorder.zig` thin-handler + use case pattern. The handler:

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;

/// HTTP handler: POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin
///
/// Body: { "is_pinned": true | false }
///
/// Behavior: flips the `is_pinned` flag on the row. When pinning
/// (true), the row's `pinned_position` is bumped to
/// MAX(pinned_position WHERE is_pinned=1) + 1 so it lands at the
/// BOTTOM of the pinned region. When unpinning (false), the row's
/// `pinned_position` is reset to 0.
///
/// Idempotent: pinning an already-pinned row is a no-op for the
/// position bump (MAX still includes the row's own value, so the
/// new position equals the current one). Unpinning an
/// already-unpinned row is also a no-op.
pub fn taskPinHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };
    defer parsed.deinit();

    const is_pinned_val = parsed.value.object.get("is_pinned") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned required" }) });
    };
    if (is_pinned_val != .bool) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "is_pinned must be a boolean" }) });
    }
    const is_pinned = is_pinned_val.bool;

    const di = try nalarcore.getSingleton();
    const new_pos = nalarcore.ai_mod.workspace_item_tasks.setTaskPinned(allocator, di.db, task_id, is_pinned) catch |err| switch (err) {
        error.TaskNotFound => return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Task not found" }) }),
        else => return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update task pin" }) }),
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTaskPinResponse(allocator, task_id, is_pinned, new_pos) });
}
```

- [ ] **Step 2: Re-export the handler in `http_handlers/mod.zig`**

Add to the task handlers block (near `tasksDeleteHandler`):

```zig
pub const taskPinHandler = @import("task_pin.zig").taskPinHandler;
```

- [ ] **Step 3: Run the build**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/task_pin.zig \
        src/ai_workflow/tui/http_handlers/mod.zig
git commit -m "feat(tasks): add taskPinHandler"
```

### Task 2.2: Write the `tasks_reorder_pinned` HTTP handler

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/tasks_reorder_pinned.zig`

- [ ] **Step 1: Write the handler**

```zig
const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;

/// HTTP handler: POST /api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned
///
/// Body: { "ordered_ids": ["id1", "id2", ..., "idN"] } (top-to-bottom
/// display order of the pinned subset).
///
/// Behavior: assigns `pinned_position = N-1 - i` to the i-th id.
/// The list lister's `ORDER BY is_pinned DESC, pinned_position DESC,
/// id DESC` then renders them in the user's chosen order. Rows that
/// aren't currently pinned (is_pinned=0) or that belong to a
/// different workspace_item are silently skipped (defense in depth,
/// consistent with the workspace reorder endpoints).
///
/// Idempotent: a second call with the same array leaves the data
/// unchanged (positions are recomputed but the final state is the
/// same).
pub fn tasksReorderPinnedHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "body required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const ordered_ids_val = root.get("ordered_ids") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids required" }) });
    };
    if (ordered_ids_val != .array) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "ordered_ids must be an array" }) });
    }

    var ids = std.ArrayList([]const u8).empty;
    defer ids.deinit(allocator);
    for (ordered_ids_val.array.items) |item| {
        if (item == .string) try ids.append(allocator, item.string);
    }

    const di = try nalarcore.getSingleton();
    nalarcore.ai_mod.workspace_item_tasks.reorderPinnedTasks(allocator, di.db, item_id, ids.items) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to reorder pinned tasks" }) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTasksReorderPinnedResponse(allocator, ids.items.len) });
}
```

- [ ] **Step 2: Re-export the handler in `http_handlers/mod.zig`**

```zig
pub const tasksReorderPinnedHandler = @import("tasks_reorder_pinned.zig").tasksReorderPinnedHandler;
```

- [ ] **Step 3: Run the build**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`.

- [ ] **Step 4: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_reorder_pinned.zig \
        src/ai_workflow/tui/http_handlers/mod.zig
git commit -m "feat(tasks): add tasksReorderPinnedHandler"
```

### Task 2.3: Register the routes in `main.zig`

**Files:**
- Modify: `src/main.zig` (around line 330, near the existing `tasks/.../run` route)

- [ ] **Step 1: Add the routes**

Insert just before the `try gs.router.get("/api/routines", ...)` line:

```zig
try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/pin", ai_mod.http_handlers.taskPinHandler);
try gs.router.post("/api/workspaces/:workspace_id/items/:item_id/tasks/reorder_pinned", ai_mod.http_handlers.tasksReorderPinnedHandler);
```

- [ ] **Step 2: Run the build**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat(tasks): register pin and reorder_pinned routes"
```

### Task 2.4: Write the static-check tests for the new handlers

**Files:**
- Create: `src/ai_workflow/tui/http_handlers/task_pin_test.zig`
- Create: `src/ai_workflow/tui/http_handlers/tasks_reorder_pinned_test.zig`
- Modify: `src/ai_workflow/tui/test_runner.zig` (register the new test files)

- [ ] **Step 1: Write `task_pin_test.zig`**

Mirror `workspace_items_reorder_test.zig` exactly. The contract:

1. The handler reads `is_pinned` from the body.
2. The handler calls `setTaskPinned`.
3. The response uses `makeTaskPinResponse` (typed).
4. The response struct is `TaskPinResponse`.

```zig
//! Static regression checks for the task pin handler.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_pin.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";
const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";
const MIGRATION_PATH = "src/ai_workflow/tui/migration.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "task_pin handler parses is_pinned from the request body" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "\"is_pinned\"") == null and
        std.mem.indexOf(u8, source, "'is_pinned'") == null)
    {
        return error.IsPinnedParamMissing;
    }
}

test "task_pin handler calls setTaskPinned use case" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "setTaskPinned") == null) {
        return error.SetTaskPinnedNotCalled;
    }
}

test "task_pin handler uses a typed response (makeTaskPinResponse)" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeTaskPinResponse") == null) {
        return error.TypedResponseMissing;
    }
}

test "llm_history exposes setTaskPinned" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn setTaskPinned(") == null) {
        return error.SetTaskPinnedMissing;
    }
}

test "TaskPinResponse and makeTaskPinResponse exist in http_response.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "TaskPinResponse") == null) {
        return error.TaskPinResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "makeTaskPinResponse") == null) {
        return error.MakeTaskPinResponseMissing;
    }
}

test "Migration050 declares is_pinned and pinned_position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MIGRATION_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "Migration050AddPinnedToWorkspaceItemTasks") == null) {
        return error.Migration050Missing;
    }
    if (std.mem.indexOf(u8, source, "is_pinned") == null) {
        return error.IsPinnedColumnMissing;
    }
    if (std.mem.indexOf(u8, source, "pinned_position") == null) {
        return error.PinnedPositionColumnMissing;
    }
}
```

- [ ] **Step 2: Write `tasks_reorder_pinned_test.zig`**

```zig
//! Static regression checks for the pinned-task reorder handler.

const std = @import("std");
const testing = std.testing;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_reorder_pinned.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";
const RESPONSE_PATH = "src/ai_workflow/tui/http_handlers/http_response.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
    );
}

test "tasks_reorder_pinned handler parses ordered_ids" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "ordered_ids") == null) {
        return error.OrderedIdsMissing;
    }
}

test "tasks_reorder_pinned handler calls reorderPinnedTasks use case" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "reorderPinnedTasks") == null) {
        return error.ReorderPinnedTasksNotCalled;
    }
}

test "tasks_reorder_pinned scopes UPDATE by is_pinned = 1" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The use case should filter by is_pinned = 1 so a payload
    // containing unpinned rows is a silent no-op for them.
    if (std.mem.indexOf(u8, source, "is_pinned = 1") == null) {
        return error.IsPinnedFilterMissing;
    }
}

test "tasks_reorder_pinned uses position = (count - 1 - i) formula" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "count - 1 -") == null) {
        return error.PositionFormulaMissing;
    }
}

test "tasks_reorder_pinned handler uses makeTasksReorderPinnedResponse" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "makeTasksReorderPinnedResponse") == null) {
        return error.TypedResponseMissing;
    }
}

test "llm_history exposes reorderPinnedTasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "pub fn reorderPinnedTasks(") == null) {
        return error.ReorderPinnedTasksMissing;
    }
}

test "TasksReorderPinnedResponse and helper exist in http_response.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, RESPONSE_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "TasksReorderPinnedResponse") == null) {
        return error.TasksReorderPinnedResponseStructMissing;
    }
    if (std.mem.indexOf(u8, source, "makeTasksReorderPinnedResponse") == null) {
        return error.MakeTasksReorderPinnedResponseMissing;
    }
}
```

- [ ] **Step 3: Register the new tests in `test_runner.zig`**

Add these two lines inside the `test {...}` block, right after the `workspace_items_reorder_test.zig` import:

```zig
    _ = @import("http_handlers/task_pin_test.zig");
    _ = @import("http_handlers/tasks_reorder_pinned_test.zig");
```

- [ ] **Step 4: Run the tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success` with the test count going up by 12 (6 from `task_pin_test.zig` + 7 from `tasks_reorder_pinned_test.zig` = 13 new).

- [ ] **Step 5: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/task_pin_test.zig \
        src/ai_workflow/tui/http_handlers/tasks_reorder_pinned_test.zig \
        src/ai_workflow/tui/test_runner.zig
git commit -m "test(tasks): add static regression tests for pin and reorder_pinned handlers"
```

### Task 2.5: Add the `is_pinned` / `pinned_position` contract to `tasks_list_test.zig`

**Files:**
- Modify: `src/ai_workflow/tui/http_handlers/tasks_list_test.zig` (add 2 new static tests)

- [ ] **Step 1: Add the tests at the bottom of `tasks_list_test.zig`**

```zig
// ─── Contract 15: list SELECT includes is_pinned and pinned_position ────

test "tasks_list llm_history SELECT includes is_pinned and pinned_position" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The pinned-task list requires both columns in the list SELECT
    // so the response can carry them to the frontend.
    if (std.mem.indexOf(u8, source, "t.is_pinned") == null) return error.IsPinnedColumnNotInSelect;
    if (std.mem.indexOf(u8, source, "t.pinned_position") == null) return error.PinnedPositionColumnNotInSelect;
}

test "tasks_list llm_history ORDER BY puts pinned rows first" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The list ORDER BY must start with is_pinned DESC so pinned
    // rows surface at the top of the per-item task list. Look for
    // the substring "is_pinned DESC" (not "ORDER BY is_pinned DESC"
    // — same rationale as the position-DESC test above).
    if (std.mem.indexOf(u8, source, "is_pinned DESC") == null) {
        std.debug.print(
            "\n!! {s} does not ORDER BY is_pinned DESC !!\n" ++
                "   Pinned tasks will not surface first in the task list.\n" ++
                "   Add: ORDER BY t.is_pinned DESC, t.pinned_position DESC, ...\n",
            .{LLM_HISTORY_PATH},
        );
        return error.OrderByIsPinnedMissing;
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`, test count +2.

- [ ] **Step 3: Commit**

```bash
git add src/ai_workflow/tui/http_handlers/tasks_list_test.zig
git commit -m "test(tasks): assert is_pinned / pinned_position are in the list SELECT and ORDER BY"
```

---

## Chunk 3: Frontend — API and store

### Task 3.1: Extend the `Task` interface and add the API functions

**Files:**
- Modify: `src/apps/desktop/src/api/index.ts`

- [ ] **Step 1: Add `is_pinned` and `pinned_position` to the `Task` interface**

Find the `Task` interface (around line 139). Add the two optional fields (optional to preserve the test-file typing rule — see `nalar-frontend-task-literal-typing-rule` skill memory):

```ts
export interface Task {
  // ... existing fields ...
  // NEW (pinned-tasks feature). Both optional so legacy test
  // fixtures (which construct Task literals without these fields)
  // keep type-checking.
  is_pinned?: boolean
  pinned_position?: number
}
```

- [ ] **Step 2: Add `pinTask` after `deleteTask`**

```ts
/**
 * Pin or unpin a task. The backend bumps the row's
 * `pinned_position` to MAX+1 (when pinning) so a newly-pinned task
 * lands at the BOTTOM of the pinned region; the user can drag it
 * to a different position afterwards. Returns the new
 * `pinned_position` so the store can confirm the row landed where
 * the user expects.
 */
export async function pinTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
): Promise<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }> {
  return await apiFetch<{ success: boolean; id: string; is_pinned: boolean; pinned_position: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/pin`,
    {
      method: 'POST',
      body: { is_pinned: isPinned },
    },
  )
}

/**
 * Reorder the pinned subset of a single workspace item. The
 * `orderedIds` array is the full top-to-bottom display order of
 * the pinned rows. The backend assigns `pinned_position =
 * count - 1 - i` so the rows render in the user's chosen order.
 */
export async function reorderPinnedTasks(
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/tasks/reorder_pinned`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}
```

- [ ] **Step 3: Run the type-check**

Run: `cd src/apps/desktop && timeout 120 bun run type-check 2>&1 | tail -n 20`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/api/index.ts
git commit -m "feat(tasks): add pinTask and reorderPinnedTasks API functions"
```

### Task 3.2: Add the `pinTask` and `reorderPinnedTasks` store actions

**Files:**
- Modify: `src/apps/desktop/src/stores/workspaces.ts`

- [ ] **Step 1: Add the `pinTask` action near `deleteTask` (around line 624)**

```ts
/**
 * Pin or unpin a task and persist the change via
 * `POST /api/.../tasks/:task_id/pin`. Optimistic: the local task's
 * `is_pinned` flag is flipped immediately and the `pinned_position`
 * is bumped to MAX+1 (matching the backend's behavior). On API
 * failure, the previous pin state and position are restored and
 * the error is logged.
 *
 * When the user pins a task, the row is moved to the bottom of the
 * pinned region. The list lister's `ORDER BY is_pinned DESC,
 * pinned_position DESC, ...` then surfaces it correctly on the next
 * render.
 */
async function pinTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
): Promise<{ success: boolean; pinned_position: number } | undefined> {
  const workspace = workspaces.value.find((w) => w.id === workspaceId)
  if (!workspace) return undefined
  const item = workspace.items.find((i) => i.id === itemId)
  if (!item || !item.tasks) return undefined
  const task = item.tasks.find((t) => t.id === taskId)
  if (!task) return undefined

  // Snapshot for rollback.
  const previousIsPinned = task.is_pinned ?? false
  const previousPinnedPosition = task.pinned_position ?? 0

  // Compute the optimistic pinned_position. When pinning, bump to
  // MAX+1 across the item's currently-pinned tasks. When unpinning,
  // reset to 0 (the value is irrelevant for unpinned rows).
  let optimisticPosition = previousPinnedPosition
  if (isPinned) {
    const maxPinned = item.tasks.reduce<number>((acc, t) => {
      if (t.id === taskId) return acc // exclude the row being pinned
      const p = t.pinned_position ?? 0
      return p > acc ? p : acc
    }, -1)
    optimisticPosition = maxPinned + 1
  }

  task.is_pinned = isPinned
  task.pinned_position = optimisticPosition

  try {
    const result = await api.pinTask(workspaceId, itemId, taskId, isPinned)
    // The backend may assign a different pinned_position if a
    // concurrent pin raced with ours. Echo the backend's value.
    if (result.pinned_position !== undefined) {
      task.pinned_position = result.pinned_position
    }
    return { success: true, pinned_position: result.pinned_position }
  } catch (err) {
    console.error('[workspacesStore.pinTask] API call failed, rolling back:', err)
    task.is_pinned = previousIsPinned
    task.pinned_position = previousPinnedPosition
    return undefined
  }
}
```

- [ ] **Step 2: Add the `reorderPinnedTasks` action**

```ts
/**
 * Reorder the pinned subset of a single workspace item and persist
 * the new order via
 * `POST /api/.../tasks/reorder_pinned`. Optimistic: the item's
 * pinned tasks are reordered in the local array immediately so the
 * UI snaps on drop. On API failure, the snapshot is restored and
 * the error is logged.
 *
 * The caller (WorkspaceItem.vue's drag handler) sends the FULL
 * ordered list of pinned task IDs, not a delta. Unpinned tasks
 * are not affected (they keep their position in the unpinned
 * region below).
 */
async function reorderPinnedTasks(
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
) {
  const workspace = workspaces.value.find((w) => w.id === workspaceId)
  if (!workspace) return
  const item = workspace.items.find((i) => i.id === itemId)
  if (!item || !item.tasks) return

  const currentPinned = item.tasks.filter((t) => t.is_pinned)
  if (currentPinned.length === 0) return

  if (orderedIds.length !== currentPinned.length) {
    console.error(
      `[workspacesStore.reorderPinnedTasks] orderedIds length ${orderedIds.length} != current pinned ${currentPinned.length}; refusing reorder`,
    )
    return
  }

  // Snapshot for rollback.
  const previousOrder = item.tasks.slice()

  // Optimistic local reorder: rebuild the tasks array as
  // [ordered pinned rows in the new order, ...unpinned rows].
  // Unpinned rows keep their existing relative order (the
  // unpinned-region ORDER BY is unchanged by the reorder).
  const pinnedById = new Map(currentPinned.map((t) => [t.id, t]))
  const reorderedPinned: Task[] = []
  for (const id of orderedIds) {
    const t = pinnedById.get(id)
    if (t) reorderedPinned.push(t)
  }
  // Defensive: any pinned rows missed in the payload are appended
  // at the end (should not happen given the length check).
  for (const t of currentPinned) {
    if (!orderedIds.includes(t.id)) reorderedPinned.push(t)
  }
  const unpinned = item.tasks.filter((t) => !t.is_pinned)
  item.tasks = [...reorderedPinned, ...unpinned]

  try {
    await api.reorderPinnedTasks(workspaceId, itemId, orderedIds)
  } catch (err) {
    console.error(
      '[workspacesStore.reorderPinnedTasks] API call failed, rolling back:',
      err,
    )
    item.tasks = previousOrder
  }
}
```

- [ ] **Step 3: Return the new actions from the store**

Find the `return { ... }` block at the bottom of `defineStore`. Add:

```ts
  return {
    // ... existing actions ...
    pinTask,
    reorderPinnedTasks,
  }
```

- [ ] **Step 4: Run the type-check**

Run: `cd src/apps/desktop && timeout 120 bun run type-check 2>&1 | tail -n 20`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/stores/workspaces.ts
git commit -m "feat(tasks): add pinTask and reorderPinnedTasks store actions"
```

---

## Chunk 4: Frontend — UI changes

### Task 4.1: Add a pin/unpin button to `WorkspaceItemTask.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItemTask.vue`

- [ ] **Step 1: Add the `pinTask` event to the `defineEmits` block**

In the `<script setup>` block, add a new event entry alongside the existing `editRoutine` / `runRoutine` events:

```ts
const emit = defineEmits<{
  // ... existing events ...
  // NEW (pinned-tasks feature): emitted by the pin/unpin button.
  // Payload carries the new is_pinned state so the store doesn't
  // have to re-read the task prop.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
}>()
```

- [ ] **Step 2: Add a `handlePinToggle` method**

```ts
const handlePinToggle = (event: Event) => {
  event.stopPropagation()
  // Flip the local optimistic state — the store action will echo
  // the same flip, so the parent's `task.is_pinned` will be
  // updated to match. If the API call fails, the store rolls back
  // and our local state is overwritten on the next render.
  emit('pinTask', props.workspaceId, props.itemId, props.task.id, !props.task.is_pinned)
}
```

- [ ] **Step 3: Add a pin button + persistent pin indicator to the template**

Add a new `<!-- Pin indicator -->` and `<!-- Pin toggle -->` to the template, inside both the ROUTINE and STANDARD branches (or as a single shared slot if the structure is shared). The persistent indicator (📌) is always visible when `is_pinned === true`; the toggle button is visible on hover like the existing pencil/X buttons.

Insert the persistent indicator immediately after the existing status dot / spinner (in the STANDARD branch, it's a slot before the task name):

```html
<!-- Pin indicator (always visible when pinned) -->
<span
  v-if="task.is_pinned"
  class="w-3 h-3 flex items-center justify-center shrink-0 text-yellow-400"
  title="Pinned"
  data-testid="task-pin-indicator"
>
  <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
    <path d="M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z"/>
  </svg>
</span>
```

And add the toggle button (between the existing status indicator and the rename button in BOTH branches, OR factor a shared slot — the cleanest approach is to add the toggle button once in each branch because the structure is duplicated, but use a small helper to avoid repetition):

For the STANDARD branch, add the pin button before the rename button:

```html
<!-- Pin/unpin toggle (show on hover) -->
<button
  @click="handlePinToggle($event)"
  class="w-4 h-4 flex items-center justify-center rounded opacity-0 group-hover/task:opacity-100 transition-opacity"
  :class="task.is_pinned ? 'text-yellow-400' : 'text-[--semantic-text-dim] hover:text-yellow-400'"
  :title="task.is_pinned ? 'Unpin task' : 'Pin task'"
  data-testid="task-pin-toggle"
>
  <svg v-if="task.is_pinned" class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
    <path d="M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z"/>
  </svg>
  <svg v-else class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 12V4h1V2H7v2h1v8l-2 2v2h5.2v6h1.6v-6H18v-2l-2-2z"/>
  </svg>
</button>
```

For the ROUTINE branch, add the same button before the existing `Edit Routine` pencil.

- [ ] **Step 4: Run the type-check + tests**

Run:
```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected: no type errors, all existing tests pass (the existing `workspaceItemTask.spec.ts` and `workspaceItemTaskRoutine.spec.ts` should still pass — they assert the structure of the standard / routine branches, and the new pin button slots in without removing any of the existing assertions).

- [ ] **Step 5: Commit**

```bash
git add src/apps/desktop/src/components/WorkspaceItemTask.vue
git commit -m "feat(tasks): add pin/unpin button + pin indicator to WorkspaceItemTask"
```

### Task 4.2: Split the task list into pinned and unpinned regions in `WorkspaceItem.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItem.vue`

- [ ] **Step 1: Add the `pinTask` and `reorderPinnedTasks` events to `defineEmits`**

```ts
const emit = defineEmits<{
  // ... existing events ...
  // NEW (pinned-tasks feature): pin/unpin forwarded from
  // <WorkspaceItemTask>. WorkspaceList will re-emit to Sidebar.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // NEW: drag-reorder of the pinned subset.
  reorderPinnedTasks: [workspaceId: string, itemId: string, orderedIds: string[]]
}>()
```

- [ ] **Step 2: Add `handlePinTask` and `handleReorderPinnedTasks` pass-through handlers**

```ts
const handlePinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  emit('pinTask', workspaceId, itemId, taskId, isPinned)
}

const handleReorderPinnedTasks = (orderedIds: string[]) => {
  emit('reorderPinnedTasks', props.workspaceId, props.item.id, orderedIds)
}
```

- [ ] **Step 3: Update the template to render pinned tasks first, then unpinned**

The current template (around line 257-269) renders all tasks in a single v-for. Split it into two v-for loops:

```html
<div v-if="isExpanded && item.tasks && item.tasks.length > 0" class="ml-8 mt-1.5 space-y-0.5 pl-2 border-l border-[--color-border]/30">
  <!-- Pinned region: drag-and-drop reorders only within this
       list. The drop handler calls handleReorderPinnedTasks. -->
  <div
    v-if="item.tasks.some((t) => t.is_pinned)"
    data-testid="pinned-tasks-region"
    @drop.prevent="handlePinnedDrop"
    @dragover.prevent
  >
    <WorkspaceItemTask
      v-for="task in item.tasks.filter((t) => t.is_pinned)"
      :key="task.id"
      :task="task"
      :workspace-id="workspaceId"
      :item-id="item.id"
      draggable="true"
      @select-task="handleSelectTask"
      @delete-task="handleDeleteTask"
      @rename-task="handleRenameTask"
      @edit-routine="handleEditRoutine"
      @run-routine="handleRunRoutine"
      @pin-task="handlePinTask"
    />
  </div>

  <!-- Unpinned region: regular order, no drag. -->
  <WorkspaceItemTask
    v-for="task in item.tasks.filter((t) => !t.is_pinned)"
    :key="task.id"
    :task="task"
    :workspace-id="workspaceId"
    :item-id="item.id"
    @select-task="handleSelectTask"
    @delete-task="handleDeleteTask"
    @rename-task="handleRenameTask"
    @edit-routine="handleEditRoutine"
    @run-routine="handleRunRoutine"
    @pin-task="handlePinTask"
  />

  <!-- existing Load More button stays unchanged -->
  <button v-if="item.hasMoreTasks" ...>...</button>
</div>
```

- [ ] **Step 4: Add the `handlePinnedDrop` method**

```ts
const handlePinnedDrop = (event: DragEvent) => {
  event.preventDefault()
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const draggedId = dataTransfer.getData('text/plain')
  if (!draggedId) return

  const pinned = (item.tasks ?? []).filter((t) => t.is_pinned)
  if (pinned.length === 0) return

  // Compute the new pinned order: keep the current order, but
  // splice the dragged row to the end. (For v1, "drop on the
  // pinned region" = "move to bottom of the pinned region". A
  // future iteration can add hover-position-based insertion.)
  const fromIdx = pinned.findIndex((t) => t.id === draggedId)
  if (fromIdx === -1) return // drag came from outside the pinned region

  const reordered = pinned.slice()
  const [moved] = reordered.splice(fromIdx, 1)
  if (moved) reordered.push(moved)
  handleReorderPinnedTasks(reordered.map((t) => t.id))
}
```

- [ ] **Step 5: Wire up the dragstart on the pinned rows**

In the `<WorkspaceItemTask>` for the pinned region, add `@dragstart` to set the dataTransfer. But the drag handler is currently in `WorkspaceItemTask.vue` only as a render-side attribute. The simplest pattern is to set it on the button via a native event. Add a `@dragstart` handler to the pinned region's `<WorkspaceItemTask>` via a wrapper:

The cleanest approach: add a `dragstart` listener on the pinned region that captures the closest `[data-task-id]` and sets the dataTransfer:

```html
<div
  v-if="item.tasks.some((t) => t.is_pinned)"
  data-testid="pinned-tasks-region"
  @drop.prevent="handlePinnedDrop"
  @dragover.prevent
  @dragstart="handlePinnedDragStart"
>
```

```ts
const handlePinnedDragStart = (event: DragEvent) => {
  const target = event.target as HTMLElement
  const row = target.closest('[data-task-id]') as HTMLElement | null
  if (!row) return
  const taskId = row.dataset.taskId
  if (!taskId) return
  event.dataTransfer?.setData('text/plain', taskId)
  event.dataTransfer!.effectAllowed = 'move'
}
```

The `WorkspaceItemTask.vue`'s root `<button>` needs `data-task-id="task.id"` added to its root element. (See Task 4.3.)

- [ ] **Step 6: Run the type-check**

Run: `cd src/apps/desktop && timeout 120 bun run type-check 2>&1 | tail -n 20`
Expected: no errors. If you see `Type 'T | undefined'` errors on the new filter calls, add non-null assertions or default the array (`item.tasks ?? []`).

- [ ] **Step 7: Commit**

```bash
git add src/apps/desktop/src/components/WorkspaceItem.vue
git commit -m "feat(tasks): split task list into pinned + unpinned regions in WorkspaceItem"
```

### Task 4.3: Add `data-task-id` to `WorkspaceItemTask.vue`'s root

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceItemTask.vue`

- [ ] **Step 1: Add `data-task-id` to the root `<button>`**

Find the root `<button class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"` element. Add the attribute:

```html
<button
  class="flex items-center gap-2 px-3 py-1 rounded text-xs group/task cursor-pointer transition-all duration-200"
  :data-task-id="task.id"
  :style="..."
  @click="handleSelectTask"
>
```

- [ ] **Step 2: Run the type-check + tests**

Run:
```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 20
```

Expected: all green.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/components/WorkspaceItemTask.vue
git commit -m "feat(tasks): expose data-task-id on WorkspaceItemTask root for drag delegation"
```

### Task 4.4: Re-emit `pinTask` and `reorderPinnedTasks` from `WorkspaceList.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/WorkspaceList.vue`

- [ ] **Step 1: Add the events to `defineEmits`**

```ts
const emit = defineEmits<{
  // ... existing events ...
  // NEW (pinned-tasks feature): pin/unpin forwarded from
  // <WorkspaceItem>. Sidebar handles this and calls the store.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // NEW: drag-reorder of the pinned subset.
  reorderPinnedTasks: [workspaceId: string, itemId: string, orderedIds: string[]]
}>()
```

- [ ] **Step 2: Forward the events from `<WorkspaceItem>`**

In the template, find the `<WorkspaceItem>` component usage and add:

```html
@pin-task="(workspaceId, itemId, taskId, isPinned) => emit('pinTask', workspaceId, itemId, taskId, isPinned)"
@reorder-pinned-tasks="(workspaceId, itemId, orderedIds) => emit('reorderPinnedTasks', workspaceId, itemId, orderedIds)"
```

- [ ] **Step 3: Run the type-check**

Run: `cd src/apps/desktop && timeout 120 bun run type-check 2>&1 | tail -n 20`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/WorkspaceList.vue
git commit -m "feat(tasks): forward pinTask and reorderPinnedTasks events from WorkspaceList"
```

### Task 4.5: Wire the new events in `Sidebar.vue`

**Files:**
- Modify: `src/apps/desktop/src/components/Sidebar.vue`

- [ ] **Step 1: Add the handlers near `handleReorderWorkspaces` and `handleReorderWorkspaceItems`**

```ts
const handlePinTask = (
  workspaceId: string,
  itemId: string,
  taskId: string,
  isPinned: boolean,
) => {
  workspacesStore.pinTask(workspaceId, itemId, taskId, isPinned)
}

const handleReorderPinnedTasks = (
  workspaceId: string,
  itemId: string,
  orderedIds: string[],
) => {
  workspacesStore.reorderPinnedTasks(workspaceId, itemId, orderedIds)
}
```

- [ ] **Step 2: Wire the new events on the `<WorkspaceList>` element**

Find the `<WorkspaceList ... @reorder-workspace-items="handleReorderWorkspaceItems" />` usage and add:

```html
@pin-task="handlePinTask"
@reorder-pinned-tasks="handleReorderPinnedTasks"
```

- [ ] **Step 3: Run the type-check + build**

Run:
```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 20
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add src/apps/desktop/src/components/Sidebar.vue
git commit -m "feat(tasks): wire pinTask and reorderPinnedTasks in Sidebar"
```

---

## Chunk 5: Frontend — tests

### Task 5.1: Write the `pinTask` store test

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStorePinTask.spec.ts`

- [ ] **Step 1: Write the test file**

Mirror `workspacesStoreItemReorder.spec.ts` (the existing item-reorder test). The test seeds the store with a workspace + item + tasks, calls `pinTask`, and asserts:

- The task's `is_pinned` flips to `true` after the call.
- The task's `pinned_position` is bumped to MAX+1 across the item's currently-pinned tasks.
- The API was called with the right URL + body.
- On API failure, the previous state is restored.

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem, type Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const task = (id: string, name: string, opts: Partial<Task> = {}): Task => ({
  id,
  name,
  task_type: 'standard',
  ...opts,
})

const item = (id: string, tasks: Task[] = []): WorkspaceItem => ({
  id,
  name: 'item',
  item_type: 'folder',
  tasks,
})

const ws = (id: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name: 'ws',
  icon: '📁',
  expanded: true,
  items,
})

describe('useWorkspacesStore.pinTask()', () => {
  const pinTaskMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    pinTaskMock.mockReset()
    vi.spyOn(api, 'pinTask').mockImplementation(pinTaskMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('flips is_pinned to true and bumps pinned_position to MAX+1', async () => {
    const store = useWorkspacesStore()
    // Seed: 1 pinned task at position 0, 1 unpinned task to be pinned.
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second')
    const w = ws('ws_1', [item('item_1', [t1, t2])])
    ;(store as any).workspaces = [w]

    pinTaskMock.mockResolvedValue({
      success: true,
      id: 'task_2',
      is_pinned: true,
      pinned_position: 1,
    })

    const result = await store.pinTask('ws_1', 'item_1', 'task_2', true)
    expect(result?.success).toBe(true)
    expect(result?.pinned_position).toBe(1)

    // Optimistic state was applied.
    const updated = w.items[0].tasks.find((t) => t.id === 'task_2')!
    expect(updated.is_pinned).toBe(true)
    expect(updated.pinned_position).toBe(1)

    // API was called once with the right shape.
    expect(pinTaskMock).toHaveBeenCalledTimes(1)
    expect(pinTaskMock).toHaveBeenCalledWith('ws_1', 'item_1', 'task_2', true)
  })

  it('flips is_pinned to false and resets pinned_position to 0', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'pinned', { is_pinned: true, pinned_position: 3 })
    const w = ws('ws_1', [item('item_1', [t1])])
    ;(store as any).workspaces = [w]

    pinTaskMock.mockResolvedValue({
      success: true,
      id: 'task_1',
      is_pinned: false,
      pinned_position: 0,
    })

    const result = await store.pinTask('ws_1', 'item_1', 'task_1', false)
    expect(result?.success).toBe(true)
    const updated = w.items[0].tasks.find((t) => t.id === 'task_1')!
    expect(updated.is_pinned).toBe(false)
    expect(updated.pinned_position).toBe(0)
  })

  it('rolls back is_pinned and pinned_position on API failure', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second')
    const w = ws('ws_1', [item('item_1', [t1, t2])])
    ;(store as any).workspaces = [w]

    pinTaskMock.mockRejectedValue(new Error('network'))

    const result = await store.pinTask('ws_1', 'item_1', 'task_2', true)
    expect(result).toBeUndefined()

    // State was rolled back: task_2 is back to unpinned.
    const updated = w.items[0].tasks.find((t) => t.id === 'task_2')!
    expect(updated.is_pinned).toBe(false)
    expect(updated.pinned_position).toBe(0)
  })
})
```

- [ ] **Step 2: Run the test**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run workspacesStorePinTask 2>&1 | tail -n 20`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/workspacesStorePinTask.spec.ts
git commit -m "test(tasks): add pinTask store tests"
```

### Task 5.2: Write the `reorderPinnedTasks` store test

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspacesStoreReorderPinnedTasks.spec.ts`

- [ ] **Step 1: Write the test file**

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem, type Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const task = (id: string, name: string, opts: Partial<Task> = {}): Task => ({
  id,
  name,
  task_type: 'standard',
  ...opts,
})

const item = (id: string, tasks: Task[] = []): WorkspaceItem => ({
  id,
  name: 'item',
  item_type: 'folder',
  tasks,
})

const ws = (id: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name: 'ws',
  icon: '📁',
  expanded: true,
  items,
})

describe('useWorkspacesStore.reorderPinnedTasks()', () => {
  const reorderPinnedMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    reorderPinnedMock.mockReset()
    vi.spyOn(api, 'reorderPinnedTasks').mockImplementation(reorderPinnedMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('optimistically reorders the pinned subset and persists', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second', { is_pinned: true, pinned_position: 1 })
    const t3 = task('task_3', 'third') // unpinned
    const w = ws('ws_1', [item('item_1', [t1, t2, t3])])
    ;(store as any).workspaces = [w]

    reorderPinnedMock.mockResolvedValue({ success: true, count: 2 })

    await store.reorderPinnedTasks('ws_1', 'item_1', ['task_2', 'task_1'])

    // Pinned subset is now [task_2, task_1] (in that order), and
    // the unpinned task_3 follows.
    const tasks = w.items[0].tasks
    expect(tasks[0].id).toBe('task_2')
    expect(tasks[1].id).toBe('task_1')
    expect(tasks[2].id).toBe('task_3')

    // API was called with the new pinned order (NOT including the
    // unpinned task_3).
    expect(reorderPinnedMock).toHaveBeenCalledTimes(1)
    expect(reorderPinnedMock).toHaveBeenCalledWith('ws_1', 'item_1', [
      'task_2',
      'task_1',
    ])
  })

  it('refuses a length mismatch and does not call the API', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second', { is_pinned: true, pinned_position: 1 })
    const w = ws('ws_1', [item('item_1', [t1, t2])])
    ;(store as any).workspaces = [w]

    await store.reorderPinnedTasks('ws_1', 'item_1', ['task_1']) // missing task_2

    expect(reorderPinnedMock).not.toHaveBeenCalled()
    // Original order preserved.
    expect(w.items[0].tasks[0].id).toBe('task_1')
    expect(w.items[0].tasks[1].id).toBe('task_2')
  })

  it('rolls back on API failure', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second', { is_pinned: true, pinned_position: 1 })
    const w = ws('ws_1', [item('item_1', [t1, t2])])
    ;(store as any).workspaces = [w]

    reorderPinnedMock.mockRejectedValue(new Error('network'))

    await store.reorderPinnedTasks('ws_1', 'item_1', ['task_2', 'task_1'])

    // Order rolled back.
    expect(w.items[0].tasks[0].id).toBe('task_1')
    expect(w.items[0].tasks[1].id).toBe('task_2')
  })
})
```

- [ ] **Step 2: Run the test**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run workspacesStoreReorderPinnedTasks 2>&1 | tail -n 20`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/workspacesStoreReorderPinnedTasks.spec.ts
git commit -m "test(tasks): add reorderPinnedTasks store tests"
```

### Task 5.3: Write the `WorkspaceItemTask` pin component test

**Files:**
- Create: `src/apps/desktop/src/__tests__/workspaceItemTaskPin.spec.ts`

- [ ] **Step 1: Write the test file**

```ts
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount } from '@vue/test-utils'

import WorkspaceItemTask from '../components/WorkspaceItemTask.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const task = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'demo',
  task_type: 'standard',
  ...overrides,
})

describe('WorkspaceItemTask pin button', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
    })
  })

  it('renders the persistent pin indicator when is_pinned is true', () => {
    const wrapper = mount(WorkspaceItemTask, {
      props: {
        task: task({ is_pinned: true, pinned_position: 0 }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(true)
  })

  it('does not render the pin indicator when is_pinned is false', () => {
    const wrapper = mount(WorkspaceItemTask, {
      props: {
        task: task({ is_pinned: false }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(true)
  })

  it('emits pinTask with the flipped state on toggle click', async () => {
    const wrapper = mount(WorkspaceItemTask, {
      props: {
        task: task({ is_pinned: false }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await wrapper.find('[data-testid="task-pin-toggle"]').trigger('click')
    const events = wrapper.emitted('pinTask')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual(['ws_1', 'item_1', 'task_1', true])
  })

  it('emits pinTask with is_pinned=false when unpinning', async () => {
    const wrapper = mount(WorkspaceItemTask, {
      props: {
        task: task({ is_pinned: true, pinned_position: 0 }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await wrapper.find('[data-testid="task-pin-toggle"]').trigger('click')
    const events = wrapper.emitted('pinTask')
    expect(events![0]).toEqual(['ws_1', 'item_1', 'task_1', false])
  })
})
```

- [ ] **Step 2: Run the test**

Run: `cd src/apps/desktop && timeout 120 bunx vitest run workspaceItemTaskPin 2>&1 | tail -n 20`
Expected: 4 tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/apps/desktop/src/__tests__/workspaceItemTaskPin.spec.ts
git commit -m "test(tasks): add pin button tests for WorkspaceItemTask"
```

---

## Chunk 6: End-to-end verification

### Task 6.1: Build the backend binary and run the full test suite

- [ ] **Step 1: Build the backend**

Run: `cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox && timeout 180 zig build install:linux:system 2>&1 | tail -n 10`
Expected: `Build Summary: 4/6 steps succeeded` (the cp at step 5 fails harmlessly on permission). The crucial "compile exe nalar" step must succeed.

- [ ] **Step 2: Run the full test suite**

Run: `timeout 180 zig build test --summary all 2>&1 | tail -n 5`
Expected: `test success`. Test count should be the prior baseline + 15 (13 from the two new static tests + 2 from the new list-SELECT tests).

- [ ] **Step 3: Run the frontend build + tests**

Run:
```bash
cd src/apps/desktop && timeout 120 bun run build 2>&1 | tail -n 10
cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 10
```

Expected: build is clean, all tests pass (prior baseline + 10: 3 for `workspacesStorePinTask` + 3 for `workspacesStoreReorderPinnedTasks` + 4 for `workspaceItemTaskPin`).

### Task 6.2: Manual smoke test on port 8080

- [ ] **Step 1: Start the server**

```bash
cd /home/ginwa/agentic_coding_zig/ginwaaitoolbox
./zig-out/bin/nalar --port 8080 &
SERVER_PID=$!
sleep 2
```

- [ ] **Step 2: Create a workspace and item**

Use the existing `curl` flow from the project's smoke-test docs to create a workspace, an item, and 3 tasks. (If a workspace already exists, reuse it.)

- [ ] **Step 3: Pin a task**

```bash
curl -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks/$TASK_ID/pin" \
    -H "Content-Type: application/json" \
    -d '{"is_pinned": true}'
```

Expected: 200 + `{"success":true,"id":"...","is_pinned":true,"pinned_position":0}`

- [ ] **Step 4: Pin a second task**

```bash
curl -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks/$TASK_2_ID/pin" \
    -H "Content-Type: application/json" \
    -d '{"is_pinned": true}'
```

Expected: 200 + `{"success":true,"id":"...","is_pinned":true,"pinned_position":1}` (bumped to 1).

- [ ] **Step 5: Reorder the pinned subset**

```bash
curl -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks/reorder_pinned" \
    -H "Content-Type: application/json" \
    -d "{\"ordered_ids\": [\"$TASK_2_ID\", \"$TASK_ID\"]}"
```

Expected: 200 + `{"success":true,"count":2}`.

- [ ] **Step 6: List tasks and verify the order**

```bash
curl "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks?sort_by=updated_at&direction=desc"
```

Expected: `task_2` first (pinned_position=1), `task_1` second (pinned_position=0), `task_3` third (unpinned).

- [ ] **Step 7: Unpin a task**

```bash
curl -X POST "http://127.0.0.1:8080/api/workspaces/$WS_ID/items/$ITEM_ID/tasks/$TASK_ID/pin" \
    -H "Content-Type: application/json" \
    -d '{"is_pinned": false}'
```

Expected: 200 + `{"success":true,"id":"...","is_pinned":false,"pinned_position":0}`. Re-list and confirm `task_1` is now at the bottom (unpinned), `task_2` is still at the top (pinned).

- [ ] **Step 8: Stop the server**

```bash
kill $SERVER_PID
```

- [ ] **Step 9: Commit any final changes**

If the smoke test surfaced an issue, fix and commit. Otherwise, no commit needed.

### Task 6.3: Final commit + branch

- [ ] **Step 1: Verify all changes are committed**

Run: `git status`
Expected: clean working tree.

- [ ] **Step 2: Verify the test counts are correct**

Run:
```bash
timeout 180 zig build test --summary all 2>&1 | tail -n 5
cd src/apps/desktop && timeout 120 bunx vitest run 2>&1 | tail -n 10
```

Expected: backend + frontend test counts match the targets.

- [ ] **Step 3: Push the branch**

```bash
git push origin feature/pinned-workspace-item-tasks
```

---

## Notes for the implementer

- **Always alias tables in SELECTs** — the project convention (see `nalar-sql-alias-tables` skill memory). Use `t.is_pinned`, `t.pinned_position` rather than bare `is_pinned`.
- **Cursor format changed** — the cursor in `tasks_list` now uses `<is_pinned>|<sort_value>|<id>`. The static test `tasks_list_test.zig` does NOT cover the cursor format (it covers `is_pinned` and `pinned_position` in the SELECT), so the cursor change is a separate concern; the implementer should add a behavioral test in a follow-up if they want to lock the format.
- **Drag-and-drop on the pinned region is intentionally simple** — v1 just moves the dragged task to the bottom of the pinned region. A future iteration can add hover-position-based insertion (track `dragOver` per-row and splice at the right index). The current scope keeps the change small and matches the "minimum viable feature" framing.
- **The `pinned_position` reset to 0 on unpin is a soft invariant** — the column is meaningless for unpinned rows, but resetting it keeps the column's value in a known state, which is useful for debugging (`SELECT pinned_position FROM workspace_item_tasks WHERE id = ?` is always 0 for unpinned rows).
- **Don't change the `WorkspaceItemTask` rename / delete events** — those are the existing `WorkspaceItemTask.vue` API. The new `pinTask` event is purely additive.
- **The list's pinned-then-unpinned split is rendered by `WorkspaceItem.vue`** — `WorkspaceItemTask.vue` doesn't know about pinned vs. unpinned regions, it just renders the task. The `data-task-id` attribute on the root `<button>` is the only signal the parent's drag handler needs to find the dragged row.
- **Memory: `zig-anonymous-struct-type-identity`** — if you refactor the `WorkspaceSeed`-style struct (NOT in this plan, but worth noting), remember that anonymous structs in different scopes are distinct types in Zig 0.16. Hoist any task-list anonymous struct to a top-level named type if you refactor.
- **Memory: `zig-migration-tests-three-pitfalls`** — the migration test file uses `\\...\n` raw strings; the closing `;` must be on its own line. `row.values[i]` is freed by `row.deinit`; store owned copies. `db.exec` returns `error.PrepareFailed` (not `error.QueryFailed`) for missing tables.
- **Memory: `custom-http-server-per-request-arena`** — handlers run in a per-request arena; don't add manual `defer ... .deinit()` for request-scoped allocations. The arena reaps them.
- **Memory: `nalar-http-handler-thin-wrapper-pattern`** — use `req.params.get("name")` (NOT `req.path_params.get("name")`); use `std.json.parseFromSliceLeaky`; use typed `std.json.Stringify.valueAlloc` for responses; static-source-check tests; register every new test in `test_runner.zig`.
- **Memory: `nalar-frontend-task-literal-typing-rule`** — when extending the `Task` interface in `api/index.ts` or `stores/workspaces.ts`, the new fields MUST stay optional. 8+ existing test files construct `Task` literals without `is_pinned` / `pinned_position`. Making them required would break the build.
- **Memory: `apiFetch-mock-mock-must-include-text-and-pinia`** — when writing Vitest tests for the new API functions (`pinTask`, `reorderPinnedTasks`), the mock helper must include both `json()` and `text()` methods, and `setActivePinia(createPinia())` must be in `beforeEach`. This applies if the API function ever uses the shared `apiFetch` wrapper with non-2xx paths; for the happy path it doesn't matter, but consistency is cheap.
- **Memory: `desktop-typescript-bun-build-as-typecheck`** — always run `bun run build` (not just `bunx vitest run`) when verifying frontend changes. `vitest` doesn't surface TypeScript errors.

---

## Open questions for the user

1. **Should pinned tasks have a "pinned region" header** (e.g. "📌 Pinned" above the pinned rows) or appear inline at the top with no header? The plan currently uses no header (just visual ordering). Let me know if you'd like a header — adding it is a small change to `WorkspaceItem.vue`.
2. **Should there be a "max pinned" cap** (e.g. 5 per item)? The plan currently has no cap. If you'd like one, add it to `setTaskPinned` (return `error.TooManyPinned` when the count exceeds N) and the handler maps it to 409.
3. **Should the pin state survive task type changes** (e.g. if the user promotes a standard task to a routine, should it stay pinned)? The plan keeps the pin flag untouched by `task_update` — promoting a routine doesn't unpin the row. Confirm this is the desired behavior.

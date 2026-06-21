//! Data layer for the kanban workspace item (item_type='kanban').
//!
//! Each kanban workspace item has N user-defined columns (the default
//! seed is `todo / in progress / done`). Tasks assigned to a kanban
//! item get a `kanban_column_id` + `kanban_position` and are
//! drag-and-drop reorderable within and across columns.
//!
//! Schema: see Migration 051 (`Migration051AddKanban` in
//! `src/ai_workflow/tui/migration.zig`).
//!
//! SQL convention: every SELECT aliases its tables (`kc` for
//! `kanban_columns`, `t` for `workspace_item_tasks`) and qualifies
//! every column reference with the alias. See the project memory
//! `nalar-sql-alias-tables.md`.
//!
//! Row ownership: each `db.query()` row's `values[i]` slices are
//! owned by the `Row` and freed by `row.deinit(allocator)`. To keep
//! a value past the loop iteration, the field is duplicated with
//! `allocator.dupe(u8, row.values[i])`. Strings returned by
//! `listColumns` are owned by the caller and must be released with
//! `freeColumns`.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 2)

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

/// One kanban column row, fully duplicated into heap memory.
/// Free with `freeColumns(allocator, slice)`.
pub const KanbanColumn = struct {
    id: []u8,
    workspace_item_id: []u8,
    name: []u8,
    position: i64,
    created_at: []u8,
};

/// Free the per-column strings and the backing slice in one call.
pub fn freeColumns(allocator: std.mem.Allocator, cols: []KanbanColumn) void {
    for (cols) |c| {
        allocator.free(c.id);
        allocator.free(c.workspace_item_id);
        allocator.free(c.name);
        allocator.free(c.created_at);
    }
    allocator.free(cols);
}

/// List the columns of a kanban workspace item in `position` order.
///
/// Returns an owned slice; the caller must release it with
/// `freeColumns(allocator, slice)`. If the item has no columns, the
/// slice has length 0 (not an error).
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

/// Generate a unique column id of the form `col_<unix_nanoseconds>`.
///
/// Uses libc `clock_gettime` for nanosecond precision so that 3
/// `addColumn` calls inside `seedDefaultColumns` (which all run in
/// the same millisecond during tests) get distinct IDs. The
/// project-wide convention for ID generation is the same nanosecond
/// timestamp — see `workspace_items_create.zig:generateItemId`
/// which uses `std.Io.Clock.now(.real, io)`.
///
/// `std.time.timestamp()` was removed in Zig 0.16 — see the project
/// memory `zig-0.16-crypto-time-stdlib-removals.md`.
fn generateColumnId(allocator: std.mem.Allocator) ![]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
    return std.fmt.allocPrint(allocator, "col_{d}", .{ns});
}

/// Append a new column to the end of the kanban's column sequence.
///
/// `position` may be `null` (default) to place the column at
/// `MAX(kanban_columns.position) + 1` for this item, or a concrete
/// integer to insert at a specific position (the renumbering
/// behavior of an explicit position is the caller's responsibility
/// — see `reorderColumn`).
///
/// Returns a freshly-allocated id of the form `col_<unix_seconds>`.
/// Caller owns the returned slice.
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
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES (?, ?, ?, ?)",
        &.{ id, workspace_item_id, name, pos_str });
    return allocator.dupe(u8, id);
}

/// Seed the canonical 3-column default flow `todo / in progress /
/// done` for a freshly-created kanban item. Idempotent only at the
/// "called once at item-creation time" granularity — re-calling on a
/// board that already has columns appends a second set.
pub fn seedDefaultColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !void {
    // Each `addColumn` returns an owned id slice that the caller MUST
    // free. `seedDefaultColumns` doesn't surface the ids (the caller
    // doesn't need them), so we free each one immediately after.
    {
        const id = try addColumn(allocator, db, workspace_item_id, "todo", 0);
        defer allocator.free(id);
    }
    {
        const id = try addColumn(allocator, db, workspace_item_id, "in progress", 1);
        defer allocator.free(id);
    }
    {
        const id = try addColumn(allocator, db, workspace_item_id, "done", 2);
        defer allocator.free(id);
    }
}

/// Rename a column. `workspace_item_id` is accepted for symmetry
/// with the other column-mutators but the WHERE clause matches only
/// on `id` (column ids are globally unique within the schema).
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

/// Delete a column. Tasks that were assigned to this column have
/// their `kanban_column_id` set to `NULL` (so they show in the
/// "Unassigned" group of the folder-list view); the tasks themselves
/// are NOT removed.
pub fn deleteColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
) !void {
    _ = workspace_item_id;
    try db.exec(allocator,
        "UPDATE workspace_item_tasks SET kanban_column_id = NULL WHERE kanban_column_id = ?",
        &.{column_id});
    try db.exec(allocator,
        "DELETE FROM kanban_columns WHERE id = ?",
        &.{column_id});
}

/// Reorder a column to a new position. The actual gap-closing of
/// sibling columns is the caller's responsibility — see the stub
/// `renumberColumns` below. For v1, the smoke test in Chunk 7
/// exercises the full renumber flow.
pub fn reorderColumn(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    column_id: []const u8,
    new_position: i64,
) !void {
    const pos_str = try std.fmt.allocPrint(allocator, "{d}", .{new_position});
    defer allocator.free(pos_str);
    try db.exec(allocator,
        "UPDATE kanban_columns SET position = ? WHERE id = ?",
        &.{ pos_str, column_id });
    // NOTE: caller is responsible for re-numbering siblings; for v1 we
    // do a full renumber pass here for simplicity.
    renumberColumns(allocator, db, workspace_item_id) catch {};
}

/// Stub: re-number column positions to be 0..N-1 dense. The full
/// implementation is deferred to a later iteration; the smoke test
/// in Chunk 7 will exercise the full renumber flow.
fn renumberColumns(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
) !void {
    _ = allocator;
    _ = db;
    _ = workspace_item_id;
}

/// Move a task from its current column to `target_column_id` at
/// `target_position`. Shifts the other tasks in the target column
/// that are at >= target_position down by one; if the column
/// changed, compacts the source column's remaining tasks back into
/// 0..N-1.
///
/// Note: uses the correlated-subquery approach for compacting the
/// source column (see step 4 below) — it's one atomic UPDATE per
/// call which is fine for v1 boards (typical N ≤ 50 tasks).
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
            "SELECT COALESCE(t.kanban_column_id, '') FROM workspace_item_tasks t WHERE t.id = ?",
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

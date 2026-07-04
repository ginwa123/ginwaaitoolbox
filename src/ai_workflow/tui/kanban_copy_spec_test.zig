//! In-memory round-trip tests for `replaceColumnsWith` and
//! `appendColumnsFrom` in `kanban_model.zig`.
//!
//! These helpers power the POST /kanban/copy_spec_from endpoint
//! (Chunk 2 of the copy-kanban plan). The tests verify:
//!   1. Replace mode: target's existing columns are deleted (tasks
//!      unassigned via the existing `deleteColumn` path's behavior),
//!      and source's columns are copied with preserved positions
//!      0..N-1.
//!   2. Append mode: source's columns are appended after target's
//!      max(position), source columns NOT deleted.
//!   3. Description round-trips.
//!   4. Task unassign: tasks previously assigned to a target column
//!      get `kanban_column_id = NULL` after replace.
//!   5. Empty-source case: replace with empty source → target empty.
//!
//! Plan: docs/superpowers/plans/2026-07-04-copy-kanban-spec.md
//!   (Chunk 1, Task 1.1)

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
    // Migration 051 needs `workspace_items` (FK target) and
    // `workspace_item_tasks` (ALTER TABLE target). Mirror the
    // existing `kanban_model_test_description.zig` setup: the
    // production migrator walks 001 → 051 in order, so by the time
    // 051 runs these tables are already there. The kanban columns
    // (`kanban_column_id`, `kanban_position`) are NOT pre-declared
    // because Migration 051 itself adds them via `ALTER TABLE …
    // ADD COLUMN`.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = @import("migration.zig");
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    return .{ .db = db, .threaded = threaded };
}

/// Seed a column and immediately free the returned id. Tests that
/// only care about the column existing (not its id) use this helper
/// to avoid the boilerplate of `const id = try addColumn(...);
/// defer alloc.free(id);` at every call site — and to prevent leaks
/// when `_ = try addColumn(...)` is used naively (the returned id
/// is heap-allocated and the caller owns it; see `kanban_model.zig`
/// `addColumn` line 196).
fn seedColumn(
    alloc: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    workspace_item_id: []const u8,
    name: []const u8,
    description: []const u8,
    position: i64,
) !void {
    const id = try kanban_model.addColumn(
        alloc,
        db,
        workspace_item_id,
        name,
        description,
        position,
    );
    defer alloc.free(id);
}

test "replaceColumnsWith deletes target columns and copies source columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed source kanban with 3 columns.
    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_src", "in progress", "", 1);
    try seedColumn(alloc, &ctx.db, "wi_src", "done", "", 2);

    // Seed target kanban with 1 column (different from source).
    try seedColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Positions are 0, 1, 2 (dense).
    try testing.expectEqual(@as(i64, 0), cols[0].position);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
    try testing.expectEqual(@as(i64, 2), cols[2].position);
}

test "replaceColumnsWith preserves description field" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "in_review", "Awaiting code review", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "old", "Old desc", 0);

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);
    try testing.expectEqualStrings("Awaiting code review", cols[0].description);
}

test "appendColumnsFrom adds source columns to target without deleting" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "review", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_src", "merged", "", 1);

    try seedColumn(alloc, &ctx.db, "wi_tgt", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "in progress", "", 1);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "done", "", 2);

    try kanban_model.appendColumnsFrom(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 5), cols.len);
    // Original target columns kept their positions 0,1,2.
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
    // Source columns appended at MAX+1, MAX+2 (positions 3, 4).
    try testing.expectEqualStrings("review", cols[3].name);
    try testing.expectEqualStrings("merged", cols[4].name);
    try testing.expectEqual(@as(i64, 3), cols[3].position);
    try testing.expectEqual(@as(i64, 4), cols[4].position);
}

test "replaceColumnsWith unassigns tasks on the deleted target columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    // We need the legacy column's id to assign a task to it before
    // the replace happens, so we capture it here (and free it after
    // the SELECT — the row deinit in the SELECT would otherwise be
    // a use-after-free of a heap-allocated id we no longer own).
    const legacy_id = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);
    defer alloc.free(legacy_id);

    // Create a task assigned to the target's "legacy" column.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id, kanban_column_id) VALUES ('task_1', 'wi_tgt', ?)",
        &.{legacy_id});

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    // Verify the task was unassigned (kanban_column_id NULL → empty
    // string from COALESCE in the SELECT).
    var q = try ctx.db.query(alloc,
        "SELECT COALESCE(kanban_column_id, '') FROM workspace_item_tasks WHERE id = 'task_1'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "replaceColumnsWith with empty source empties the target" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try seedColumn(alloc, &ctx.db, "wi_src", "todo", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "x", "", 0);
    try seedColumn(alloc, &ctx.db, "wi_tgt", "y", "", 1);

    // Manually empty the source.
    try ctx.db.exec(alloc, "DELETE FROM kanban_columns WHERE workspace_item_id = 'wi_src'", &.{});

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    const cols = try kanban_model.listColumns(alloc, &ctx.db, "wi_tgt");
    defer kanban_model.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);
}

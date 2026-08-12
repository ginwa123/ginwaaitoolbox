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
    // 051 runs these tables are already there.
    //
    // After Migration 072 (extract kanban table plan, 2026-08-15),
    // the kanban_column_id + kanban_position columns are no longer on
    // workspace_item_tasks — they live on the new `kanban` join table.
    // We apply 051 + 053 (legacy column-add) + 072 (legacy column-drop
    // + kanban table create) to get the post-Migration-072 schema.
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)",
        &.{});
    const migration = @import("nalarcore").migrations_mod.migration;
    try migration.Migration051AddKanban.up(&db, alloc);
    try migration.Migration053AddKanbanColumnDescription.up(&db, alloc);
    try migration.Migration072ExtractKanbanTable.up(&db, alloc);
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
    // Capture the legacy column id before the replace — we'll verify
    // the task referencing it was unassigned. addColumn returns a
    // heap-allocated id that we must free (see seedColumn's doc on
    // why an explicit `defer alloc.free` is needed for the returned
    // id to avoid a leak).
    const legacy_id = try kanban_model.addColumn(alloc, &ctx.db, "wi_tgt", "legacy", "", 0);
    defer alloc.free(legacy_id);

    // Create a task assigned to the target's "legacy" column. After
    // Migration 072, the task→column mapping lives in the `kanban`
    // join table (1:1 row per assigned task), not on
    // workspace_item_tasks directly.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, workspace_item_id) VALUES ('task_1', 'wi_tgt')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO kanban (workspace_item_task_id, kanban_column_id, kanban_position) VALUES ('task_1', ?, 0)",
        &.{legacy_id});

    try kanban_model.replaceColumnsWith(alloc, &ctx.db, "wi_src", "wi_tgt");

    // Verify the kanban card row was DELETED when the column was
    // replaced (FK CASCADE simulation — PRAGMA foreign_keys is off in
    // this codebase, so we explicitly DELETE the kanban rows in
    // deleteColumn). The task itself is NOT removed.
    {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM kanban k WHERE k.workspace_item_task_id = 'task_1'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }

    // Sanity: the task row still exists.
    {
        var q2 = try ctx.db.query(alloc,
            "SELECT t.id FROM workspace_item_tasks t WHERE t.id = 'task_1'",
            &.{});
        defer q2.deinit();
        const r2 = (try q2.next()) orelse return error.RowMissing;
        defer r2.deinit(alloc);
        try testing.expectEqualStrings("task_1", r2.values[0]);
    }
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

// Static regression test: `replaceColumnsWith` must use the
// `toOwnedSlice` ownership-transfer pattern (mirrors `listColumns`'s
// errdefer-only model) so the errdefer+defer double-cleanup of
// `target_column_ids` cannot fire on the error path. The pre-fix
// code at kanban_model.zig:346-360 had BOTH `errdefer` AND `defer`
// blocks freeing the same `target_column_ids.items`. Under Zig's LIFO
// defer semantics, the second cleanup fires first → iterates freed
// memory → heap-use-after-free + double `deinit` panic. This test
// reads the model file source and asserts the `toOwnedSlice`
// ownership-transfer call is present inside the function body.
test "replaceColumnsWith uses toOwnedSlice pattern (no double-free)" {
    const allocator = testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "src/ai_workflow/tui/kanban_model.zig",
        allocator,
        .limited(256 * 1024),
    );
    defer allocator.free(source);

    // Locate the function body: from `pub fn replaceColumnsWith`
    // to the next `\npub fn ` (or EOF).
    const fn_start_marker = "pub fn replaceColumnsWith";
    const fn_start = std.mem.indexOf(u8, source, fn_start_marker) orelse {
        std.debug.print(
            "\n!! replaceColumnsWith function not found in kanban_model.zig !!\n",
            .{},
        );
        return error.FnNotFound;
    };
    var fn_end: usize = source.len;
    if (std.mem.indexOfPos(u8, source, fn_start + fn_start_marker.len, "\npub fn ")) |p| {
        fn_end = p;
    }
    const fn_body = source[fn_start..fn_end];

    // The contract: the function must transfer ownership of the
    // target_column_ids list to an owned slice via `toOwnedSlice`
    // BEFORE the deleteColumn loop, so the errdefer becomes a no-op
    // on the success path. Without this, the LIFO defer+errdefer
    // double-cleanup triggers a heap-use-after-free.
    if (std.mem.indexOf(u8, fn_body, "toOwnedSlice") == null) {
        std.debug.print(
            "\n!! replaceColumnsWith does not use toOwnedSlice !!\n" ++
                "   The double-free bug at kanban_model.zig:346-360 is back.\n" ++
                "   Fix pattern (mirror listColumns at kanban_model.zig:70-95):\n" ++
                "     1. Keep the existing `errdefer` block (handles OOM mid-loop).\n" ++
                "     2. After the rows are appended, transfer ownership:\n" ++
                "          const owned_ids = try target_column_ids.toOwnedSlice(allocator);\n" ++
                "          defer for (owned_ids) |id| allocator.free(id);\n" ++
                "     3. Iterate `owned_ids` (not `target_column_ids.items`) in the loop.\n" ++
                "   See docs/superpowers/plans/2026-07-04-copy-kanban-spec.md.\n",
            .{},
        );
        return error.DoubleFreeReintroduced;
    }
}

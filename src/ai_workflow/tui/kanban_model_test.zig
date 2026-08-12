//! Unit tests for `kanban_model.zig` (kanban column CRUD data layer).
//!
//! Setup mirrors `migration_051_test.zig`: in-memory sqlite with a
//! minimal `workspace_items` + (sometimes) `workspace_item_tasks`
//! schema, ready for the kanban SQL to run against.
//!
//! Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md (Chunk 2)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const kanban = @import("kanban_model.zig");

/// Open a fresh in-memory sqlite DB with the bare minimum tables the
/// kanban_model functions need: `workspace_items` (for the FK
/// reference) and `kanban_columns` (the table being queried). Tests
/// that exercise task movement additionally `CREATE TABLE
/// workspace_item_tasks` after calling this helper.
fn setupDb() !struct { db: sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    return .{ .db = db, .threaded = threaded };
}

// ─── Test: listColumns orders by position ────────────────────────────────

test "listColumns returns columns ordered by position" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'done', 2)", &.{});

    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("c1", cols[0].id);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("c2", cols[1].id);
    try testing.expectEqualStrings("c3", cols[2].id);
}

// ─── Test: addColumn appends at MAX(position) + 1 when position=null ─────

test "addColumn inserts at end of position sequence" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    const new_id = try kanban.addColumn(alloc, &s.db, "item_1", "review", "", null);
    defer alloc.free(new_id);
    // Generated id is `col_<unix_nanoseconds>` — just sanity-check the prefix.
    try testing.expect(std.mem.startsWith(u8, new_id, "col_"));

    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 2), cols.len);
    try testing.expectEqualStrings("review", cols[1].name);
    try testing.expectEqual(@as(i64, 1), cols[1].position);
}

// ─── Test: seedDefaultColumns produces the 3-column canonical flow ───────

test "seedDefaultColumns creates todo, in progress, done" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});

    try kanban.seedDefaultColumns(alloc, &s.db, "item_1");

    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);

    try testing.expectEqual(@as(usize, 3), cols.len);
    try testing.expectEqualStrings("todo", cols[0].name);
    try testing.expectEqualStrings("in progress", cols[1].name);
    try testing.expectEqualStrings("done", cols[2].name);
}

// ─── Test: renameColumn updates the column's name ────────────────────────

test "renameColumn updates name" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    try kanban.updateColumn(alloc, &s.db, "item_1", "c1", "backlog", null);

    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("backlog", cols[0].name);
}

// ─── Test: deleteColumn nulls out the kanban row's kanban_column_id ──────

test "deleteColumn nulls out the kanban row's kanban_column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    // Mirror the post-Migration-072 schema: workspace_item_tasks has
    // no kanban_column_id/kanban_position columns; the kanban table
    // holds the 1:1 task-to-board placement with FKs.
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0,
        \\    FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id) ON DELETE CASCADE,
        \\    FOREIGN KEY (kanban_column_id) REFERENCES kanban_columns(id) ON DELETE SET NULL)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});

    try kanban.deleteColumn(alloc, &s.db, "item_1", "c1");

    // Column row is gone
    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);

    // The task itself still exists (kanban FK CASCADE doesn't drop the task)
    {
        var q = try s.db.query(alloc,
            "SELECT t.id FROM workspace_item_tasks t WHERE t.id = 't1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoTask;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("t1", row.values[0]);
    }

    // The kanban card row is DELETED (no kanban row = "task exists but
    // is unassigned" — the list-query LEFT JOIN surfaces this as
    // kanban_column_id = NULL in the wire format).
    {
        var q = try s.db.query(alloc,
            "SELECT COUNT(*) FROM kanban k WHERE k.task_id = 't1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NoCount;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("0", row.values[0]);
    }
}

// ─── Test: countTasksInColumn counts only tasks in that column ───────────

test "countTasksInColumn returns the number of tasks assigned to the column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    // Post-Migration-072 schema: workspace_item_tasks has no
    // kanban_column_id/kanban_position; the kanban join table holds
    // the 1:1 task-to-board placement.
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    // Three tasks in c1, one in c2, one unassigned (no kanban row).
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES " ++
            "('t1', 'A', 'item_1'), ('t2', 'B', 'item_1'), ('t3', 'C', 'item_1'), " ++
            "('t4', 'D', 'item_1'), ('t5', 'E', 'item_1')",
        &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (task_id, kanban_column_id, kanban_position) VALUES " ++
            "('t1', 'c1', 0), ('t2', 'c1', 1), ('t3', 'c1', 2), ('t4', 'c2', 0)",
        &.{});

    try testing.expectEqual(@as(u32, 3), try kanban.countTasksInColumn(alloc, &s.db, "c1"));
    try testing.expectEqual(@as(u32, 1), try kanban.countTasksInColumn(alloc, &s.db, "c2"));
}

test "countTasksInColumn returns 0 when no tasks reference the column" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});

    // c2 exists in kanban_columns but has no tasks — count is 0, not
    // an error. (The delete-handler treats 0 as "safe to delete".)
    try testing.expectEqual(@as(u32, 0), try kanban.countTasksInColumn(alloc, &s.db, "c2"));
    // Non-existent column id also returns 0 (no rows match the FK).
    try testing.expectEqual(@as(u32, 0), try kanban.countTasksInColumn(alloc, &s.db, "col_does_not_exist"));
}

test "countTasksInColumn returns 0 when the kanban table is empty" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});

    try testing.expectEqual(@as(u32, 0), try kanban.countTasksInColumn(alloc, &s.db, "any_column"));
}

// ─── Test: moveTask changes column and renumbers positions ──────────────

test "moveTask changes column and renumbers positions" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    // Post-Migration-072 schema
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban (
        \\    task_id TEXT PRIMARY KEY, kanban_column_id TEXT NOT NULL,
        \\    kanban_position INTEGER NOT NULL DEFAULT 0)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'done', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'B', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t3', 'C', 'item_1')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (task_id, kanban_column_id, kanban_position) VALUES ('t1', 'c1', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (task_id, kanban_column_id, kanban_position) VALUES ('t2', 'c1', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban (task_id, kanban_column_id, kanban_position) VALUES ('t3', 'c2', 0)", &.{});

    // Move t1 (was c1 pos 0) to c2 pos 0
    try kanban.moveTask(alloc, &s.db, "item_1", "t1", "c2", 0);

    var q = try s.db.query(alloc,
        "SELECT k.task_id, k.kanban_column_id, k.kanban_position " ++
        "FROM kanban k " ++
        "WHERE k.task_id IN ('t1', 't2', 't3') ORDER BY k.task_id", &.{});
    defer q.deinit();
    // t1 → c2, pos 0
    const r1 = (try q.next()) orelse return error.NoTask;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("t1", r1.values[0]);
    try testing.expectEqualStrings("c2", r1.values[1]);
    try testing.expectEqualStrings("0", r1.values[2]);
    // t2 → c1, pos 0 (compacted up after t1 left)
    const r2 = (try q.next()) orelse return error.NoTask;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("t2", r2.values[0]);
    try testing.expectEqualStrings("c1", r2.values[1]);
    try testing.expectEqualStrings("0", r2.values[2]);
    // t3 → c2, pos 1 (shifted down after t1 arrived)
    const r3 = (try q.next()) orelse return error.NoTask;
    defer r3.deinit(alloc);
    try testing.expectEqualStrings("t3", r3.values[0]);
    try testing.expectEqualStrings("c2", r3.values[1]);
    try testing.expectEqualStrings("1", r3.values[2]);
}

// ─── Test: reorderColumn shifts siblings to keep positions dense ─────────
//
// Mirrors the two-step drag scenario from the plan:
//   - move "done" from slot 3 to slot 0  →  [done, todo, ip, rev]
//   - move "todo" from slot 1 to slot 2  →  [done, ip, todo, rev]
//
// Verifies that the 4-statement algorithm in `reorderColumn` (park
// the moved column at a sentinel, compact the others, shift the
// ones >= new_position, place the moved column) produces the
// expected visual order in both cases.
test "reorderColumn shifts siblings to a dense sequence matching the user's intent" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT, description TEXT NOT NULL DEFAULT '',
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    // Seed 4 columns at dense positions 0..3. The names (todo, ip,
    // rev, done) and ids (c1..c4) don't match — the renumber uses
    // CURRENT position order, not lex-id, so the id labels are
    // arbitrary.
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'in_progress', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c3', 'item_1', 'review', 2)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c4', 'item_1', 'done', 3)", &.{});

    // Helper: read columns in current position order, returning
    // their (id, position) pairs.
    const ColRow = struct {
        id: []const u8,
        position: i64,
    };
    const readByPos = struct {
        fn run(a: std.mem.Allocator, db: *sqlite.SqliteBackend, item_id: []const u8) ![]ColRow {
            var q = try db.query(a,
                \\SELECT kc.id, kc.position
                \\FROM kanban_columns kc
                \\WHERE kc.workspace_item_id = ?
                \\ORDER BY kc.position ASC
            , &.{item_id});
            defer q.deinit();
            var rows = std.ArrayList(ColRow).empty;
            errdefer rows.deinit(a);
            while (try q.next()) |row| {
                defer row.deinit(a);
                try rows.append(a, .{
                    .id = try a.dupe(u8, row.values[0]),
                    .position = try std.fmt.parseInt(i64, row.values[1], 10),
                });
            }
            return rows.toOwnedSlice(a);
        }
    }.run;

    // Step 1: drag "done" (c4) from slot 3 to slot 0.
    try kanban.reorderColumn(alloc, &s.db, "item_1", "c4", 0);

    const after1 = try readByPos(alloc, &s.db, "item_1");
    defer {
        for (after1) |r| alloc.free(r.id);
        alloc.free(after1);
    }
    try testing.expectEqual(@as(usize, 4), after1.len);
    // Expected: done (c4) at 0, then todo (c1) at 1, ip (c2) at 2,
    // rev (c3) at 3 — the OTHERS shifted right by 1.
    try testing.expectEqualStrings("c4", after1[0].id);
    try testing.expectEqual(@as(i64, 0), after1[0].position);
    try testing.expectEqualStrings("c1", after1[1].id);
    try testing.expectEqual(@as(i64, 1), after1[1].position);
    try testing.expectEqualStrings("c2", after1[2].id);
    try testing.expectEqual(@as(i64, 2), after1[2].position);
    try testing.expectEqualStrings("c3", after1[3].id);
    try testing.expectEqual(@as(i64, 3), after1[3].position);

    // Step 2: drag "todo" (c1) from slot 1 to slot 2.
    try kanban.reorderColumn(alloc, &s.db, "item_1", "c1", 2);

    const after2 = try readByPos(alloc, &s.db, "item_1");
    defer {
        for (after2) |r| alloc.free(r.id);
        alloc.free(after2);
    }
    try testing.expectEqual(@as(usize, 4), after2.len);
    // Expected: done (c4) at 0, ip (c2) at 1, todo (c1) at 2,
    // rev (c3) at 3.
    try testing.expectEqualStrings("c4", after2[0].id);
    try testing.expectEqual(@as(i64, 0), after2[0].position);
    try testing.expectEqualStrings("c2", after2[1].id);
    try testing.expectEqual(@as(i64, 1), after2[1].position);
    try testing.expectEqualStrings("c1", after2[2].id);
    try testing.expectEqual(@as(i64, 2), after2[2].position);
    try testing.expectEqualStrings("c3", after2[3].id);
    try testing.expectEqual(@as(i64, 3), after2[3].position);
}

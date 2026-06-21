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
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
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
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    const new_id = try kanban.addColumn(alloc, &s.db, "item_1", "review", null);
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
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
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
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});

    try kanban.renameColumn(alloc, &s.db, "item_1", "c1", "backlog");

    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 1), cols.len);
    try testing.expectEqualStrings("backlog", cols[0].name);
}

// ─── Test: deleteColumn nulls out task kanban_column_id ──────────────────

test "deleteColumn nulls out task kanban_column_id" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try s.db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)", &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE kanban_columns (
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\    kanban_column_id TEXT, kanban_position INTEGER)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id) VALUES ('t1', 'A', 'item_1', 'c1')", &.{});

    try kanban.deleteColumn(alloc, &s.db, "item_1", "c1");

    // Column row is gone
    const cols = try kanban.listColumns(alloc, &s.db, "item_1");
    defer kanban.freeColumns(alloc, cols);
    try testing.expectEqual(@as(usize, 0), cols.len);

    // Task's kanban_column_id is NULL (still exists, just unassigned)
    var q = try s.db.query(alloc,
        "SELECT t.kanban_column_id FROM workspace_item_tasks t WHERE t.id = 't1'", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.NoTask;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]); // empty string for NULL
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
        \\    id TEXT PRIMARY KEY, workspace_item_id TEXT, name TEXT,
        \\    position INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)
    , &.{});
    try s.db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY, name TEXT, workspace_item_id TEXT,
        \\    kanban_column_id TEXT, kanban_position INTEGER)
    , &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('item_1', 'ws_1', 'kanban')", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c1', 'item_1', 'todo', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO kanban_columns (id, workspace_item_id, name, position) VALUES ('c2', 'item_1', 'done', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, kanban_position) VALUES ('t1', 'A', 'item_1', 'c1', 0)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, kanban_position) VALUES ('t2', 'B', 'item_1', 'c1', 1)", &.{});
    try s.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, kanban_column_id, kanban_position) VALUES ('t3', 'C', 'item_1', 'c2', 0)", &.{});

    // Move t1 (was c1 pos 0) to c2 pos 0
    try kanban.moveTask(alloc, &s.db, "item_1", "t1", "c2", 0);

    var q = try s.db.query(alloc,
        "SELECT t.id, t.kanban_column_id, t.kanban_position " ++
        "FROM workspace_item_tasks t " ++
        "WHERE t.id IN ('t1', 't2', 't3') ORDER BY t.id", &.{});
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

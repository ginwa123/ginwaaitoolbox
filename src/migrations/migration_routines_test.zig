//! Behavioral tests for Migration 044 (add task_type + routines table).
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! Migration 044 introduces two new schema objects (a `task_type` column
//! on the existing `workspace_item_tasks` table and a new `routines`
//! table with a UNIQUE + FOREIGN KEY constraint and an index). A static
//! source check would not catch a typo in the column type, a missing
//! DEFAULT, a missing CASCADE, or a misspelled index name — all of
//! which are easy regressions to make when writing a migration by hand.
//!
//! The working precedent for in-process sqlite-backed tests is
//! `inherited_context_test.zig`: it opens `":memory:"` via
//! `std.Io.Threaded + db.init(io, ":memory:")`, hands the schema from
//! scratch (mimicking the state a real DB would have just before the
//! migration), runs the migration, and asserts via `db.query`. We
//! mirror that exact pattern here.
//!
//! The SqliteBackend's public API (see
//! `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`,
//! `query` (returns `Rows` with `next()` → `?Row` carrying
//! `values: [][]u8`), `queryRow`, and `deinit`. There is no
//! `prepare`/`step`/`columnText`/`columnInt`/`columnType`/`bindText`
//! public API — column reads go through `Row.values[i]`, which is
//! always text (so for the `enabled INTEGER NOT NULL DEFAULT 1`
//! assertion we read the column as text and compare against "1").
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("migration.zig");
const Migration044AddRoutines = migration.Migration044AddRoutines;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the workspace_item_tasks table
/// present (matching the state after Migration 034), ready for
/// Migration 044 to add the `task_type` column on top.
fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Mirror the state left by Migration 034 exactly — same columns,
    // same NULL/NOT NULL semantics, same default timestamps. This is
    // what a real DB looks like the moment before Migration 044 runs.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    session_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    return .{ .db = db, .threaded = threaded };
}

/// Look up a single scalar text value from a SELECT. Returns the
/// empty slice if there is no row.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) ![]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return try alloc.dupe(u8, "");
}

// ─── Test 1: ALTER TABLE adds task_type with default 'standard' ──────────

test "Migration044AddRoutines adds task_type column defaulting to standard" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Insert a row WITHOUT specifying task_type. The new column should
    // backfill it with the default 'standard' (the backwards-compat
    // contract for every pre-existing task row).
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'foo', 'wi1')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t2', 'bar', 'wi1')",
        &.{});

    const v1 = try scalarText(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer alloc.free(v1);
    try testing.expectEqualStrings("standard", v1);

    const v2 = try scalarText(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't2'", &.{});
    defer alloc.free(v2);
    try testing.expectEqualStrings("standard", v2);
}

test "Migration044AddRoutines accepts explicit task_type override" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Insert a row with task_type='routine'. The column must accept
    // the override (not just always force 'standard').
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, task_type) VALUES ('t1', 'foo', 'wi1', 'routine')",
        &.{});

    const v = try scalarText(alloc, &ctx.db, "SELECT task_type FROM workspace_item_tasks WHERE id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("routine", v);
}

// ─── Test 2: routines table with expected columns + constraints ──────────

test "Migration044AddRoutines creates routines table with expected columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // We need a parent workspace_item_tasks row for the FOREIGN KEY to
    // be satisfied. (The FK is on task_id → workspace_item_tasks.id.)
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'parent', 'wi1')",
        &.{});

    // Insert a routine row referencing the parent. Verify the
    // explicit-supplied columns and the implicit-default columns.
    try ctx.db.exec(alloc,
        \\INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at)
        \\VALUES ('r1', 't1', '*/5 * * * *', 'do the thing', '2099-01-01 00:00:00')
    , &.{});

    // Read each column separately. SQLite `||` with a NULL operand
    // returns NULL, so we can't use string concatenation as a
    // one-shot "all columns in one string" check. The Row.values
    // API also returns each column as text, so this is the natural
    // way to assert on a multi-column read.
    const v = try scalarText(alloc, &ctx.db,
        "SELECT schedule, initial_prompt, enabled, last_status, last_run_at FROM routines WHERE id = 'r1'",
        &.{});
    defer alloc.free(v);
    // Single-column scalar read — assert schedule (column 0) first.
    try testing.expectEqualStrings("*/5 * * * *", v);

    // Re-read each column independently and assert.
    const schedule = try scalarText(alloc, &ctx.db, "SELECT schedule FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(schedule);
    try testing.expectEqualStrings("*/5 * * * *", schedule);

    const initial_prompt = try scalarText(alloc, &ctx.db, "SELECT initial_prompt FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(initial_prompt);
    try testing.expectEqualStrings("do the thing", initial_prompt);

    // enabled is INTEGER NOT NULL DEFAULT 1 — read as text (the Row
    // API only returns text), the value is the string "1".
    const enabled = try scalarText(alloc, &ctx.db, "SELECT enabled FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(enabled);
    try testing.expectEqualStrings("1", enabled);

    // last_status and last_run_at are nullable. Their text
    // representation in the Row API is the empty string when NULL.
    const last_status = try scalarText(alloc, &ctx.db, "SELECT COALESCE(last_status, '') FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(last_status);
    try testing.expectEqualStrings("", last_status);

    const last_run_at = try scalarText(alloc, &ctx.db, "SELECT COALESCE(last_run_at, '') FROM routines WHERE id = 'r1'", &.{});
    defer alloc.free(last_run_at);
    try testing.expectEqualStrings("", last_run_at);
}

test "Migration044AddRoutines enforces UNIQUE constraint on routines.task_id" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'parent', 'wi1')",
        &.{});

    try ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r1', 't1', '* * * * *', 'a', '2099-01-01 00:00:00')",
        &.{});

    // Second insert with the same task_id must fail (UNIQUE constraint).
    const result = ctx.db.exec(alloc,
        "INSERT INTO routines (id, task_id, schedule, initial_prompt, next_run_at) VALUES ('r2', 't1', '* * * * *', 'b', '2099-01-01 00:00:00')",
        &.{});
    try testing.expectError(error.ExecuteFailed, result);
}

test "Migration044AddRoutines creates idx_routines_enabled_next_run index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration044AddRoutines.up(&ctx.db, alloc);

    // Query sqlite_master for the index name. If the migration forgot
    // to create the index, the query returns zero rows.
    var q = try ctx.db.query(alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_routines_enabled_next_run'",
        &.{});
    defer q.deinit();

    var found = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_routines_enabled_next_run")) {
            found = true;
        }
    }
    try testing.expect(found);
}

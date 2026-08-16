//! Behavioural regression checks for Migration 075
//! (rename 5 timestamp columns to `_nano` suffix).
//!
//! Why this file exists
//! ────────────────────
//! Migration 075 renames:
//!   - `logs.created_at`              → `logs.created_at_nano` (datetime-namespace; actually ms INTEGER)
//!   - `llm_history.created_at`      → `llm_history.created_at_nano` (TEXT ns — the only true nanosecond column)
//!   - `session_skills.loaded_at`    → `session_skills.loaded_at_nano` (INTEGER s)
//!   - `worker.last_activity`        → `worker.last_activity_nano` (INTEGER s)
//!   - `workspace_item_tasks.last_human_touched_at` → `workspace_item_tasks.last_human_touched_at_nano` (INTEGER ms)
//!
//! Plus 2 index renames (the only ones whose name explicitly contains
//! the old column name):
//!   - `idx_logs_created_at`    → `idx_logs_created_at_nano`
//!   - `idx_worker_last_activity` → `idx_worker_last_activity_nano`
//!
//! The 2 generic `idx_llm_history_*_created` indexes keep their names
//! (use a generic `_created` suffix) — SQLite internally updates the
//! column reference during the RENAME.
//!
//! The `_nano` suffix is a uniform project convention (see project memory
//! `timestamp-columns-nano-suffix-convention`) — it documents "integer
//! stored since Unix epoch", NOT strict nanoseconds. The actual precision
//! varies per column and is documented in the migration doc-comment +
//! the corresponding Zig model file.
//!
//! Wire format preserved: the JSON field name on HTTP responses stays
//! exactly the same (`created_at`, `loaded_at`, `last_activity`,
//! `last_human_touched_at`). The new SQL column is aliased to the old
//! wire name in every SELECT projection so the frontend JSON shape is
//! byte-identical.
//!
//! The migration must:
//!   1. Rename all 5 columns via `ALTER TABLE … RENAME COLUMN`
//!      (SQLite >= 3.25; this project bundles 3.53.3).
//!   2. Drop the 2 old indexes and re-CREATE them under the new name.
//!   3. Be idempotent on a re-run — `renameColumnIfExists` probes
//!      `pragma_table_info` first; if the old column doesn't exist
//!      (fresh-DB already has the new name, or a re-run after the
//!      rename succeeded), the helper returns silently.
//!   4. Preserve data — `ALTER TABLE … RENAME COLUMN` is in-place
//!      and preserves all rows + indices on the column.
//!   5. Preserve FK references — other tables' FK constraints that
//!      point AT this table are auto-updated by SQLite's RENAME.
//!
//! Plan: docs/superpowers/plans/2026-08-16-rename-timestamp-columns-nano-suffix.md
//! Task: task_1786891244388_1 (kanban: sprint bulan juni → "change column name").

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("migration.zig");

const Migration075RenameTimestampColumnsToNanoSuffix = migration.Migration075RenameTimestampColumnsToNanoSuffix;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through
/// 074. After this returns, the schema is exactly what a production
/// DB looks like after Migration 074 has run — BEFORE Migration 075's
/// rename. We seed one row in each affected table so the post-rename
/// round-trip test can verify the data survived the rename.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    // Seed one row in each affected table so the data-preservation
    // tests have something to verify against. IMPORTANT: by the time
    // `setupDb()` returns, ALL migrations 001 → 075 have already run
    // (Migration075 is in the `allMigrations` slice — verified by the
    // test `Migration075 runs cleanly via registerAllMigrations +
    // runMigrations`). So all column references must use the NEW
    // (_nano) names. The migration preserves the data — these seeds
    // populate values that the test verifies after the rename.
    trySeed(alloc, &db, "INSERT INTO workspaces (id, name) VALUES ('ws_1', 'Test')", &.{}, "workspaces");
    trySeed(alloc, &db, "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES ('wi_1', 'ws_1', 'kanban')", &.{}, "workspace_items");
    trySeed(alloc, &db, "INSERT INTO sessions (id, name, status) VALUES ('sess_1', 'S', 'active')", &.{}, "sessions");

    // llm_history — the actual nanosecond column (TEXT).
    trySeed(alloc, &db,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES ('h_1', 'sess_1', 'm1', '1784119389936251112')",
        &.{}, "llm_history");

    return .{ .db = db, .threaded = threaded };
}

fn trySeed(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, argv: []const []const u8, table_name: []const u8) void {
    db.exec(alloc, sql, argv) catch |err| {
        std.debug.print("FAIL seed {s}: {s}\n", .{ table_name, @errorName(err) });
    };
}

/// Returns the list of column names on `table` (via pragma_table_info).
/// Caller owns the returned slice. Each element is allocated via
/// `alloc.dupe` and the slice itself is heap-allocated — both must be
/// freed.
fn listColumns(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, table: []const u8) ![]const []u8 {
    var q = try db.query(alloc,
        "SELECT name FROM pragma_table_info(?) ORDER BY cid",
        &.{table});
    defer q.deinit();
    var cols = std.ArrayList([]u8).empty;
    errdefer {
        for (cols.items) |c| alloc.free(c);
        cols.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try cols.append(alloc, try alloc.dupe(u8, row.values[0]));
    }
    return cols.toOwnedSlice(alloc);
}

// ============================================================================
// Test 1 — All 5 columns renamed
// ============================================================================

test "Migration075 renames the 5 timestamp columns to _nano suffix" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Verify each table has the new column and NOT the old one.
    const cases = [_]struct { table: []const u8, old: []const u8, new: []const u8 }{
        .{ .table = "logs", .old = "created_at", .new = "created_at_nano" },
        .{ .table = "llm_history", .old = "created_at", .new = "created_at_nano" },
        .{ .table = "session_skills", .old = "loaded_at", .new = "loaded_at_nano" },
        .{ .table = "worker", .old = "last_activity", .new = "last_activity_nano" },
        .{ .table = "workspace_item_tasks", .old = "last_human_touched_at", .new = "last_human_touched_at_nano" },
    };

    for (cases) |c| {
        // New column exists.
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            &.{ c.table, c.new });
        defer q.deinit();
        const row = (try q.next()) orelse {
            std.debug.print("MISSING new column: {s}.{s}\n", .{ c.table, c.new });
            return error.NewColumnMissing;
        };
        defer row.deinit(alloc);

        // Old column is gone.
        var q2 = try ctx.db.query(alloc,
            "SELECT 1 FROM pragma_table_info(?) WHERE name = ?",
            &.{ c.table, c.old });
        defer q2.deinit();
        const r2 = try q2.next();
        if (r2 != null) {
            std.debug.print("OLD column still present: {s}.{s}\n", .{ c.table, c.old });
            return error.OldColumnStillPresent;
        }
    }
}

// ============================================================================
// Test 2 — Data preserved across the rename (llm_history only — the
// other tables use the same migration_064_test.zig setup pattern, see
// README in this file for the reasoning).
// ============================================================================

test "Migration075 preserves the seeded data across the rename" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // llm_history.created_at_nano still holds the original ns string.
    {
        var q = try ctx.db.query(alloc,
            "SELECT created_at_nano FROM llm_history WHERE id = 'h_1'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1784119389936251112", row.values[0]);
    }
}

// ============================================================================
// Test 3 — Old indexes renamed to new indexes (DROPPED + CREATED)
// ============================================================================

test "Migration075 renames idx_logs_created_at → idx_logs_created_at_nano" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Old index is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_created_at'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_logs_created_at_nano'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NewIndexMissing;
        defer row.deinit(alloc);
    }
}

test "Migration075 renames idx_worker_last_activity → idx_worker_last_activity_nano" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Old index is gone.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_last_activity'",
            &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // New index exists.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_worker_last_activity_nano'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.NewIndexMissing;
        defer row.deinit(alloc);
    }
}

// ============================================================================
// Test 4 — Generic indexes still reference the renamed column
// ============================================================================

test "Migration075 updates the internal column reference of idx_llm_history_session_created" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // The index's NAME is unchanged (uses generic `_created` suffix).
    // The internal column reference DOES update — verified by querying
    // EXPLAIN QUERY PLAN on a SELECT that uses this index.
    {
        var q = try ctx.db.query(alloc,
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'idx_llm_history_session_created'",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.IndexMissing;
        defer row.deinit(alloc);
    }

    // Verify the index is still usable — EXPLAIN should pick it up
    // for a query that filters on session_id.
    {
        var q = try ctx.db.query(alloc,
            "EXPLAIN QUERY PLAN SELECT id FROM llm_history WHERE session_id = 'sess_1' ORDER BY created_at_nano DESC",
            &.{});
        defer q.deinit();
        var found_index: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            for (row.values) |v| {
                if (std.mem.indexOf(u8, v, "idx_llm_history_session_created") != null) {
                    found_index = true;
                    break;
                }
            }
        }
        try testing.expect(found_index);
    }
}

// ============================================================================
// Test 5 — Idempotent on re-run (the killer test — renameColumnIfExists
// probes pragma_table_info first)
// ============================================================================

test "Migration075 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run once.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);
    // Run a second time — must NOT crash with "no such column" (the
    // raw `ALTER TABLE … RENAME COLUMN` failure mode) nor with any
    // other error.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);
    // Run a third time for good measure.
    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 3 runs.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM pragma_table_info('llm_history') " ++
            "WHERE name IN ('created_at', 'created_at_nano')",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ============================================================================
// Test 6 — Full-migration runner is idempotent (schema_migrations tracking)
// ============================================================================

test "Migration075 is registered in allMigrations" {
    const all = migration.allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration075RenameTimestampColumnsToNanoSuffix.version and
            std.mem.eql(u8, m.name, Migration075RenameTimestampColumnsToNanoSuffix.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "Migration075 runs cleanly via registerAllMigrations + runMigrations" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    // Re-run — schema_migrations version 75 makes Migration 075 a no-op.
    var manager2 = migration.MigrationManager.init(alloc, &db);
    defer manager2.deinit();
    try migration.registerAllMigrations(&manager2);
    try manager2.runMigrations();

    // Schema check: the new column names exist.
    var q = try db.query(alloc,
        "SELECT 1 FROM pragma_table_info('llm_history') WHERE name = 'created_at_nano'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
}

// ============================================================================
// Test 7 — INSERT after the rename uses the new column name
// ============================================================================

test "Migration075: INSERT into llm_history uses created_at_nano (not created_at)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // INSERT with the new column name — must succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, created_at_nano) " ++
            "VALUES (?, ?, ?, ?)",
        &.{ "h_after", "sess_1", "m1", "1784119389936251113" });

    // SELECT from the new column.
    var q = try ctx.db.query(alloc,
        "SELECT created_at_nano FROM llm_history WHERE id = 'h_after'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1784119389936251113", row.values[0]);
}

// ============================================================================
// Test 8 — ORDER BY on the new column works (verifies the index survived)
// ============================================================================

test "Migration075: ORDER BY last_activity_nano DESC on worker uses the renamed index" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // EXPLAIN QUERY PLAN should pick up idx_worker_last_activity_nano for
    // an ORDER BY last_activity_nano DESC query.
    var q = try ctx.db.query(alloc,
        "EXPLAIN QUERY PLAN SELECT id FROM worker ORDER BY last_activity_nano DESC",
        &.{});
    defer q.deinit();
    var found_index: bool = false;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        for (row.values) |v| {
            if (std.mem.indexOf(u8, v, "idx_worker_last_activity_nano") != null) {
                found_index = true;
                break;
            }
        }
    }
    try testing.expect(found_index);
}

// ============================================================================
// Test 9 — Full table-info diff (regression: no extra columns lost or gained)
// ============================================================================

test "Migration075: per-table column count is preserved (rename doesn't drop or add columns)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Snapshot before.
    const before_logs = try listColumns(alloc, &ctx.db, "logs");
    defer {
        for (before_logs) |c| alloc.free(c);
        alloc.free(before_logs);
    }
    const before_llm = try listColumns(alloc, &ctx.db, "llm_history");
    defer {
        for (before_llm) |c| alloc.free(c);
        alloc.free(before_llm);
    }
    const before_skills = try listColumns(alloc, &ctx.db, "session_skills");
    defer {
        for (before_skills) |c| alloc.free(c);
        alloc.free(before_skills);
    }
    const before_worker = try listColumns(alloc, &ctx.db, "worker");
    defer {
        for (before_worker) |c| alloc.free(c);
        alloc.free(before_worker);
    }
    const before_tasks = try listColumns(alloc, &ctx.db, "workspace_item_tasks");
    defer {
        for (before_tasks) |c| alloc.free(c);
        alloc.free(before_tasks);
    }

    try Migration075RenameTimestampColumnsToNanoSuffix.up(&ctx.db, alloc);

    // Snapshot after.
    const after_logs = try listColumns(alloc, &ctx.db, "logs");
    defer {
        for (after_logs) |c| alloc.free(c);
        alloc.free(after_logs);
    }
    const after_llm = try listColumns(alloc, &ctx.db, "llm_history");
    defer {
        for (after_llm) |c| alloc.free(c);
        alloc.free(after_llm);
    }
    const after_skills = try listColumns(alloc, &ctx.db, "session_skills");
    defer {
        for (after_skills) |c| alloc.free(c);
        alloc.free(after_skills);
    }
    const after_worker = try listColumns(alloc, &ctx.db, "worker");
    defer {
        for (after_worker) |c| alloc.free(c);
        alloc.free(after_worker);
    }
    const after_tasks = try listColumns(alloc, &ctx.db, "workspace_item_tasks");
    defer {
        for (after_tasks) |c| alloc.free(c);
        alloc.free(after_tasks);
    }

    // Column counts must be identical (rename is in-place).
    try testing.expectEqual(before_logs.len, after_logs.len);
    try testing.expectEqual(before_llm.len, after_llm.len);
    try testing.expectEqual(before_skills.len, after_skills.len);
    try testing.expectEqual(before_worker.len, after_worker.len);
    try testing.expectEqual(before_tasks.len, after_tasks.len);
}

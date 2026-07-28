//! Static + behavioural regression checks for Migration 066
//! (`design_pages.workspace_item_task_id` FK + backfill).
//!
//! Why this file exists
//! ────────────────────
//! Migration 066 adds a single nullable TEXT column to `design_pages`
//! that binds each page 1:1 to a `workspace_item_tasks` chat-session
//! row. The replacement of the name-pattern lookup in
//! `AppLayout.handleDesignOpenChat` with a direct FK lookup depends
//! on this column being (a) added, (b) uniquely indexed, (c) backfilled
//! for every existing page so legacy DBs do not orphan their per-page
//! chats.
//!
//! The migration must:
//!   1. Add `workspace_item_task_id TEXT` (nullable, no DEFAULT —
//!      NULL = "not yet backfilled"; after `up()` returns, every row
//!      must be backfilled).
//!   2. Create a UNIQUE index on the column (the 1:1 invariant; SQLite
//!      uses the same index for the FK lookup, so no second index is
//!      needed).
//!   3. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column" or "index already exists" — see project
//!      memory `nalar-data-and-routines.md` §"Migration #009-#052
//!      fresh-DB cascade is fragile").
//!   4. Be safe for fresh-DB installs that already declare the column
//!      in their canonical CREATE TABLE — `addColumnIfMissing` handles
//!      both fresh-DB and upgrade-from-v1 paths.
//!   5. **Backfill** every pre-existing page with a fresh
//!      `workspace_item_tasks` row named `"Design Chat: <page_name>"`
//!      (or `"Design Chat: untitled"` for empty page names) so the
//!      design canvas chat surface has a stable task row for every
//!      legacy page.
//!
//! The migration-registration trap (defining the struct without
//! registering it in `allMigrations`) is checked in Test 5 — see
//! project memory `migration-registration-trap.md`.
//!
//! Plan: docs/superpowers/plans/2026-07-28-design-page-workspace-item-task-fk.md
//! (Task 1).

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const migration = @import("migration.zig");
const Migration066AddDesignPageTaskFk = migration.Migration066AddDesignPageTaskFk;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Mirror of the production schema BEFORE Migration 066 — no
/// `workspace_item_task_id` column on `design_pages`. The migration
/// itself adds the column via `addColumnIfMissing`.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // workspace_items + workspace_item_tasks: FK targets + chat-session
    // table that the backfill creates new rows in. Production walks
    // migrations 001 → 065 first; we mirror the minimal schema here.
    // The minimal `workspace_item_tasks` schema matches the v65 shape
    // (description added by Migration 062, task_type is the
    // NOT NULL DEFAULT 'standard' column).
    try db.exec(alloc,
        "CREATE TABLE workspace_items (id TEXT PRIMARY KEY, workspace_id TEXT, item_type TEXT)",
        &.{});
    try db.exec(alloc,
        "CREATE TABLE workspace_item_tasks (" ++
            "id TEXT PRIMARY KEY, " ++
            "name TEXT, " ++
            "workspace_item_id TEXT, " ++
            "task_type TEXT NOT NULL DEFAULT 'standard', " ++
            "description TEXT NOT NULL DEFAULT ''" ++
            ")",
        &.{});

    // design_pages: the pre-migration shape (Migration 055 + 056
    // schema — id, workspace_item_id, name, width, height, x, y,
    // position, created_at, updated_at, FK to workspace_items).
    // NO `workspace_item_task_id` column yet — that's exactly what
    // Migration 066 adds.
    try db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration066 adds workspace_item_task_id column to design_pages" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('design_pages')
            \\WHERE name = 'workspace_item_task_id'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name.
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("workspace_item_task_id", row.values[0]);

    // Confirm there are no extra rows (i.e. only one match — not the
    // "column literally named TEXT" footgun from passing only a type
    // to addColumnIfMissing; see project memory
    // `addColumnIfMissing-requires-name-type`).
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be TEXT (so the FK to
    // workspace_item_tasks.id works), not a literal "TEXT" string
    // in the column-name slot.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", type_row.values[0]);

    // UNIQUE index sanity — must exist after the migration (the
    // 1:1 invariant enforcement). Catch a regression where
    // someone drops the CREATE INDEX step but leaves the column.
    var qi = try ctx.db.query(alloc,
        \\SELECT name FROM sqlite_master
        \\WHERE type = 'index'
        \\  AND name = 'idx_design_pages_workspace_item_task_id'
    , &.{});
    defer qi.deinit();
    const index_row = (try qi.next()) orelse return error.UniqueIndexMissing;
    defer index_row.deinit(alloc);
    try testing.expectEqualStrings("idx_design_pages_workspace_item_task_id", index_row.values[0]);
}

test "Migration066 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column
    // name" or "index already exists" — the
    // `addColumnIfMissing` + `CREATE … IF NOT EXISTS` calls are all
    // idempotent.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration066 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // for design_pages already includes `workspace_item_task_id TEXT`.
    // The migration must be a no-op for the column add (NOT a
    // "duplicate column" crash), the index add must be idempotent
    // (IF NOT EXISTS), and the backfill must find no rows to update
    // (table is empty after the recreate).
    try ctx.db.exec(alloc, "DROP TABLE design_pages", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE design_pages (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_item_id TEXT NOT NULL,
        \\    name TEXT NOT NULL DEFAULT '',
        \\    width INTEGER NOT NULL DEFAULT 1440,
        \\    height INTEGER NOT NULL DEFAULT 1024,
        \\    x INTEGER NOT NULL DEFAULT 0,
        \\    y INTEGER NOT NULL DEFAULT 0,
        \\    position INTEGER NOT NULL DEFAULT 0,
        \\    workspace_item_task_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    FOREIGN KEY (workspace_item_id) REFERENCES workspace_items(id) ON DELETE CASCADE
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists,
    // CREATE INDEX IF NOT EXISTS is a no-op, backfill query returns
    // zero rows.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // Re-check: still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('design_pages')
        \\WHERE name = 'workspace_item_task_id'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration066 backfills a workspace_item_tasks row for each existing design page" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Seed: one workspace_item, then 3 design pages (with one
    // empty-name edge case to exercise the "Design Chat: untitled"
    // fallback). The setupDb() schema does NOT yet include the
    // `workspace_item_task_id` column; we add it manually first
    // (simulating that the migration's `addColumnIfMissing` step has
    // already run on a legacy DB) — every existing row gets NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) " ++
            "VALUES ('wi_1', 'ws_1', 'design')",
        &.{});
    try ctx.db.exec(alloc,
        "ALTER TABLE design_pages ADD COLUMN workspace_item_task_id TEXT",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_a', 'wi_1', 'Login', 0)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_b', 'wi_1', 'Dashboard', 1)",
        &.{});
    try ctx.db.exec(alloc,
        // Empty name — exercises the "Design Chat: untitled" fallback.
        "INSERT INTO design_pages (id, workspace_item_id, name, position) " ++
            "VALUES ('page_c', 'wi_1', '', 2)",
        &.{});

    // Sanity: all 3 pages have NULL task_id BEFORE the migration runs.
    {
        var q = try ctx.db.query(alloc,
            "SELECT COUNT(*) FROM design_pages WHERE workspace_item_task_id IS NULL",
            &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("3", row.values[0]);
    }

    // Apply the migration. addColumnIfMissing no-ops (column exists);
    // CREATE INDEX IF NOT EXISTS creates the unique index; backfill
    // creates 3 new tasks + updates 3 pages.
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);

    // 1. Every page now has a non-NULL workspace_item_task_id that
    //    points at a real workspace_item_tasks row. Joining both
    //    tables catches both the UPDATE and the FK invariant in one
    //    query — if the migration forgot the UPDATE, the JOIN would
    //    still return 3 rows (matching by workspace_item_id, not the
    //    new task_id), so we use the actual `workspace_item_task_id`
    //    column for the join.
    var qj = try ctx.db.query(alloc,
        \\SELECT dp.id, dp.name, t.id, t.name, t.task_type, t.description
        \\FROM design_pages dp
        \\JOIN workspace_item_tasks t
        \\  ON t.id = dp.workspace_item_task_id
        \\WHERE dp.workspace_item_id = 'wi_1'
        \\ORDER BY dp.position ASC
    , &.{});
    defer qj.deinit();

    // Expected: page_a → "Design Chat: Login", page_b → "Design Chat:
    // Dashboard", page_c → "Design Chat: untitled" (empty name
    // fallback). task_type is always 'standard'; description is ''.
    const expected: [3][]const u8 = .{ "Design Chat: Login", "Design Chat: Dashboard", "Design Chat: untitled" };
    const expected_page_ids: [3][]const u8 = .{ "page_a", "page_b", "page_c" };
    for (expected, 0..) |_, i| {
        const row = (try qj.next()) orelse return error.BackfillRowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings(expected_page_ids[i], row.values[0]);
        try testing.expectEqualStrings(expected[i], row.values[3]);
        try testing.expectEqualStrings("standard", row.values[4]);
        try testing.expectEqualStrings("", row.values[5]);
        // Sanity: the task id is non-empty (i.e. was actually
        // generated, not the empty-slice-as-NULL trap).
        try testing.expect(row.values[2].len > 0);
    }
    // No 4th row expected — the backfill should produce exactly
    // one task per page.
    try testing.expect((try qj.next()) == null);

    // 2. No page was left with NULL workspace_item_task_id after the
    //    backfill (the migration's WHERE clause should match every
    //    pre-existing row exactly once).
    var qnull = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM design_pages WHERE workspace_item_task_id IS NULL",
        &.{});
    defer qnull.deinit();
    const null_row = (try qnull.next()) orelse return error.RowMissing;
    defer null_row.deinit(alloc);
    try testing.expectEqualStrings("0", null_row.values[0]);

    // 3. Re-run safety: a second `up()` call must not produce extra
    //    task rows (the backfill's WHERE workspace_item_task_id IS
    //    NULL matches zero rows on the second pass).
    try Migration066AddDesignPageTaskFk.up(&ctx.db, alloc);
    var qc = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM workspace_item_tasks WHERE workspace_item_id = 'wi_1'",
        &.{});
    defer qc.deinit();
    const count_row = (try qc.next()) orelse return error.RowMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("3", count_row.values[0]);
}

test "Migration066 is registered in allMigrations" {
    // The migration-registration trap: defining the struct is not
    // enough — it must also be added to `migration.zig::allMigrations`.
    // A static-contract test that just imports the struct directly
    // would pass with the tuple missing (because tests import the
    // struct, not the slice). This test iterates the slice and
    // catches the regression where someone deletes the registration
    // tuple. See project memory `migration-registration-trap.md`.
    for (migration.allMigrations) |m| {
        if (m.version == Migration066AddDesignPageTaskFk.version) return;
    }
    return error.Migration066NotRegistered;
}
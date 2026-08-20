//! Behavioural regression checks for Migration 077
//! (users + user_companies + user_company_members + workspaces.user_id +
//!  sessions.user_id + default user_system + backfill).
//!
//! Why this file exists
//! ────────────────────
//! Migration 077 lays the schema foundation for multi-user / multi-tenant nalar:
//!   - `users` table (id, email, name, password_hash, role, is_active,
//!     created_at, updated_at, last_login_at)
//!   - `user_companies` table (id, name, slug, description, is_active,
//!     created_at, updated_at, created_by)
//!   - `user_company_members` join table (user_id, user_company_id, role,
//!     joined_at, invited_by) with composite PRIMARY KEY
//!   - Additive `user_id` column on `workspaces` (nullable, no FK constraint)
//!   - Additive `user_id` column on `sessions` (nullable, no FK constraint)
//!   - Default `user_system` user (is_active=0, password_hash='!disabled',
//!     can never log in)
//!   - Backfill of all legacy workspaces + sessions to user_id='user_system'
//!
//! The migration must:
//!   1. Create all 3 new tables with the right column types + defaults.
//!   2. Add `user_id` columns to `workspaces` + `sessions` via
//!      `addColumnIfMissing` (idempotent on re-run).
//!   3. Create the 6 supporting indexes (idx_users_email, idx_users_active,
//!      idx_user_companies_slug, idx_user_companies_active,
//!      idx_user_company_members_user, idx_user_company_members_company,
//!      idx_workspaces_user_id, idx_sessions_user_id).
//!   4. Insert the default `user_system` user (idempotent via INSERT OR IGNORE).
//!   5. Backfill all legacy rows (workspaces, sessions) where user_id IS NULL
//!      to user_id='user_system'. Idempotent — re-running on a DB where every
//!      row already has user_id set is a no-op.
//!   6. Be safe for fresh-DB installs (the canonical CREATE TABLE in earlier
//!      migrations does NOT declare user_id, so the ALTER TABLE adds it; on
//!      re-run, `addColumnIfMissing` short-circuits).
//!
//! Set-up uses `MigrationManager.registerAllMigrations` + `runMigrations` so
//! the test schema matches what production runs (per project memory
//! `project-test-use-migrations-module`). This avoids the drift trap of
//! hand-rolling a minimal workspaces / sessions schema — the moment a new
//! column lands in production, the hand-rolled baseline silently tests an
//! outdated schema.
//!
//! Plan: docs/superpowers/plans/2026-08-21-users-rbac-foundation.md
//! Task: task_1787199963946_1
//! Spec: docs/superpowers/specs/2026-08-21-users-rbac-foundation-design.md

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("migration.zig");

const Migration077AddUsersAndRbacSchema = migration.Migration077AddUsersAndRbacSchema;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Set up an in-memory DB and run every production migration through 077.
/// After this returns, the schema is exactly what a production DB looks
/// like after Migration 077 has run — the 3 new tables exist, the 2
/// additive columns are present, the default user_system is in the
/// users table, and every existing row (zero, since this is a fresh DB)
/// would have user_id='user_system' if there were any.
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

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Test 1 — `users` table has all 9 columns with the right types + defaults.
// ============================================================================

test "Migration077 creates users table with all 9 columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Expected columns: (name, type, default value or "" for none).
    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "email", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "'" },
        .{ .name = "password_hash", .type = "TEXT", .default = "" },
        .{ .name = "role", .type = "TEXT", .default = "'user'" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "last_login_at", .type = "DATETIME", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM pragma_table_info('users') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        // SQLite's dflt_value is the raw literal (e.g. "'" for empty-string DEFAULT,
        // "'user'" for the role default). Compare as-is.
        if (expected[idx].default.len > 0) {
            try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        }
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 2 — `user_companies` table has all 8 columns with the right types +
// defaults.
// ============================================================================

test "Migration077 creates user_companies table with all 8 columns" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const expected = [_]struct { name: []const u8, type: []const u8, default: []const u8 }{
        .{ .name = "id", .type = "TEXT", .default = "" },
        .{ .name = "name", .type = "TEXT", .default = "" },
        .{ .name = "slug", .type = "TEXT", .default = "" },
        .{ .name = "description", .type = "TEXT", .default = "'" },
        .{ .name = "is_active", .type = "INTEGER", .default = "1" },
        .{ .name = "created_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "updated_at", .type = "DATETIME", .default = "CURRENT_TIMESTAMP" },
        .{ .name = "created_by", .type = "TEXT", .default = "" },
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name, type, dflt_value FROM pragma_table_info('user_companies') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx].name, row.values[0]);
        try testing.expectEqualStrings(expected[idx].type, row.values[1]);
        if (expected[idx].default.len > 0) {
            try testing.expectEqualStrings(expected[idx].default, row.values[2]);
        }
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ============================================================================
// Test 3 — `user_company_members` join table has the composite PRIMARY KEY.
// ============================================================================

test "Migration077 creates user_company_members table with composite PK" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the table exists with all 5 user-defined columns.
    const expected = [_][]const u8{
        "user_id", "user_company_id", "role", "joined_at", "invited_by",
    };

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('user_company_members') ORDER BY cid
    , &.{});
    defer q.deinit();

    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);

    // Verify the composite PRIMARY KEY (user_id, user_company_id) is in
    // place. SQLite stores the PK info in pragma_table_info's `pk` column;
    // the composite PK manifests as pk=1 on user_id and pk=2 on
    // user_company_id (the order they're declared in the PRIMARY KEY clause).
    var pk_q = try ctx.db.query(alloc,
        \\SELECT name, pk FROM pragma_table_info('user_company_members')
        \\WHERE pk > 0 ORDER BY pk
    , &.{});
    defer pk_q.deinit();

    const expected_pk = [_][]const u8{ "user_id", "user_company_id" };
    var pk_idx: usize = 0;
    while (try pk_q.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(pk_idx < expected_pk.len);
        try testing.expectEqualStrings(expected_pk[pk_idx], row.values[0]);
        pk_idx += 1;
    }
    try testing.expectEqual(@as(usize, expected_pk.len), pk_idx);

    // Verify the CHECK constraint on `role` rejects invalid values.
    // `sqlite3_prepare_v2` will return an error if the constraint fails.
    // Valid value: insert succeeds. Invalid value: insert fails with
    // CHECK constraint failed.
    try ctx.db.exec(alloc,
        "INSERT INTO users (id, email, name, password_hash) VALUES ('u_pk', 'u_pk@x', 'U', 'h')",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO user_companies (id, name, slug) VALUES ('c_pk', 'C', 'c-pk')",
        &.{});

    // Valid role: 'member' (the default) — should succeed.
    try ctx.db.exec(alloc,
        "INSERT INTO user_company_members (user_id, user_company_id, role) " ++
            "VALUES ('u_pk', 'c_pk', 'member')",
        &.{});

    // Invalid role: 'superuser' (not in the CHECK list) — should fail.
    const result = ctx.db.exec(alloc,
        "INSERT INTO user_company_members (user_id, user_company_id, role) " ++
            "VALUES ('u_pk', 'c_pk', 'superuser')",
        &.{});
    try testing.expectError(error.SqliteError, result);
}

// ============================================================================
// Test 4 — workspaces.user_id added + backfill works (NULL → user_system).
// ============================================================================

test "Migration077 adds user_id to workspaces and backfills legacy rows to user_system" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the column exists with type=TEXT, nullable.
    var col_q = try ctx.db.query(alloc,
        \\SELECT type, \"notnull\" FROM pragma_table_info('workspaces')
        \\WHERE name = 'user_id'
    , &.{});
    defer col_q.deinit();
    const col_row = (try col_q.next()) orelse return error.ColumnMissing;
    defer col_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", col_row.values[0]);
    try testing.expectEqualStrings("0", col_row.values[1]); // 0 = nullable

    // Insert a legacy row WITH user_id=NULL (mimics a row from a pre-077 DB).
    // The column allows NULL by default since the migration uses
    // "user_id TEXT" (no NOT NULL).
    try ctx.db.exec(alloc,
        "INSERT INTO workspaces (id, name, user_id) VALUES ('ws_legacy', 'Legacy', NULL)",
        &.{});

    // Verify it's NULL.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM workspaces WHERE id = 'ws_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        // NULL is represented as an empty string by SqliteBackend.exec,
        // matching the project convention (see project memory
        // `sqlite-backend-empty-slice-binds-as-null`).
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration. `addColumnIfMissing` is a no-op (column
    // exists), `CREATE TABLE IF NOT EXISTS` is a no-op, `INSERT OR IGNORE`
    // is a no-op for user_system — but the backfill UPDATE will convert
    // the NULL user_id to 'user_system'.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the legacy row is now backfilled.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM workspaces WHERE id = 'ws_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_system", row.values[0]);
    }
}

// ============================================================================
// Test 5 — sessions.user_id added + backfill works (NULL → user_system).
// ============================================================================

test "Migration077 adds user_id to sessions and backfills legacy rows to user_system" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Verify the column exists with type=TEXT, nullable.
    var col_q = try ctx.db.query(alloc,
        \\SELECT type, \"notnull\" FROM pragma_table_info('sessions')
        \\WHERE name = 'user_id'
    , &.{});
    defer col_q.deinit();
    const col_row = (try col_q.next()) orelse return error.ColumnMissing;
    defer col_row.deinit(alloc);
    try testing.expectEqualStrings("TEXT", col_row.values[0]);
    try testing.expectEqualStrings("0", col_row.values[1]); // 0 = nullable

    // Insert a legacy row with user_id=NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, user_id) VALUES ('sess_legacy', 'Legacy', 'active', NULL)",
        &.{});

    // Verify it's NULL.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM sessions WHERE id = 'sess_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("", row.values[0]);
    }

    // Re-run the migration to trigger the backfill.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the legacy row is now backfilled.
    {
        var q = try ctx.db.query(alloc,
            "SELECT user_id FROM sessions WHERE id = 'sess_legacy'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("user_system", row.values[0]);
    }
}

// ============================================================================
// Test 6 — Default `user_system` user exists with the right shape.
// ============================================================================

test "Migration077 inserts the default user_system user" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    var q = try ctx.db.query(alloc,
        \\SELECT id, email, name, password_hash, role, is_active
        \\FROM users WHERE id = 'user_system'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.UserSystemMissing;
    defer row.deinit(alloc);

    try testing.expectEqualStrings("user_system", row.values[0]);
    try testing.expectEqualStrings("system@local", row.values[1]);
    try testing.expectEqualStrings("System", row.values[2]);
    try testing.expectEqualStrings("!disabled", row.values[3]);
    try testing.expectEqualStrings("admin", row.values[4]);
    try testing.expectEqualStrings("0", row.values[5]); // is_active=0 — can never log in

    // Verify exactly ONE user_system row exists (UNIQUE constraint on
    // email + INSERT OR IGNORE on the second migration call).
    var count_q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM users WHERE id = 'user_system'", &.{});
    defer count_q.deinit();
    const count_row = (try count_q.next()) orelse return error.CountMissing;
    defer count_row.deinit(alloc);
    try testing.expectEqualStrings("1", count_row.values[0]);
}

// ============================================================================
// Test 7 — Idempotent on re-run (the killer test — addColumnIfMissing + INSERT OR IGNORE).
// ============================================================================

test "Migration077 is idempotent on re-run via addColumnIfMissing + INSERT OR IGNORE" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Run .up() three more times — each must NOT crash with
    // "duplicate column name" or "UNIQUE constraint failed" or any
    // other error. This is the specific failure mode addColumnIfMissing +
    // INSERT OR IGNORE are designed to prevent.
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);
    try Migration077AddUsersAndRbacSchema.up(&ctx.db, alloc);

    // Verify the schema is still correct after all 4 runs total
    // (1 from setupDb + 3 from this test).
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('workspaces') WHERE name = 'user_id'
    , &.{});
    defer q.deinit();
    const ws_row = (try q.next()) orelse return error.RowMissing;
    defer ws_row.deinit(alloc);
    try testing.expectEqualStrings("1", ws_row.values[0]);

    var q2 = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name = 'user_id'
    , &.{});
    defer q2.deinit();
    const sess_row = (try q2.next()) orelse return error.RowMissing;
    defer sess_row.deinit(alloc);
    try testing.expectEqualStrings("1", sess_row.values[0]);

    // Verify exactly ONE user_system row.
    var q3 = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM users WHERE id = 'user_system'", &.{});
    defer q3.deinit();
    const user_row = (try q3.next()) orelse return error.RowMissing;
    defer user_row.deinit(alloc);
    try testing.expectEqualStrings("1", user_row.values[0]);

    // Run the full migration runner again — schema_migrations tracking
    // makes Migration 077 a no-op.
    var manager = migration.MigrationManager.init(alloc, &ctx.db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();
}

// ============================================================================
// Test 8 — Migration 077 is registered in `allMigrations`. Defining the
// struct alone is not enough — it must also be added to
// `migration.zig::allMigrations` so the production migration runner picks
// it up (per project memory `migration-registration-trap.md`).
// ============================================================================

test "Migration077 is registered in allMigrations" {
    const all = migration.allMigrations;
    var found: bool = false;
    for (all) |m| {
        if (m.version == Migration077AddUsersAndRbacSchema.version and
            std.mem.eql(u8, m.name, Migration077AddUsersAndRbacSchema.name))
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
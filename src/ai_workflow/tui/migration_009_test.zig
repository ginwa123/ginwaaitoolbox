//! Behavioral tests for Migration 009 (remove_created_column).
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! Migration 009's `INSERT INTO ... SELECT datetime(CAST(created AS
//! INTEGER), 'unixepoch') FROM llm_history_old` references a `created`
//! column that has **never existed** in this codebase — Migration 001
//! has always created `llm_history` with a `created_at` column
//! directly. On a fresh DB (no historical `created` column),
//! `runMigrations` aborts with:
//!
//!   sqlite3_prepare_v2 error: no such column: created
//!
//! which crashes the server during startup. A static source check
//! would not catch this — only executing the INSERT against an
//! actual schema exposes the bug. The fix (Migration 009 now uses
//! `COALESCE(created_at, CURRENT_TIMESTAMP)`) is verified by
//! running migration 009 against the schema state left by
//! migrations 001–008.
//!
//! The SqliteBackend's public API (see
//! `src/modules/databases/sqlite/Sqlite.zig`) is: `init`, `exec`,
//! `query` (returns `Rows` with `next()` → `?Row` carrying
//! `values: [][]u8`). Column reads go through `Row.values[i]`, which
//! is always text.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("migration.zig");
const Migration001CreateLLMHistory = migration.Migration001CreateLLMHistory;
const Migration002AddRoleToLLMHistory = migration.Migration002AddRoleToLLMHistory;
const Migration003AddReasoningContent = migration.Migration003AddReasoningContent;
const Migration004AddSessionDir = migration.Migration004AddSessionDir;
const Migration005AddIsFeedToLLM = migration.Migration005AddIsFeedToLLM;
const Migration006AddAgent = migration.Migration006AddAgent;
const Migration007AddSessionTracking = migration.Migration007AddSessionTracking;
const Migration008AddSessionSkills = migration.Migration008AddSessionSkills;
const Migration009RemoveCreatedColumn = migration.Migration009RemoveCreatedColumn;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB and apply migrations 001–008,
/// matching the schema state that migration 009 was always meant to
/// consume. After this returns, the DB has the full pre-migration-009
/// `llm_history` schema with all columns added by 002–008, ready for
/// migration 009 to do its rename-and-copy dance.
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

    // Replay migrations 001–008 in version order. Migration 001 itself
    // creates the table; the rest are ADD COLUMN. This mirrors what a
    // fresh-install DB looks like when migration 009 is about to run.
    try Migration001CreateLLMHistory.up(&db, alloc);
    try Migration002AddRoleToLLMHistory.up(&db, alloc);
    try Migration003AddReasoningContent.up(&db, alloc);
    try Migration004AddSessionDir.up(&db, alloc);
    try Migration005AddIsFeedToLLM.up(&db, alloc);
    try Migration006AddAgent.up(&db, alloc);
    try Migration007AddSessionTracking.up(&db, alloc);
    try Migration008AddSessionSkills.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: migration 009 does not crash on a fresh-DB schema ────────────
//
// This is the canonical regression test for the "fresh-DB crash" bug.
// It MUST NOT return an error (the bug was `error.PrepareFailed` with
// message "no such column: created" from Migration 009's INSERT...SELECT).
// Before the fix, this test fails on a fresh DB. After the fix, it
// passes — and the CI smoke test (`scripts/ci-smoke-test.sh`) depends
// on this passing on the test runner's fresh $HOME.

test "Migration009RemoveCreatedColumn does not crash on fresh-DB schema (no 'created' column)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: pre-migration `llm_history` exists with `created_at` (not
    // `created`). If this assertion fails, the setup helper drifted out
    // of sync with Migration 001 — fix the helper, not the test.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM pragma_table_info('llm_history') WHERE name IN ('created', 'created_at')",
            &.{});
        defer q.deinit();
        var has_created: bool = false;
        var has_created_at: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            if (std.mem.eql(u8, row.values[0], "created")) has_created = true;
            if (std.mem.eql(u8, row.values[0], "created_at")) has_created_at = true;
        }
        try testing.expect(!has_created);
        try testing.expect(has_created_at);
    }

    // Run migration 009 — this is the line that crashed pre-fix.
    try Migration009RemoveCreatedColumn.up(&ctx.db, alloc);

    // Post-conditions: `llm_history_old` is gone (it was renamed then
    // dropped), `llm_history` still exists with `created_at`.
    {
        var q = try ctx.db.query(alloc,
            "SELECT name FROM sqlite_master WHERE name IN ('llm_history', 'llm_history_old') ORDER BY name",
            &.{});
        defer q.deinit();
        var seen_llm_history: bool = false;
        var seen_llm_history_old: bool = false;
        while (try q.next()) |row| {
            defer row.deinit(alloc);
            if (std.mem.eql(u8, row.values[0], "llm_history")) seen_llm_history = true;
            if (std.mem.eql(u8, row.values[0], "llm_history_old")) seen_llm_history_old = true;
        }
        try testing.expect(seen_llm_history);
        try testing.expect(!seen_llm_history_old);
    }
}

// ─── Test 2: pre-existing rows survive the rename-and-copy ────────────────
//
// Verifies that the COALESCE(created_at, CURRENT_TIMESTAMP) fix doesn't
// silently NULL out pre-existing rows. Inserts a single row with an
// explicit created_at, runs migration 009, asserts the row is still
// present with the same created_at value.

test "Migration009RemoveCreatedColumn preserves pre-existing rows' created_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert a deterministic row in the pre-migration schema.
    try ctx.db.exec(alloc,
        "INSERT INTO llm_history (id, session_id, model, response_content, created_at) " ++
        "VALUES ('row_1', 'sess_1', 'm1', 'hello', '2026-06-30 12:34:56')",
        &.{});

    try Migration009RemoveCreatedColumn.up(&ctx.db, alloc);

    // Read it back: should still exist with the original created_at.
    var q = try ctx.db.query(alloc,
        "SELECT id, created_at FROM llm_history WHERE id = 'row_1'",
        &.{});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("row_1", row.values[0]);
    try testing.expectEqualStrings("2026-06-30 12:34:56", row.values[1]);
}

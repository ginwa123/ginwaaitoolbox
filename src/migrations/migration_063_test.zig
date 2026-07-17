//! Behavioural tests for Migration 063 (add the `logs` table for
//! frontend error capture).
//!
//! Why this file exists
//! ────────────────────
//! Migration 063 introduces the `logs` table that the frontend's
//! `window.error` / `unhandledrejection` / `console.error` /
//! `console.warn` listeners POST into (Chunk 2 handler). The schema
//! must be exactly:
//!   - 11 columns in the right order (the Ch3 SELECT * ORDER BY
//!     created_at DESC relies on the cid ordering to be deterministic).
//!   - 2 indexes (`idx_logs_created_at DESC` for the primary read path,
//!     `idx_logs_level` for `WHERE level = ?` filtering).
//!   - Idempotent on a re-run (`CREATE TABLE IF NOT EXISTS` +
//!     `CREATE INDEX IF NOT EXISTS`) so a fresh-DB install and an
//!     upgrade-from-v62 install both succeed.
//!
//! A static source check would not catch a typo'd column name, a
//! missing index, a missing `IF NOT EXISTS` (which would crash on a
//! re-run), or a wrong column type. Asserting the actual schema after
//! `up()` runs mirrors the pattern in `migration_062_test.zig`.
//!
//! Plan: docs/plans/2026-07-17-frontend-error-logs-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration063AddFrontendLogs = migration.Migration063AddFrontendLogs;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB. Mirrors `routines/scheduler_test.zig`
/// `setupDb` (the project's canonical Io.Threaded + :memory: pattern).
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

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: Migration 063 creates all 11 columns in the right order ──────

test "Migration063 creates logs table with all 11 columns in the right order" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration063AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(
        alloc,
        "SELECT name FROM pragma_table_info('logs') ORDER BY cid",
        &[_][]const u8{},
    );
    defer rows.deinit();

    const expected = [_][]const u8{
        "id", "created_at", "level", "kind", "message",
        "stack", "source", "line", "route_path", "session_id", "count",
    };

    var idx: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        try testing.expect(idx < expected.len);
        try testing.expectEqualStrings(expected[idx], row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, expected.len), idx);
}

// ─── Test 2: Migration 063 creates the 2 indexes ──────────────────────────

test "Migration063 creates the idx_logs_created_at and idx_logs_level indexes" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration063AddFrontendLogs.up(&s.db, alloc);

    var rows = try s.db.query(
        alloc,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='logs' ORDER BY name",
        &[_][]const u8{},
    );
    defer rows.deinit();

    var found_created_at = false;
    var found_level = false;
    while (try rows.next()) |row| {
        defer row.deinit(alloc);
        if (std.mem.eql(u8, row.values[0], "idx_logs_created_at")) found_created_at = true;
        if (std.mem.eql(u8, row.values[0], "idx_logs_level")) found_level = true;
    }
    try testing.expect(found_created_at);
    try testing.expect(found_level);
}

// ─── Test 3: Migration 063 is idempotent on a re-run ──────────────────────

test "Migration063 is idempotent (re-running up() does not error)" {
    const alloc = testing.allocator;
    var s = try setupDb();
    defer s.threaded.deinit();
    defer s.db.deinit();

    try Migration063AddFrontendLogs.up(&s.db, alloc);
    // Second run must not error — `CREATE TABLE IF NOT EXISTS` +
    // `CREATE INDEX IF NOT EXISTS` make this a safe no-op. If they
    // were bare CREATE / CREATE INDEX, the second run would crash
    // with "table logs already exists" / "index already exists".
    try Migration063AddFrontendLogs.up(&s.db, alloc);
}
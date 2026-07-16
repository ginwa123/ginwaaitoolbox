//! Static regression checks for Migration 063
//! (sessions.is_auto_retry_until_stop + sessions.last_finish_reason).
//!
//! Why this file exists
//! ────────────────────
//! Migration 063 introduces two new columns on `sessions`:
//!   - `is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0` — opt-in flag
//!     that lets a session keep retrying past the 10-attempt TooManyRetries
//!     bail (unattended mode for overnight runs).
//!   - `last_finish_reason TEXT` — denormalized cache of the most recent
//!     `finish_reason` the workflow observed, so a server restart mid-
//!     conversation picks up where the last turn left off.
//!
//! The migration must:
//!   1. Add both columns to a fresh DB that only has the canonical
//!      `sessions(id, name, status)` columns (upgrade-from-v1 path).
//!   2. Be idempotent (re-runs don't crash with "duplicate column name").
//!   3. Give existing rows a `0` default for the flag and NULL for
//!      `last_finish_reason`.
//!
//! Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//!   (Chunk 1, Task 1.1)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration063AddSessionAutoRetry = @import("migration.zig").Migration063AddSessionAutoRetry;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    // Minimal v1 sessions table — the canonical pre-Migration-063 schema
    // only declares id/name/status (Migration 017 line 263-269). The
    // migration must add the new columns on top of this.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active'
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration063 adds is_auto_retry_until_stop column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('sessions')
            \\WHERE name = 'is_auto_retry_until_stop'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'is_auto_retry_until_stop'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("is_auto_retry_until_stop", row.values[0]);

    // No duplicate row.
    try testing.expect((try q.next()) == null);
}

test "Migration063 adds last_finish_reason column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'last_finish_reason'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_finish_reason", row.values[0]);
    try testing.expect((try q.next()) == null);
}

test "Migration063 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);
    // Re-run — must not crash with "duplicate column name".
    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // Still exactly one column of each name.
    for ([_][]const u8{ "is_auto_retry_until_stop", "last_finish_reason" }) |col| {
        var q = try ctx.db.query(alloc,
            \\SELECT COUNT(*) FROM pragma_table_info('sessions')
            \\WHERE name = ?
        , &[_][]const u8{col});
        defer q.deinit();
        const row = (try q.next()) orelse return error.RowMissing;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("1", row.values[0]);
    }
}

test "Migration063 default for is_auto_retry_until_stop is 0 on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one v1-shape session row (only id/name, no new columns yet).
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_063', 'Pre')",
        &.{});

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // The existing row should now have is_auto_retry_until_stop = '0'
    // (the NOT NULL DEFAULT 0 fires). SQLite stores INTEGER columns
    // as INTEGER affinity, but SqliteBackend.query reads values as
    // text — verify the string form '0'.
    var q = try ctx.db.query(alloc,
        "SELECT is_auto_retry_until_stop FROM sessions WHERE id = 's_pre_063'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "Migration063 last_finish_reason is NULL on existing rows" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_063b', 'Pre')",
        &.{});

    try Migration063AddSessionAutoRetry.up(&ctx.db, alloc);

    // SELECT last_finish_reason — expect empty string (SQL NULL is
    // surfaced as "" by SqliteBackend per the project's convention;
    // see project memory `sqlite-backend-empty-slice-binds-as-null`).
    var q = try ctx.db.query(alloc,
        "SELECT last_finish_reason FROM sessions WHERE id = 's_pre_063b'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

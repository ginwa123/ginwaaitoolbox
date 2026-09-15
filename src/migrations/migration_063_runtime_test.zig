//! Behavioral regression tests for the runtime CRUD helpers added
//! with Migration 063 (sessions.is_auto_retry_until_stop +
//! sessions.last_finish_reason).
//!
//! Why this file exists
//! ────────────────────
//! Migration 063 (migration_063_test.zig) verifies the SCHEMA change.
//! This file verifies the helper functions the rest of the codebase
//! uses to read + write the new columns:
//!   - create_session() takes is_auto_retry_until_stop as a parameter
//!   - getSession() reads both new columns back via SELECT
//!   - updateSessionAutoRetryUntilStop() toggles the flag
//!   - updateSessionLastFinishReason() persists the latest finish_reason
//!   - getSessionListWithCursor() / getSessionList() SELECT both new
//!     columns (covered separately in Task 1.4)
//!
//! The setup mirrors `migration_062_test.zig:32-59` — declare the
//! `sessions` table with the post-Migration-063 canonical shape
//! (includes the two new columns) to exercise the "fresh-DB canonical
//! CREATE TABLE" path that `addColumnIfMissing` handles.
//!
//! Plan: docs/superpowers/plans/2026-07-16-session-auto-retry-until-stop.md
//!   (Chunk 1, Task 1.3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;

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

    // Canonical post-Migration-063 schema. Both new columns are
    // already declared, so `addColumnIfMissing` (when called from
    // the migration's up()) short-circuits cleanly — no "duplicate
    // column" error. The runtime CRUD tests here use this shape
    // directly without re-running the migration.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    created_at DATETIME,
        \\    updated_at DATETIME,
        \\    selected_profile_model TEXT,
        \\    git_worktree_cwd TEXT,
        \\    is_auto_retry_until_stop INTEGER NOT NULL DEFAULT 0,
        \\    last_finish_reason TEXT,
        \\    pr_url TEXT,
        \\    pr_provider TEXT
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Reads a single text column from sessions by id. Returns an owned
/// copy (allocated with `testing.allocator`) so the caller can keep
/// the value alive after `row.deinit()`. Returns null if the row is
/// missing or the column is NULL (surfaced as empty []u8 — see the
/// `sqlite-backend-empty-slice-binds-as-null` project memory for the
/// NULL-as-empty-string convention).
fn readColumn(
    ctx: *TestCtx,
    allocator: std.mem.Allocator,
    column: []const u8,
    row_id: []const u8,
) !?[]u8 {
    // SqliteBackend.query takes argv as []const []const u8 (a slice of
    // string slices), not a tuple. Column name is interpolated via
    // std.fmt.allocPrint because `query` doesn't support format-string
    // substitution for table/column identifiers.
    const sql = try std.fmt.allocPrint(allocator, "SELECT {s} FROM sessions WHERE id = ?", .{column});
    defer allocator.free(sql);
    const argv = [_][]const u8{row_id};
    var q = try ctx.db.query(allocator, sql, argv[0..]);
    defer q.deinit();
    const row_opt = try q.next();
    if (row_opt) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return null;
}

test "create_session: is_auto_retry_until_stop = '1' is persisted to sessions row" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s1", "test", "1");
        defer session.deinit(alloc);

        const got = (try readColumn(&ctx, alloc, "is_auto_retry_until_stop", "s1")) orelse
            return error.NoRow;
        defer alloc.free(got);
        try testing.expectEqualStrings("1", got);
    }
}

test "create_session: empty is_auto_retry_until_stop defaults to '0'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Pass empty string — the helper coerces to "0" via SQL binding.
    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s2", "test", "");
        defer session.deinit(alloc);

        const got = (try readColumn(&ctx, alloc, "is_auto_retry_until_stop", "s2")) orelse
            return error.NoRow;
        defer alloc.free(got);
        try testing.expectEqualStrings("0", got);
    }
}

test "getSession: reads back is_auto_retry_until_stop + last_finish_reason" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Write the new columns directly so we can verify getSession
    // surfaces them — bypass create_session (which coerces the flag).
    // db.exec takes argv as `[]const []const u8` (a slice of strings);
    // an empty `&.{}` tuple binds every `?` as SQL NULL, so the
    // 5 placeholders below need explicit strings.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name, status, is_auto_retry_until_stop, last_finish_reason) " ++
        "VALUES (?, ?, 'active', ?, ?)",
        &[_][]const u8{ "s3", "test", "1", "stop" });

    const got = (try llm_history.getSession(alloc, &ctx.db, "s3")) orelse
        return error.NoRow;
    defer got.deinit(alloc);
    try testing.expectEqualStrings("1", got.is_auto_retry_until_stop);
    try testing.expectEqualStrings("stop", got.last_finish_reason);
}

test "updateSessionAutoRetryUntilStop: toggles 0 -> 1" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s4", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionAutoRetryUntilStop(alloc, &ctx.db, "s4", "1");

    const got = (try readColumn(&ctx, alloc, "is_auto_retry_until_stop", "s4")) orelse
        return error.NoRow;
    defer alloc.free(got);
    try testing.expectEqualStrings("1", got);
}

test "updateSessionLastFinishReason: persists the latest value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s5", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s5", "tool_calls");

    const got = (try readColumn(&ctx, alloc, "last_finish_reason", "s5")) orelse
        return error.NoRow;
    defer alloc.free(got);
    try testing.expectEqualStrings("tool_calls", got);
}

test "updateSessionLastFinishReason: overwrites on every call" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    {
        const session = try llm_history.create_session(alloc, &ctx.db, "s6", "test", "");
        defer session.deinit(alloc);
    }

    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s6", "length");
    try llm_history.updateSessionLastFinishReason(alloc, &ctx.db, "s6", "stop");

    const got = (try readColumn(&ctx, alloc, "last_finish_reason", "s6")) orelse
        return error.NoRow;
    defer alloc.free(got);
    try testing.expectEqualStrings("stop", got);
}

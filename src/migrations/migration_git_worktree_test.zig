//! Behavioral tests for Migration 046 (add git_worktree_cwd column to
//! sessions).
//!
//! Why a behavioral DB test (not a static check)?
//! ───────────────────────────────────────────────
//! Migration 046 is a simple ALTER TABLE ADD COLUMN, but a static source
//! check would not catch a typo in the column name, a missing NULL/NOT
//! NULL semantic, or a missing registration in `allMigrations` — all of
//! which would silently break the new `set_git_worktree` tool that
//! Chunks 2-4 of the plan will build on top of this column.
//!
//! The working precedent for in-process sqlite-backed tests is
//! `migration_routines_test.zig`: it opens `":memory:"` via
//! `std.Io.Threaded + db.init(io, ":memory:")`, hands the schema from
//! scratch (mimicking the state a real DB would have just before the
//! migration), runs the migration, and asserts via `db.query`. We
//! mirror that exact pattern here.
//!
//! Plan: docs/plans/2026-06-18-set-git-worktree-tool.md (Chunk 1)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration046AddGitWorktreeCwdToSessions = migration.Migration046AddGitWorktreeCwdToSessions;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the sessions table present
/// (matching the state left by migrations 017 + 022 + 025 + 029 + 040),
/// ready for Migration 046 to add the `git_worktree_cwd` column on top.
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

    // Mirror the state left by Migration 017 + 022 + 025 + 029 + 040
    // exactly — same columns, same NULL/NOT NULL semantics, same default
    // timestamps. This is what a real DB looks like the moment before
    // Migration 046 runs.
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    cwd TEXT,
        \\    workspace_id TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    selected_profile_model TEXT
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

// ─── Test 1: ALTER TABLE adds git_worktree_cwd defaulting to NULL ────────

test "Migration046AddGitWorktreeCwdToSessions adds git_worktree_cwd column defaulting to NULL" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration046AddGitWorktreeCwdToSessions.up(&ctx.db, alloc);

    // Insert a row WITHOUT specifying git_worktree_cwd. The new column
    // should backfill NULL (the backwards-compat contract for every
    // pre-existing session row).
    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('t1', 'foo')", &.{});

    // NULL is mapped to the empty string by COALESCE at the read site
    // (matching the convention used for cwd, created_at, updated_at,
    // and selected_profile_model).
    const v = try scalarText(alloc, &ctx.db, "SELECT COALESCE(s.git_worktree_cwd, '') FROM sessions s WHERE s.id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("", v);
}

// ─── Test 2: explicit value round-trips ──────────────────────────────────

test "Migration046AddGitWorktreeCwdToSessions accepts explicit value" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try Migration046AddGitWorktreeCwdToSessions.up(&ctx.db, alloc);

    try ctx.db.exec(alloc, "INSERT INTO sessions (id, name) VALUES ('t1', 'foo')", &.{});
    try ctx.db.exec(alloc, "UPDATE sessions SET git_worktree_cwd = '/abs/path' WHERE id = 't1'", &.{});

    const v = try scalarText(alloc, &ctx.db, "SELECT s.git_worktree_cwd FROM sessions s WHERE s.id = 't1'", &.{});
    defer alloc.free(v);
    try testing.expectEqualStrings("/abs/path", v);
}

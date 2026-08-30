//! Static + behavioural regression checks for Migration 082
//! (`sessions.last_human_touched_at_nano`).
//!
//! Why this file exists
//! ────────────────────
//! Migration 082 adds a single nullable INTEGER column on `sessions` that
//! stamps the last time a HUMAN (not the AI agent) interacted with a
//! chat. The chat sidebar UI uses this column instead of `updated_at`
//! (which gets bumped by every AI SSE tick) so the visible time pill
//! reads "5m ago" if you touched the chat 5 minutes ago even when the
//! agent has been running since.
//!
//! Sibling of Migration 065 (`workspace_item_tasks.last_human_touched_at`,
//! landed in commit `e07a13f6` for the kanban-task-notification-icon plan).
//! This migration does the same thing for the SESSIONS table — the kanban
//! card already uses the task-side column for its "awaiting review" dot,
//! the sidebar now uses the session-side column for its time pill.
//!
//! The migration must:
//!   1. Add `last_human_touched_at_nano INTEGER` (nullable, no DEFAULT —
//!      NULL = "never touched by a human", which the frontend falls back
//!      to `updated_at` for, so pre-migration sessions keep their old
//!      visible time without a regression).
//!   2. Be idempotent on re-run (re-running must not crash with
//!      "duplicate column name" — see the project's hard-fought
//!      knowledge about fresh-DB migration cascades in
//!      `nalar-data-and-routines.md` §"Migration #009-#052 fresh-DB
//!      cascade is fragile").
//!   3. Be safe for fresh-DB installs that already declare the column
//!      in their canonical CREATE TABLE — use `addColumnIfMissing` so
//!      the helper handles both fresh-DB and upgrade-from-v1 paths.
//!   4. Leave existing rows at NULL (NOT 0 or the current time — same
//!      reasoning as Migration 065: we cannot retroactively know whether
//!      a session from before the migration was "touched").
//!
//! Column name uses the `_nano` suffix per the project-wide convention
//! from Migration 075. The wire field stays bare `last_human_touched_at`.
//!
//! Plan: docs/superpowers/plans/2026-08-29-chat-sidebar-last-human-touched.md
//! Spec: docs/superpowers/specs/2026-08-29-chat-sidebar-last-human-touched-design.md

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;

const Migration082AddSessionHumanTouchedAt = @import("migration.zig").Migration082AddSessionHumanTouchedAt;

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Minimal `sessions` table mirror matching the v17 production shape
/// (no `last_human_touched_at_nano` column yet, that's exactly what the
/// migration adds). The production DB walks migrations 001 → 081 first
/// so a real `sessions` table is already there; we recreate the v17
/// shape here so the test exercises the upgrade path.
fn setupDb() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});
    return .{ .db = db, .threaded = threaded };
}

test "Migration082 adds last_human_touched_at_nano column to sessions" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Sanity: column does NOT exist before the migration.
    {
        var q = try ctx.db.query(alloc,
            \\SELECT 1 FROM pragma_table_info('sessions')
            \\WHERE name = 'last_human_touched_at_nano'
        , &.{});
        defer q.deinit();
        try testing.expect((try q.next()) == null);
    }

    // Apply the migration.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Confirm the column exists with the expected name (NOT "INTEGER"
    // literal — that footgun was caught in Migration 065's test, see
    // project memory `addColumnIfMissing-requires-name-type`).
    var q = try ctx.db.query(alloc,
        \\SELECT name FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ColumnMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("last_human_touched_at_nano", row.values[0]);

    // Confirm exactly one row matched.
    try testing.expect((try q.next()) == null);

    // Type sanity: the column must be INTEGER (so unix-ms comparisons
    // work as arithmetic), not TEXT.
    var qt = try ctx.db.query(alloc,
        \\SELECT type FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qt.deinit();
    const type_row = (try qt.next()) orelse return error.RowMissing;
    defer type_row.deinit(alloc);
    try testing.expectEqualStrings("INTEGER", type_row.values[0]);

    // Nullability sanity: NOT NULL must NOT appear in the column's
    // constraints (the canonical "never touched" state is NULL).
    var qn = try ctx.db.query(alloc,
        \\SELECT "notnull" FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer qn.deinit();
    const nn_row = (try qn.next()) orelse return error.RowMissing;
    defer nn_row.deinit(alloc);
    try testing.expectEqualStrings("0", nn_row.values[0]);
}

test "Migration082 is idempotent on a re-run" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Run the migration once…
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);
    // …and a second time. Must not crash with "duplicate column name".
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Still exactly one column of that name.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration082 is idempotent on a fresh-DB install where the canonical schema already declares the column" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Simulate a fresh-DB install where the canonical CREATE TABLE
    // already includes `last_human_touched_at_nano INTEGER`. The
    // migration must be a no-op (NOT a "duplicate column" crash).
    try ctx.db.exec(alloc, "DROP TABLE sessions", &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'active',
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    last_human_touched_at_nano INTEGER
        \\)
    , &.{});

    // Should not error — addColumnIfMissing detects the column exists.
    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Re-check: still exactly one column.
    var q = try ctx.db.query(alloc,
        \\SELECT COUNT(*) FROM pragma_table_info('sessions')
        \\WHERE name = 'last_human_touched_at_nano'
    , &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "Migration082 leaves pre-existing rows at NULL (not 0, not now)" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Insert one existing session BEFORE applying the migration. Same
    // semantic reasoning as Migration 065: we cannot retroactively
    // know whether the user touched this session before the migration
    // ran, so the value must be NULL — the frontend treats NULL as
    // "fall back to updated_at" which gives legacy sessions their
    // existing visible time without a regression.
    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_pre_082', 'Legacy chat')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // SQL NULL is surfaced as "" by SqliteBackend.query — same
    // convention as Migration 065's test.
    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = 's_pre_082'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("", row.values[0]);
}

test "Migration082 stamps a value when set after the migration" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO sessions (id, name) VALUES ('s_a', 'A')",
        &.{});

    try Migration082AddSessionHumanTouchedAt.up(&ctx.db, alloc);

    // Now stamp a unix-ms timestamp — should persist as the literal
    // integer (formatted as TEXT by SqliteBackend.bind). This is the
    // exact call shape that llm_history.updateSessionLastHumanTouchedAt
    // will use.
    const now_ms_str = try std.fmt.allocPrint(alloc, "{d}", .{@as(i64, 1_786_000_000_000)});
    defer alloc.free(now_ms_str);
    try ctx.db.exec(alloc,
        "UPDATE sessions SET last_human_touched_at_nano = ? WHERE id = ?",
        &[_][]const u8{ now_ms_str, "s_a" });

    var q = try ctx.db.query(alloc,
        "SELECT last_human_touched_at_nano FROM sessions WHERE id = 's_a'",
        &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1786000000000", row.values[0]);
}

test "Migration082 is registered in allMigrations" {
    const all = @import("migration.zig").allMigrations;
    for (all) |m| {
        if (m.version == Migration082AddSessionHumanTouchedAt.version) return;
    }
    return error.Migration082NotRegistered;
}

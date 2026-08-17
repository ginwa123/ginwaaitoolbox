//! Tests for the `update_activity` agent tool path.
//!
//! History
//! ───────
//! This file pre-existed (last touched April 2026 per git blame) but
//! was never registered in any test_runner.zig, so its tests were
//! silently compiled out. The pre-existing tests referenced helpers
//! (`llm_history.upsertWorker`, `llm_history.get_active_workers`)
//! that don't exist in the current codebase — so the file never
//! compiled when wired up.
//!
//! Migration 073 — `session_activity` append-only log — needs to
//! verify that `llm_history.recordSessionActivity` works end-to-end,
//! so this file is now imported from
//! `src/ai_workflow/tui/test_runner.zig`. The dead-code pre-existing
//! tests are removed (they never ran anyway); the
//! `recordSessionActivity` regression tests below are the canonical
//! behavioural checks for the new helper.
//!
//! Convention
//! ──────────
//! Tests walk ALL migrations from scratch so the schema under test is
//! GUARANTEED to match production. No hand-rolled CREATE TABLE.
//! (Project memory `llm-history-test-use-migrations-module.md`.)
//!
//! Plan: docs/superpowers/plans/2026-08-13-session-activity-table.md
//! Task: task_1786629034327 ("new table session_activity")

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Spin up a fresh in-memory DB, walk ALL migrations from 001 → 073
/// so every table the production server has is present (sessions,
/// worker, llm_history, kanban, session_activity, etc.).
fn setupDb() !TestCtx {
    const alloc = std.testing.allocator;
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
// Migration 073 — recordSessionActivity regression tests
// ============================================================================

test "recordSessionActivity inserts a row into session_activity for the given session_id" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = std.testing.allocator;

    const session_id = "test_session_abc";
    const description = "[2026-08-13 10:00] test @ /test | Thinking | Working on it";

    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, description);

    // Exactly 1 row, with the exact session_id + description.
    var q = try ctx.db.query(alloc,
        "SELECT session_id, description FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings(session_id, row.values[0]);
    try std.testing.expectEqualStrings(description, row.values[1]);

    // No further rows.
    try std.testing.expect((try q.next()) == null);
}

test "recordSessionActivity appends a new row each call (same description -> two rows)" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = std.testing.allocator;

    const session_id = "test_session_xyz";
    const description = "[2026-08-13 10:00] test @ /test | Repeated thought";

    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, description);
    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, description);

    // Exactly 2 rows for this session_id.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings("2", row.values[0]);
}

// ============================================================================
// Task 6 — wiring test: execUpdateActivity must do TWO things on success
// ============================================================================
//
// After Migration 073 lands, `execUpdateActivity` must:
//   (a) UPDATE worker.last_activity_description (existing live-UI behaviour).
//   (b) INSERT into session_activity (new historical log).
//
// This test exercises both helpers in sequence against an in-memory
// DB with both tables present, simulating the two side effects of
// the real tool call.

test "wiring: updateWorkerActivityWithDescription + recordSessionActivity both land on success" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = std.testing.allocator;

    const session_id = "test_session_wiring";
    // Pre-register the worker so updateWorkerActivityWithDescription
    // finds a matching row. Production registers workers with
    // `id = session_id` (see workflow.zig's upsert path).
    try ctx.db.exec(alloc,
        "INSERT INTO worker (id, session_id, working_directory) VALUES (?, ?, ?)",
        &.{ session_id, session_id, "/test/cwd" });

    const thought = "[2026-08-13 10:30] test @ /test | Wiring | Both tables updated";
    try llm_history.updateWorkerActivityWithDescription(alloc, &ctx.db, session_id, thought);
    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, thought);

    // Assert: worker table got the UPDATE (existing behaviour preserved).
    {
        var q = try ctx.db.query(alloc,
            "SELECT last_activity_description FROM worker WHERE id = ?",
            &.{session_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.WorkerRowMissing;
        defer row.deinit(alloc);
        try std.testing.expectEqualStrings(thought, row.values[0]);
    }

    // Assert: session_activity got the INSERT (new behaviour).
    var q = try ctx.db.query(alloc,
        "SELECT session_id, description FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.SessionActivityRowMissing;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings(session_id, row.values[0]);
    try std.testing.expectEqualStrings(thought, row.values[1]);
}
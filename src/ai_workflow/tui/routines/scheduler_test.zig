//! Behavioral tests for `Scheduler.zig` (Task 3.1 of the Add Task
//! Routines plan).
//!
//! `Scheduler` is the polling loop that drives routines to fire. It
//! has three public helpers (tested here) and one public `start`
//! function (the infinite loop, not unit-tested — it is exercised by
//! the integration test in Task 3.3):
//!
//!   - `resetStuckRunning`     — flip every `last_status='running'` row
//!                               to `'failed'` with a "process killed"
//!                               error. Called once at startup to
//!                               recover from a previous process crash.
//!   - `recomputeDueNextRunAt` — recompute `next_run_at` for every
//!                               enabled routine. Called once at
//!                               startup so routines that were due
//!                               during downtime fire within 5s of boot.
//!   - `start`                 — the polling loop. NOT tested here.
//!
//! Both tests use the in-memory sqlite pattern from
//! `migration_routines_test.zig` / `model_test.zig` / `fire_test.zig`.
//! The actual SqliteBackend API is `db.query(alloc, sql, args) → Rows →
//! next() → ?Row{ values: [][]u8 }`. Column reads go through
//! `row.values[i]` (a `[]u8` text slice, empty string for NULLs); there
//! is no `.scalar` accessor in this codebase.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("../migration.zig");
const Migration044AddRoutines = migration.Migration044AddRoutines;

const model = @import("model.zig");
const Scheduler = @import("Scheduler.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the pre-Migration-044 state
/// (`workspace_item_tasks` from Migration 034) and run Migration 044
/// to bring it to the post-migration state. Mirrors the helper in
/// `model_test.zig`.
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

    // Minimal schema — the model tests use a slightly richer one with
    // `session_id`/`created_at`/`updated_at`, but `Scheduler` never
    // reads those, so a 3-column parent table is enough.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    try Migration044AddRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Run a single-column SELECT and return a duplicated copy of the
/// first row's first column. Returns null when the query produces no
/// rows. Mirrors the helper in `model_test.zig`.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

// ─── Test 1: resetStuckRunning ────────────────────────────────────────────

test "Scheduler.resetStuckRunning marks running rows as failed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')",
        &.{});
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "*/5 * * * *",
        .initial_prompt = "x",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Simulate a crashed previous process: routine is stuck in 'running'.
    try ctx.db.exec(alloc,
        "UPDATE routines SET last_status = 'running' WHERE id = 'r1'",
        &.{});

    try Scheduler.resetStuckRunning(alloc, &ctx.db);

    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM routines WHERE id = 'r1'", &.{});
    defer if (status) |s| alloc.free(s);
    const err_msg = try scalarText(alloc, &ctx.db,
        "SELECT last_error FROM routines WHERE id = 'r1'", &.{});
    defer if (err_msg) |s| alloc.free(s);

    try testing.expect(status != null);
    try testing.expectEqualStrings("failed", status.?);
    try testing.expect(err_msg != null);
    try testing.expectEqualStrings("process killed (restart detected)", err_msg.?);
}

// ─── Test 2: recomputeDueNextRunAt ────────────────────────────────────────

test "Scheduler.recomputeDueNextRunAt advances rows in the past" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')",
        &.{});
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "0 9 * * *",
        .initial_prompt = "x",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    try Scheduler.recomputeDueNextRunAt(alloc, &ctx.db, ctx.threaded.io());

    const next = try scalarText(alloc, &ctx.db,
        "SELECT next_run_at FROM routines WHERE id = 'r1'", &.{});
    defer if (next) |s| alloc.free(s);

    try testing.expect(next != null);
    // next_run_at should be in the 21st century, at 09:00:00 (cron
    // nextFireTime from now), not stuck at the year 2000.
    try testing.expect(std.mem.indexOf(u8, next.?, " 09:00:00") != null);
    try testing.expect(std.mem.indexOf(u8, next.?, "2000-") == null);
}

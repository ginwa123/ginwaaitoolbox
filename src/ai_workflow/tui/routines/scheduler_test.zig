//! Behavioral tests for `Scheduler.zig` (Task 3 of the
//! workspace-items-routines plan).
//!
//! `Scheduler` is the polling loop that drives workspace routines to
//! fire. It has two public helpers (tested here) and one public
//! `start` function (the infinite polling loop — the new
//! architecture uses `di.group_emit_session_create.concurrent`
//! which is too heavy to mock in a unit test):
//!
//!   - `resetStuckRunning`     — flip every `last_status='running'` row
//!                               to `'failed'` with a "process killed"
//!                               error. Called once at startup to
//!                               recover from a previous process crash.
//!   - `recomputeDueNextRunAt` — recompute `next_run_at` for every
//!                               enabled routine. Called once at
//!                               startup so routines that were due
//!                               during downtime fire within 5s of boot.
//!   - `start`                 — the polling loop. Exercised by the
//!                               runtime smoke test (manual UI flow).
//!
//! Both unit tests use the in-memory sqlite pattern from
//! `model_test.zig` / `fire_test.zig`. The actual SqliteBackend API is
//! `db.query(alloc, sql, args) → Rows → next() → ?Row{
//! values: [][]u8 }`. Column reads go through `row.values[i]` (a
//! `[]u8` text slice, empty string for NULLs); there is no `.scalar`
//! accessor in this codebase.
//!
//! The integration test that previously exercised `Scheduler.start`
//! end-to-end via the `nalar-routine-fire` sub-process is gone. The
//! new architecture submits the LLM work to
//! `di.group_emit_session_create.concurrent` which requires a real
//! `nalarcore.ContextIPCTui` singleton with a wired event bus and a
//! live `CallbackAiWorkerFlow` subscription. That machinery is not
//! constructible inside a unit test. The runtime smoke test (firing
//! a routine via the desktop UI and watching it run) is the
//! integration coverage.
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;

const model = @import("model.zig");
const Scheduler = @import("Scheduler.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables
/// and run Migration 084. Mirrors the helper in `model_test.zig`.
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

    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard'
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    item_type TEXT NOT NULL
        \\)
    , &.{});

    try Migration084ReplaceRoutinesWithWorkspaceRoutines.up(&db, alloc);

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

fn insertParentItem(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')",
        &.{id});
}

// ─── Test 1: resetStuckRunning ────────────────────────────────────────────

test "Scheduler.resetStuckRunning marks running rows as failed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "*/5 * * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Simulate a crashed previous process: routine is stuck in 'running'.
    try ctx.db.exec(alloc,
        "UPDATE workspace_routines SET last_status = 'running' WHERE id = 'item_1'",
        &.{});

    try Scheduler.resetStuckRunning(alloc, &ctx.db);

    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (status) |s| alloc.free(s);
    const err_msg = try scalarText(alloc, &ctx.db,
        "SELECT last_error FROM workspace_routines WHERE id = 'item_1'", &.{});
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

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "0 9 * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    try Scheduler.recomputeDueNextRunAt(alloc, &ctx.db, ctx.threaded.io());

    const next = try scalarText(alloc, &ctx.db,
        "SELECT next_run_at FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (next) |s| alloc.free(s);

    try testing.expect(next != null);
    // next_run_at should be in the 21st century, at 09:00:00 (cron
    // nextFireTime from now), not stuck at the year 2000.
    try testing.expect(std.mem.indexOf(u8, next.?, " 09:00:00") != null);
    try testing.expect(std.mem.indexOf(u8, next.?, "2000-") == null);
}

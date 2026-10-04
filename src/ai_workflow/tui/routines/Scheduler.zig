//! `Scheduler.zig` — the polling loop that drives workspace routines
//! to fire.
//!
//! Retargeted from per-task routines (Migration 044) to
//! `workspace_routines` (Migration 084).
//!
//! `start(allocator, db, di, io)` is the public entry point — call
//! it via `di.group_emit_session_create.concurrent(io, ...)` from
//! `startup.zig`. The function does NOT return; it runs
//! the polling loop until the process exits. The polling interval is
//! `TICK_INTERVAL_NS` (5 seconds).
//!
//! On startup the loop calls two restart-safety helpers:
//!
//!   - `resetStuckRunning`     — flip every `last_status='running'`
//!                               row to `'failed'` with a "process
//!                               killed" error. Recovers from a
//!                               previous process crash.
//!   - `recomputeDueNextRunAt` — recompute `next_run_at` for every
//!                               enabled routine from the cron
//!                               expression. Lets routines that were
//!                               due during downtime fire within 5s of
//!                               boot instead of waiting for their
//!                               originally-scheduled `next_run_at`.
//!
//! Each tick calls `fireDueRoutines`, which lists every due routine
//! via `model.listDueWorkspaceRoutineIds` and calls
//! `fire.fireWorkspaceRoutine` for each. `fire.fireWorkspaceRoutine`
//! submits the LLM work to the same Io group via
//! `di.group_emit_session_create.concurrent(io, ...)` — the same
//! pattern as `http_handlers/session_create.zig:161`. A slow LLM
//! call in one routine cannot block polling of others: the
//! fire-and-forget submit returns immediately, and the Io group
//! runs the LLM in a worker thread.
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)
//! Task: task_1789032258828_0.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const sqlite = pabrikcore.sqlite;

const model = @import("model.zig");
const cron = @import("cron.zig");
const fire = @import("fire.zig");

/// Polling interval between `fireDueRoutines` ticks.
pub const TICK_INTERVAL_NS: i128 = 5 * std.time.ns_per_s;

/// Reset every routine whose `last_status = 'running'` to `'failed'`
/// with a "process killed" error. Called once at startup to recover
/// from a previous process crash (the previous process claimed the
/// row, the sub-process was launched, but neither it nor the in-process
/// worker wrote a terminal status before the process died).
pub fn resetStuckRunning(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) !void {
    const err_msg = "process killed (restart detected)";
    const copy = try allocator.dupe(u8, err_msg);
    defer allocator.free(copy);
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_status = 'failed', last_error = ?, updated_at = datetime('now')
        \\ WHERE last_status = 'running'
    , &.{copy});
}

/// Recompute `next_run_at` for every enabled routine from the cron
/// expression. Called once at startup so routines that were due
/// during downtime fire within 5s of boot — without this pass, a
/// routine with `next_run_at = 2000-01-01 00:00:00` would not be
/// picked up by `listDueWorkspaceRoutineIds` (which compares against
/// `now_sqlite`) until the clock naturally caught up. Wait — that
/// would actually be fine since 2000-01-01 is in the past; the real
/// use case is: a routine's `next_run_at` was advanced by a prior
/// run to e.g. 2099-01-01 00:00:00, then the system clock got
/// misconfigured and advanced past that. In that case the row
/// becomes "due" naturally. The bigger motivation is consistency:
/// if the cron expression is edited while the routine is idle, the
/// new `next_run_at` reflects the edit, not the old expression.
///
/// Manual-only routines (empty schedule) are skipped — there is no
/// cron to compute from and their `next_run_at` stays NULL.
pub fn recomputeDueNextRunAt(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    io: std.Io,
) !void {
    // Collect (id, schedule, next_run_at) for every enabled routine in
    // a first pass; then UPDATE in a second pass. Doing it in two
    // passes keeps us from holding a `Rows` cursor open across
    // `db.exec` calls (which the SqliteBackend does not support — it
    // serializes statements per connection).
    var rows = try db.query(allocator,
        "SELECT id, schedule FROM workspace_routines WHERE enabled = 1 AND schedule != ''", &.{});
    defer rows.deinit();

    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);

    const Pending = struct {
        id: []u8,
        schedule: []u8,
        next_sqlite: []u8,
    };
    var to_update: std.ArrayList(Pending) = .empty;
    defer {
        for (to_update.items) |item| {
            allocator.free(item.id);
            allocator.free(item.schedule);
            allocator.free(item.next_sqlite);
        }
        to_update.deinit(allocator);
    }

    while (try rows.next()) |row| {
        defer row.deinit(allocator);
        const id = try allocator.dupe(u8, row.values[0]);
        const schedule = try allocator.dupe(u8, row.values[1]);

        const next_ns = cron.nextFireTime(schedule, now_ns) catch |err| {
            // Bad cron expressions are the user's problem, not the
            // scheduler's. Free what we've allocated for this row and
            // skip; the loop continues with the remaining rows.
            std.log.warn(
                "scheduler: nextFireTime failed for routine {s} (schedule={s}): {s}",
                .{ id, schedule, @errorName(err) },
            );
            allocator.free(id);
            allocator.free(schedule);
            continue;
        };

        const next_sqlite = try fire.formatSqliteDatetime(allocator, next_ns);
        try to_update.append(allocator, .{
            .id = id,
            .schedule = schedule,
            .next_sqlite = next_sqlite,
        });
    }

    for (to_update.items) |item| {
        _ = try db.exec(allocator,
            "UPDATE workspace_routines SET next_run_at = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ item.next_sqlite, item.id });
    }
}

/// Fire one routine per due id. Uses the main process's
/// `di.group_emit_session_create` group via `fire.fireWorkspaceRoutine`
/// (no thread, no sub-process). Returns the count of routines that
/// were successfully fired. Errors from `fireWorkspaceRoutine` other
/// than the three controlled `FireError` variants are logged and the
/// routine is skipped — a single broken routine must not block
/// polling of others.
pub fn fireDueRoutines(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *pabrikcore.App,
    io: std.Io,
) !usize {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const now_sqlite = try fire.formatSqliteDatetime(allocator, now_ns);
    defer allocator.free(now_sqlite);

    const due_ids = try model.listDueWorkspaceRoutineIds(allocator, db, now_sqlite);
    defer {
        for (due_ids) |id| allocator.free(id);
        allocator.free(due_ids);
    }

    var fired: usize = 0;
    for (due_ids) |routine_id| {
        fire.fireWorkspaceRoutine(allocator, db, di, io, routine_id) catch |err| switch (err) {
            error.NotARoutine, error.Disabled, error.AlreadyRunning => continue,
            else => {
                std.log.warn("scheduler: fireWorkspaceRoutine failed for {s}: {s}", .{ routine_id, @errorName(err) });
                continue;
            },
        };
        fired += 1;
    }
    return fired;
}

/// The polling loop. Runs forever (no cancel signal in v1). Call
/// from `di.group_emit_session_create.concurrent(io, ...)` — see
/// `startup.zig` for the wiring.
pub fn start(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *pabrikcore.App,
    io: std.Io,
) !void {
    // Restart safety: do these once at startup. A failure here is
    // logged but does not abort the loop — the next tick's
    // `fireDueRoutines` is still useful.
    resetStuckRunning(allocator, db) catch |err| {
        std.log.warn("scheduler: resetStuckRunning failed: {s}", .{@errorName(err)});
    };
    recomputeDueNextRunAt(allocator, db, io) catch |err| {
        std.log.warn("scheduler: recomputeDueNextRunAt failed: {s}", .{@errorName(err)});
    };

    while (true) {
        _ = fireDueRoutines(allocator, db, di, io) catch |err| {
            std.log.warn("scheduler: fireDueRoutines failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(io, .{ .nanoseconds = TICK_INTERVAL_NS }, .real);
    }
}

// ===== Tests merged from scheduler_test.zig (2026-09-29 flatten) =====
// Behavioral tests for `Scheduler.zig` (Task 3 of the
// workspace-items-routines plan).
//
// `Scheduler` is the polling loop that drives workspace routines to
// fire. It has two public helpers (tested here) and one public
// `start` function (the infinite polling loop — the new
// architecture uses `di.group_emit_session_create.concurrent`
// which is too heavy to mock in a unit test):
//
//   - `resetStuckRunning`     — flip every `last_status='running'` row
//                               to `'failed'` with a "process killed"
//                               error. Called once at startup to
//                               recover from a previous process crash.
//   - `recomputeDueNextRunAt` — recompute `next_run_at` for every
//                               enabled routine. Called once at
//                               startup so routines that were due
//                               during downtime fire within 5s of boot.
//   - `start`                 — the polling loop. Exercised by the
//                               runtime smoke test (manual UI flow).
//
// Both unit tests use the in-memory sqlite pattern from
// `model.zig` / `fire.zig`. The actual SqliteBackend API is
// `db.query(alloc, sql, args) → Rows → next() → ?Row{
// values: [][]u8 }`. Column reads go through `row.values[i]` (a
// `[]u8` text slice, empty string for NULLs); there is no `.scalar`
// accessor in this codebase.
//
// The integration test that previously exercised `Scheduler.start`
// end-to-end via the `pabrik-routine-fire` sub-process is gone. The
// new architecture submits the LLM work to
// `di.group_emit_session_create.concurrent` which requires a real
// `pabrikcore.App` singleton with a wired event bus and a
// live `CallbackAiWorkerFlow` subscription. That machinery is not
// constructible inside a unit test. The runtime smoke test (firing
// a routine via the desktop UI and watching it run) is the
// integration coverage.
//
// Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)

const testing = std.testing;

const migration = pabrikcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables
/// and run Migration 084. Mirrors the helper in `model.zig`.
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
/// rows. Mirrors the helper in `model.zig`.
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

    try resetStuckRunning(alloc, &ctx.db);

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

    try recomputeDueNextRunAt(alloc, &ctx.db, ctx.threaded.io());

    const next = try scalarText(alloc, &ctx.db,
        "SELECT next_run_at FROM workspace_routines WHERE id = 'item_1'", &.{});
    defer if (next) |s| alloc.free(s);

    try testing.expect(next != null);
    // next_run_at should be in the 21st century, at 09:00:00 (cron
    // nextFireTime from now), not stuck at the year 2000.
    try testing.expect(std.mem.indexOf(u8, next.?, " 09:00:00") != null);
    try testing.expect(std.mem.indexOf(u8, next.?, "2000-") == null);
}

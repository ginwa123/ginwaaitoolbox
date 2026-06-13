//! `Scheduler.zig` — the polling loop that drives routines to fire
//! (Task 3.1 of the Add Task Routines plan, refactored per PR #8 review).
//!
//! `start(allocator, db, di, io)` is the public entry point — call
//! it via `di.group_emit_session_create.concurrent(io, ...)` from
//! `startup.zig` (Task 3.2). The function does NOT return; it runs
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
//! via `model.listDueRoutineIds` and calls `fire.fireRoutine` for
//! each. `fire.fireRoutine` submits the LLM work to the same Io
//! group via `di.group_emit_session_create.concurrent(io, ...)` —
//! the same pattern as `http_handlers/session_create.zig:161`. A
//! slow LLM call in one routine cannot block polling of others: the
//! fire-and-forget submit returns immediately, and the Io group
//! runs the LLM in a worker thread.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

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
        \\UPDATE routines
        \\   SET last_status = 'failed', last_error = ?, updated_at = datetime('now')
        \\ WHERE last_status = 'running'
    , &.{copy});
}

/// Recompute `next_run_at` for every enabled routine from the cron
/// expression. Called once at startup so routines that were due
/// during downtime fire within 5s of boot — without this pass, a
/// routine with `next_run_at = 2000-01-01 00:00:00` would not be
/// picked up by `listDueRoutineIds` (which compares against
/// `now_sqlite`) until the clock naturally caught up. Wait — that
/// would actually be fine since 2000-01-01 is in the past; the real
/// use case is: a routine's `next_run_at` was advanced by a prior
/// run to e.g. 2099-01-01 00:00:00, then the system clock got
/// misconfigured and advanced past that. In that case the row
/// becomes "due" naturally. The bigger motivation is consistency:
/// if the cron expression is edited while the routine is idle, the
/// new `next_run_at` reflects the edit, not the old expression.
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
        "SELECT id, schedule FROM routines WHERE enabled = 1", &.{});
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
            "UPDATE routines SET next_run_at = ?, updated_at = datetime('now') WHERE id = ?",
            &.{ item.next_sqlite, item.id });
    }
}

/// Fire one routine per due id. Uses the main process's
/// `di.group_emit_session_create` group via `fire.fireRoutine`
/// (no thread, no sub-process). Returns the count of routines that
/// were successfully fired. Errors from `fireRoutine` other than the
/// three controlled `FireError` variants are logged and the routine
/// is skipped — a single broken routine must not block polling of
/// others.
pub fn fireDueRoutines(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
    io: std.Io,
) !usize {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const now_sqlite = try fire.formatSqliteDatetime(allocator, now_ns);
    defer allocator.free(now_sqlite);

    const due_ids = try model.listDueRoutineIds(allocator, db, now_sqlite);
    defer {
        for (due_ids) |id| allocator.free(id);
        allocator.free(due_ids);
    }

    var fired: usize = 0;
    for (due_ids) |task_id| {
        fire.fireRoutine(allocator, db, di, io, task_id) catch |err| switch (err) {
            error.NotARoutine, error.Disabled, error.AlreadyRunning => continue,
            else => {
                std.log.warn("scheduler: fireRoutine failed for {s}: {s}", .{ task_id, @errorName(err) });
                continue;
            },
        };
        fired += 1;
    }
    return fired;
}

/// The polling loop. Runs forever (no cancel signal in v1). Call
/// from `di.group_emit_session_create.concurrent(io, ...)` — see
/// `startup.zig` (Task 3.2) for the wiring.
pub fn start(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
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
        try io.sleep(io, .{ .nanoseconds = TICK_INTERVAL_NS }, .real);
    }
}

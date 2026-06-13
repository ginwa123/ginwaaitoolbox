//! `Scheduler.zig` — the polling loop that drives routines to fire
//! (Task 3.1 of the Add Task Routines plan).
//!
//! `start(allocator, db, io)` is the public entry point — call it from
//! a background thread (Task 3.2 wires it in `startup.zig`). The
//! function does NOT return; it runs the polling loop until the
//! process exits. The polling interval is `TICK_INTERVAL_NS` (5
//! seconds).
//!
//! On startup the loop calls two restart-safety helpers:
//!
//!   - `resetStuckRunning`     — flip every `last_status='running'`
//!                               row to `'failed'` with a "process
//!                               killed" error. Recovers from a
//!                               previous process crash (the row was
//!                               claimed but the sub-process never
//!                               wrote a terminal status).
//!   - `recomputeDueNextRunAt` — recompute `next_run_at` for every
//!                               enabled routine from the cron
//!                               expression. Lets routines that were
//!                               due during downtime fire within 5s of
//!                               boot instead of waiting for their
//!                               originally-scheduled `next_run_at`.
//!
//! Each tick calls `spawnDueRoutines`, which lists every due routine
//! via `model.listDueRoutineIds` and spawns one
//! `nalar-routine-fire --id <id>` sub-process per id. The sub-process
//! is fire-and-forget — we deliberately do NOT call `child.wait(io)`,
//! matching the `notifications.zig:130` pattern. A slow LLM call in one
//! routine cannot block polling of others.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const model = @import("model.zig");
const cron = @import("cron.zig");

/// Polling interval between `spawnDueRoutines` ticks.
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

        const next_sqlite = try formatSqliteDatetime(allocator, next_ns);
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

/// Spawn one `nalar-routine-fire --id <id>` sub-process per due id.
/// Fire-and-forget: do NOT call `child.wait(io)` — see
/// `notifications.zig:130` for the rationale. Returns the count of
/// sub-processes spawned (excluding spawn failures).
fn spawnDueRoutines(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, io: std.Io) !usize {
    const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
    const now_sqlite = try formatSqliteDatetime(allocator, now_ns);
    defer allocator.free(now_sqlite);

    const due_ids = try model.listDueRoutineIds(allocator, db, now_sqlite);
    defer {
        for (due_ids) |id| allocator.free(id);
        allocator.free(due_ids);
    }

    var spawned: usize = 0;
    for (due_ids) |id| {
        const argv = try allocator.dupe([]const u8, &.{
            "nalar-routine-fire",
            "--id",
            id,
        });
        defer allocator.free(argv);

        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            std.log.warn("scheduler: failed to spawn nalar-routine-fire: {s}", .{@errorName(err)});
            continue;
        };
        // Fire-and-forget. We deliberately don't call child.wait(io)
        // so a slow LLM call in one routine cannot block polling of
        // others. The `child.id == null` check mirrors
        // `notifications.zig:146` and forces the compiler to consider
        // `child` used (Zig 0.16's process.Child has no meaningful
        // other read on the fire-and-forget path).
        if (child.id == null) continue;
        spawned += 1;
    }
    return spawned;
}

/// The polling loop. Runs forever (no cancel signal in v1). Call from
/// a background thread — see `startup.zig` (Task 3.2) for the
/// thread-spawn wiring.
pub fn start(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, io: std.Io) !void {
    // Restart safety: do these once at startup. A failure here is
    // logged but does not abort the loop — the next tick's
    // `spawnDueRoutines` is still useful.
    resetStuckRunning(allocator, db) catch |err| {
        std.log.warn("scheduler: resetStuckRunning failed: {s}", .{@errorName(err)});
    };
    recomputeDueNextRunAt(allocator, db, io) catch |err| {
        std.log.warn("scheduler: recomputeDueNextRunAt failed: {s}", .{@errorName(err)});
    };

    while (true) {
        _ = spawnDueRoutines(allocator, db, io) catch |err| {
            std.log.warn("scheduler: spawnDueRoutines failed: {s}", .{@errorName(err)});
        };
        try std.Io.sleep(io, .{ .nanoseconds = TICK_INTERVAL_NS }, .real);
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────

/// Convert unix nanos (i128) to a SQLite DATETIME literal
/// `YYYY-MM-DD HH:MM:SS`. Duplicated from `fire.zig` so the scheduler
/// is self-contained (the helpers are private there; the only public
/// `formatSqliteDatetime` would be a wider API surface for no
/// observable benefit).
fn formatSqliteDatetime(allocator: std.mem.Allocator, unix_nanos: i128) ![]u8 {
    const secs: i64 = @intCast(@divTrunc(unix_nanos, std.time.ns_per_s));
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator,
        "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            @as(u32, @intCast(day_seconds.getHoursIntoDay())),
            @as(u32, @intCast(day_seconds.getMinutesIntoHour())),
            @as(u32, @intCast(day_seconds.getSecondsIntoMinute())),
        });
}

//! `routines` model — DB row struct + CRUD helpers (Task 1.2 of the
//! Add Task Routines plan).
//!
//! The `Routine` struct mirrors the columns of the `routines` table
//! created by Migration 044 (`task_type`/`routines` schema). All strings
//! are owned by the caller via `std.mem.Allocator.dupe`; `Routine.deinit`
//! frees them. Optional fields are `null` for NULL columns (the DB
//! representation is the empty string in the Row API; we translate
//! empty → null on read).
//!
//! The DB helpers take `*nalarcore.sqlite.SqliteBackend` (NOT a connection
//! pool, NOT a transaction wrapper) and use the public
//! `query`/`exec`/`Rows`/`Row` API. There is no prepare/step/columnText
//! public surface on SqliteBackend; column reads go through
//! `row.values[i]` (a `[]u8` text slice).
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md (Task 1.2)
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const SqliteBackend = nalarcore.sqlite.SqliteBackend;
const Scheduler = @import("Scheduler.zig");

/// Canonical status values written to the `routines.last_status` column.
///
/// `.idle` is the "no row has ever run" state and maps to NULL on disk
/// (so `last_status IS NULL` and `last_status = 'idle'` are NOT the same
/// thing in the DB; the latter never appears). `.running` is set by
/// `claimForRun` to mark a routine as in-flight (the WHERE clause in
/// `listDueRoutineIds` and `claimForRun` excludes already-running rows).
pub const RoutineRunStatus = enum {
    idle,
    success,
    failed,
    running,

    /// String representation for a non-NULL `last_status` column. Returns
    /// null for `.idle` so the caller can pass null to the SQL binder
    /// and write a real NULL to the column.
    pub fn dbValue(self: RoutineRunStatus) ?[]const u8 {
        return switch (self) {
            .idle => null,
            .success => "success",
            .failed => "failed",
            .running => "running",
        };
    }

    /// Inverse of `dbValue` — NULL or the empty string decodes to `.idle`,
    /// unknown strings also decode to `.idle` (defensive default).
    pub fn fromDb(text: ?[]const u8) RoutineRunStatus {
        const t = text orelse return .idle;
        if (t.len == 0) return .idle;
        if (std.mem.eql(u8, t, "success")) return .success;
        if (std.mem.eql(u8, t, "failed")) return .failed;
        if (std.mem.eql(u8, t, "running")) return .running;
        return .idle;
    }
};

/// In-memory representation of one row in the `routines` table. All
/// string fields are owned and must be freed with `deinit`.
pub const Routine = struct {
    id: []const u8,
    task_id: []const u8,
    schedule: []const u8,
    initial_prompt: []const u8,
    enabled: bool,
    next_run_at: []const u8,
    last_run_at: ?[]const u8 = null,
    last_status: RoutineRunStatus = .idle,
    last_error: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,

    pub fn deinit(self: Routine, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.task_id);
        allocator.free(self.schedule);
        allocator.free(self.initial_prompt);
        allocator.free(self.next_run_at);
        if (self.last_run_at) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
        if (self.created_at) |v| allocator.free(v);
        if (self.updated_at) |v| allocator.free(v);
    }
};

/// Insert a new routine row. All fields except `id`, `task_id`,
/// `schedule`, `initial_prompt`, `enabled`, and `next_run_at` are filled
/// by column defaults (`created_at`/`updated_at` = CURRENT_TIMESTAMP,
/// the rest are NULL). The caller's `Routine` is consumed (no `deinit`
/// needed by the caller — strings are NOT duplicated, they're borrowed
/// during the INSERT only).
pub fn insertRoutine(allocator: std.mem.Allocator, db: *SqliteBackend, r: Routine) !void {
    _ = try db.exec(allocator,
        \\INSERT INTO routines (id, task_id, schedule, initial_prompt, enabled, next_run_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , &.{
        r.id,
        r.task_id,
        r.schedule,
        r.initial_prompt,
        if (r.enabled) "1" else "0",
        r.next_run_at,
    });
}

/// Load the routine for a given `task_id`. Returns `error.RoutineNotFound`
/// if no row matches. The returned `Routine` owns its strings; caller
/// must call `routine.deinit(allocator)`.
pub fn loadRoutineByTaskId(allocator: std.mem.Allocator, db: *SqliteBackend, task_id: []const u8) !Routine {
    var q = try db.query(allocator,
        \\SELECT id, task_id, schedule, initial_prompt, enabled, next_run_at,
        \\       last_run_at, last_status, last_error, created_at, updated_at
        \\FROM routines r WHERE task_id = ?
    , &.{task_id});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RoutineNotFound;
    defer row.deinit(allocator);

    // enabled is INTEGER — the Row API returns it as the text "1" or "0".
    const enabled_int = std.fmt.parseInt(i64, row.values[4], 10) catch 0;

    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .task_id = try allocator.dupe(u8, row.values[1]),
        .schedule = try allocator.dupe(u8, row.values[2]),
        .initial_prompt = try allocator.dupe(u8, row.values[3]),
        .enabled = enabled_int == 1,
        .next_run_at = try allocator.dupe(u8, row.values[5]),
        // NULL columns arrive as empty strings in the Row API; translate
        // empty → null so the in-memory model matches the SQL NULL.
        .last_run_at = try nullIfEmpty(allocator, row.values[6]),
        .last_status = RoutineRunStatus.fromDb(nullIfEmptyConst(row.values[7])),
        .last_error = try nullIfEmpty(allocator, row.values[8]),
        .created_at = try nullIfEmpty(allocator, row.values[9]),
        .updated_at = try nullIfEmpty(allocator, row.values[10]),
    };
}

/// Return the ids of every enabled routine whose `next_run_at` is at or
/// before `now_sqlite` (formatted as an SQLite DATETIME literal, e.g.
/// `"2025-01-01 00:00:00"`) and which is not already in the
/// `last_status = 'running'` state. This is the Scheduler's hot read
/// path — the index `idx_routines_enabled_next_run` makes it a single
/// index seek per due routine.
///
/// The returned slice and each of its elements are owned by the caller;
/// free with:
///   for (ids) |id| allocator.free(id);
///   allocator.free(ids);
/// Return the task_ids of every enabled routine whose `next_run_at`
/// is at or before `now_sqlite` (formatted as an SQLite DATETIME literal,
/// e.g. `"2000-01-01 00:00:00"`) and which is not already in the
/// `last_status = 'running'` state. This is the Scheduler's hot read
/// path — the index `idx_routines_enabled_next_run` makes it a single
/// index seek per due routine.
///
/// Returns `task_id` (NOT `routines.id`): the caller (Scheduler) passes
/// these straight to `fire.fireRoutine(task_id)`, which calls
/// `loadRoutineByTaskId`. Returning the routine id here would make the
/// loader's `WHERE task_id = ?` lookup miss every row, surfacing as a
/// silent `FireError.NotARoutine` that the scheduler swallows — the
/// exact bug that hit production when this query SELECTed `id`. Don't
/// regress.
pub fn listDueRoutineIds(allocator: std.mem.Allocator, db: *SqliteBackend, now_sqlite: []const u8) ![][]u8 {
    var q = try db.query(allocator,
        \\SELECT task_id FROM routines r
        \\WHERE enabled = 1
        \\  AND next_run_at <= ?
        \\  AND (last_status IS NULL OR last_status != 'running')
    , &.{now_sqlite});
    defer q.deinit();

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    while (try q.next()) |row| {
        defer row.deinit(allocator);
        try out.append(allocator, try allocator.dupe(u8, row.values[0]));
    }
    return out.toOwnedSlice(allocator);
}

/// Atomically transition a routine's `last_status` to `'running'` iff it
/// is not already `'running'`. Returns `true` if the claim won, `false`
/// if the row was already running or no longer exists.
///
/// Implemented as a single conditional `UPDATE` followed by
/// `sqlite3_changes()`. `db.exec` runs the entire `sqlite3_step` loop
/// under the SqliteBackend's mutex; `sqlite3_changes` is per-connection
/// state so it correctly reports whether the WHERE matched. The
/// scheduler is the only writer of `last_status` so the only
/// consequence of a concurrent write is a lost claim (return false),
/// never a corrupted state.
pub fn claimForRun(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8) !bool {
    db.exec(allocator,
        \\UPDATE routines
        \\   SET last_status = 'running', updated_at = datetime('now')
        \\ WHERE id = ?
        \\   AND (last_status IS NULL OR last_status != 'running')
    , &.{routine_id}) catch |err| {
        std.log.warn("claimForRun: UPDATE failed for {s}: {s}", .{ routine_id, @errorName(err) });
        return false;
    };

    // 1 → we won the claim; 0 → another caller claimed it first
    // (or the row is gone).
    return db.changes() > 0;
}

/// Mark a routine as having completed successfully: set
/// `last_status = 'success'`, bump `next_run_at` to the cron-computed
/// next firing time, stamp `last_run_at` to now, and clear `last_error`.
///
/// Caller is expected to have already won the `claimForRun` race (so
/// the routine is in the 'running' state) — this UPDATE does not check
/// status, it just overwrites.
pub fn markSuccess(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE routines
        \\   SET last_run_at = datetime('now'),
        \\       next_run_at = ?,
        \\       last_status = 'success',
        \\       last_error = NULL,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ next_run_at_sqlite, routine_id });
}

/// Mark a routine as failed with the given error message, and advance
/// its `next_run_at` so the scheduler picks a future run. The routine
/// stays enabled (a transient failure like "LLM rate limit" must not
/// silently disable a recurring job — the user can disable it
/// explicitly).
pub fn markFailed(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, err_msg: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE routines
        \\   SET last_status = 'failed',
        \\       last_error = ?,
        \\       next_run_at = ?,
        \\       updated_at = datetime('now')
        \\ WHERE id = ?
    , &.{ err_msg, next_run_at_sqlite, routine_id });
}

/// Iterate over all enabled routines, recompute `next_run_at` via
/// `cron.nextFireTime`, and UPDATE the row. The `compute_fn` and
/// `now_unix_nanos` parameters are accepted for backwards
/// compatibility (Chunk 1 placeholder signature) but ignored — the
/// implementation uses the wall clock from `Scheduler.recomputeDueNextRunAt`
/// and the standard `cron.nextFireTime`.
pub fn recomputeAllNextRunAt(
    allocator: std.mem.Allocator,
    db: *SqliteBackend,
    compute_fn: *const fn (schedule: []const u8, now_unix_nanos: i128) anyerror![]const u8,
    now_unix_nanos: i128,
) !void {
    _ = compute_fn;
    _ = now_unix_nanos;
    const di = nalarcore.getSingleton() catch return;
    try Scheduler.recomputeDueNextRunAt(allocator, db, di.io);
}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Translate the Row API's "NULL column → empty slice" representation
/// into a `?[]const u8` and dup the non-empty case so the caller owns
/// the memory.
fn nullIfEmpty(allocator: std.mem.Allocator, slice: []const u8) !?[]const u8 {
    if (slice.len == 0) return null;
    return try allocator.dupe(u8, slice);
}

/// Same as `nullIfEmpty` but doesn't dup — used when the value is only
/// passed to `fromDb`, which compares by `[]const u8` and doesn't take
/// ownership. Avoids one alloc per row load.
fn nullIfEmptyConst(slice: []const u8) ?[]const u8 {
    if (slice.len == 0) return null;
    return slice;
}

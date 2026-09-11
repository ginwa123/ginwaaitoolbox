//! `workspace_routines` model — DB row struct + CRUD helpers.
//!
//! Retargeted from the deleted per-task `routines` table (Migration
//! 044) to `workspace_routines` (Migration 084). The `Routine` struct
//! mirrors the new table's columns; all strings are owned by the
//! caller via `std.mem.Allocator.dupe`; `Routine.deinit` frees them.
//! Optional fields are `null` for NULL columns (the DB
//! representation is the empty string in the Row API; we translate
//! empty → null on read).
//!
//! The DB helpers take `*nalarcore.sqlite.SqliteBackend` (NOT a connection
//! pool, NOT a transaction wrapper) and use the public
//! `query`/`exec`/`Rows`/`Row` API. There is no prepare/step/columnText
//! public surface on SqliteBackend; column reads go through
//! `row.values[i]` (a `[]u8` text slice).
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)
//! Task: task_1789032258828_0.

const std = @import("std");
const nalarcore = @import("nalarcore");
const SqliteBackend = nalarcore.sqlite.SqliteBackend;
const Scheduler = @import("Scheduler.zig");

/// Canonical status values written to the `workspace_routines.last_status`
/// column.
///
/// `.idle` is the "no row has ever run" state and maps to `'idle'` on
/// disk (the column is `NOT NULL DEFAULT 'idle'` — unlike the old
/// per-task table where idle was NULL). `.running` is set by
/// `claimForRun` to mark a routine as in-flight (the WHERE clause in
/// `listDueWorkspaceRoutineIds` and `claimForRun` excludes
/// already-running rows).
pub const RoutineRunStatus = enum {
    idle,
    success,
    failed,
    running,

    /// String representation for the `last_status` column.
    pub fn dbValue(self: RoutineRunStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
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

/// In-memory representation of one row in the `workspace_routines`
/// table. All string fields are owned and must be freed with `deinit`.
pub const Routine = struct {
    id: []const u8,
    workspace_item_id: []const u8,
    description: []const u8 = "",
    instruction: []const u8 = "",
    schedule: []const u8 = "",
    enabled: bool,
    next_run_at: ?[]const u8 = null,
    last_run_at: ?[]const u8 = null,
    last_status: RoutineRunStatus = .idle,
    last_error: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,

    pub fn deinit(self: Routine, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.workspace_item_id);
        if (self.description.len > 0) allocator.free(self.description);
        if (self.instruction.len > 0) allocator.free(self.instruction);
        if (self.schedule.len > 0) allocator.free(self.schedule);
        if (self.next_run_at) |v| allocator.free(v);
        if (self.last_run_at) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
        if (self.created_at) |v| allocator.free(v);
        if (self.updated_at) |v| allocator.free(v);
    }
};

/// Insert a new routine row. `next_run_at` null writes SQL NULL
/// (manual-run only). Text columns use `COALESCE(NULLIF(?, ''), '')`
/// because `SqliteBackend.exec` binds empty slices as SQL NULL, which
/// would violate the `NOT NULL DEFAULT ''` constraints (see memory
/// `sqlite-backend-empty-slice-binds-as-null`).
pub fn insertWorkspaceRoutine(allocator: std.mem.Allocator, db: *SqliteBackend, r: Routine) !void {
    _ = try db.exec(allocator,
        \\INSERT INTO workspace_routines (id, workspace_item_id, description, instruction, schedule, enabled, next_run_at)
        \\VALUES (?, ?, COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), COALESCE(NULLIF(?, ''), ''), ?, ?)
    , &.{
        r.id,
        r.workspace_item_id,
        r.description,
        r.instruction,
        r.schedule,
        if (r.enabled) "1" else "0",
        r.next_run_at orelse "",
    });
}

/// Load the routine for a given workspace-routine `id` (which equals
/// its `workspace_item_id` per the D3 identity). Returns
/// `error.RoutineNotFound` if no row matches. The returned `Routine`
/// owns its strings; caller must call `routine.deinit(allocator)`.
pub fn loadWorkspaceRoutineById(allocator: std.mem.Allocator, db: *SqliteBackend, id: []const u8) !Routine {
    var q = try db.query(allocator,
        \\SELECT id, workspace_item_id, description, instruction, schedule, enabled, next_run_at,
        \\       last_run_at, last_status, last_error, created_at, updated_at
        \\FROM workspace_routines WHERE id = ?
    , &.{id});
    defer q.deinit();

    const row = (try q.next()) orelse return error.RoutineNotFound;
    defer row.deinit(allocator);

    // enabled is INTEGER — the Row API returns it as the text "1" or "0".
    const enabled_int = std.fmt.parseInt(i64, row.values[5], 10) catch 0;

    return .{
        .id = try allocator.dupe(u8, row.values[0]),
        .workspace_item_id = try allocator.dupe(u8, row.values[1]),
        .description = try allocator.dupe(u8, row.values[2]),
        .instruction = try allocator.dupe(u8, row.values[3]),
        .schedule = try allocator.dupe(u8, row.values[4]),
        .enabled = enabled_int == 1,
        .next_run_at = try nullIfEmpty(allocator, row.values[6]),
        // NULL columns arrive as empty strings in the Row API; translate
        // empty → null so the in-memory model matches the SQL NULL.
        .last_run_at = try nullIfEmpty(allocator, row.values[7]),
        .last_status = RoutineRunStatus.fromDb(nullIfEmptyConst(row.values[8])),
        .last_error = try nullIfEmpty(allocator, row.values[9]),
        .created_at = try nullIfEmpty(allocator, row.values[10]),
        .updated_at = try nullIfEmpty(allocator, row.values[11]),
    };
}

/// Return the ids of every enabled routine whose `next_run_at` is at or
/// before `now_sqlite` (formatted as an SQLite DATETIME literal, e.g.
/// `"2025-01-01 00:00:00"`) and which is not already in the
/// `last_status = 'running'` state. This is the Scheduler's hot read
/// path — the index `idx_workspace_routines_enabled_next_run` makes it
/// a single index seek per due routine.
///
/// Manual-only routines (`next_run_at IS NULL`) never match: any
/// comparison against NULL is NULL, not true.
///
/// The returned slice and each of its elements are owned by the caller;
/// free with:
///   for (ids) |id| allocator.free(id);
///   allocator.free(ids);
pub fn listDueWorkspaceRoutineIds(allocator: std.mem.Allocator, db: *SqliteBackend, now_sqlite: []const u8) ![][]u8 {
    var q = try db.query(allocator,
        \\SELECT id FROM workspace_routines
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
        \\UPDATE workspace_routines
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
/// A null (empty) `next_run_at_sqlite` writes SQL NULL (manual-only
/// routine — no next fire).
///
/// Caller is expected to have already won the `claimForRun` race (so
/// the routine is in the 'running' state) — this UPDATE does not check
/// status, it just overwrites.
pub fn markSuccess(allocator: std.mem.Allocator, db: *SqliteBackend, routine_id: []const u8, next_run_at_sqlite: []const u8) !void {
    _ = try db.exec(allocator,
        \\UPDATE workspace_routines
        \\   SET last_run_at = datetime('now'),
        \\       next_run_at = ?,
        \\       last_status = 'success',
        \\       last_error = '',
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
        \\UPDATE workspace_routines
        \\   SET last_status = 'failed',
        \\       last_error = COALESCE(NULLIF(?, ''), ''),
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

/// Dupe a Row-API text slice, translating the empty string (SQL NULL)
/// to Zig null.
fn nullIfEmpty(allocator: std.mem.Allocator, v: []const u8) !?[]u8 {
    if (v.len == 0) return null;
    return try allocator.dupe(u8, v);
}

/// Non-allocating variant for `fromDb` inputs.
fn nullIfEmptyConst(v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    return v;
}

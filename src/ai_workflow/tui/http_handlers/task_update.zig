const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = nalarcore.llm_history;
const cron = @import("../routines/cron.zig");
const fire = @import("../routines/fire.zig");

/// PUT /api/workspaces/tasks/:task_id - Update task by ID only (no workspace/item needed).
///
/// Body: { name?, session_id?, schedule?, initial_prompt?, enabled? }.
/// Standard fields (name, session_id) keep the existing cascade paths.
/// Routine fields (schedule, initial_prompt, enabled) are validated and
/// persisted to the `routines` table; on a schedule change, `next_run_at`
/// is recomputed via `cron.nextFireTime`. Routine fields are optional —
/// a plain task update that omits them is a no-op for the routines table.
///
/// Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md
pub fn tasksUpdateByIdHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return updateTaskHandler(ctx, req, res);
}

/// PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
/// (Same body and behavior as tasksUpdateByIdHandler.)
pub fn tasksUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    return updateTaskHandler(ctx, req, res);
}

// =====================================================================
// Error set + input/output types for the useCase
// =====================================================================

pub const TaskUpdateError = error{
    OutOfMemory,
    InvalidJson,
    MissingBody,
    BadCron,
    MissingRoutineSchedule,
    MissingRoutineInitialPrompt,
    InvalidCronExpression,
    FailedToComputeNextFireTime,
    FailedToUpdateRoutine,
    FailedToUpdateTask,
};

/// Slice of optional fields the client may send. Mirrors
/// `http_response.TaskUpdateRequest` but expressed as a struct-local type
/// to avoid a forced include in this file.
const TaskUpdateInput = struct {
    task_id: []const u8,
    body: http_response.TaskUpdateRequest,
    db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
};

/// Result of a successful task update. The handler serializes the
/// `id` field into a small `{"success":true,"id":"..."}` JSON response.
const TaskUpdateResult = struct {
    task_id: []const u8,
};

// =====================================================================
// Handler
// =====================================================================

/// Shared implementation for both task-update routes. The two
/// registrations differ only in URL shape; the body parsing, cascade
/// logic, and routine-fields branch are identical.
fn updateTaskHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // Parse request body
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskUpdateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const result = useCase(allocator, .{
        .task_id = task_id,
        .body = json_body,
        .db = sqlite_db,
        .io = ctx.io,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.InvalidCronExpression => 400,
            error.MissingRoutineSchedule => 400,
            error.MissingRoutineInitialPrompt => 400,
            error.FailedToComputeNextFireTime => 400,
            error.FailedToUpdateRoutine => 500,
            error.FailedToUpdateTask => 500,
            error.MissingBody => 400,
            error.BadCron => 400,
            error.InvalidJson => 400,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.InvalidJson => "Invalid JSON",
            error.MissingBody => "Request body required",
            error.BadCron => "Invalid cron expression",
            error.MissingRoutineSchedule => "schedule is required for routine updates",
            error.MissingRoutineInitialPrompt => "initial_prompt is required for routine updates",
            error.InvalidCronExpression => "Invalid cron expression",
            error.FailedToComputeNextFireTime => "Failed to compute next fire time",
            error.FailedToUpdateRoutine => "Failed to update routine",
            error.FailedToUpdateTask => "Failed to update task",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{result.task_id}) });
}

// =====================================================================
// useCase
// =====================================================================

fn useCase(allocator: std.mem.Allocator, input: TaskUpdateInput) TaskUpdateError!TaskUpdateResult {
    const task_id = input.task_id;

    // Routine-fields branch. If ANY routine field is present in the
    // request body, validate the schedule (if changed), recompute
    // `next_run_at`, and persist to the `routines` table.
    //
    // We use `INSERT OR REPLACE INTO routines` (rather than `UPDATE … WHERE
    // task_id = ?`) so a standard task that gets promoted to a routine
    // via this endpoint gets a fresh `routines` row. The `id` is the
    // stable `routine_{task_id}` key (matching the create handler), so
    // a re-INSERT just replaces the existing row in place.
    if (input.body.schedule != null or input.body.initial_prompt != null or input.body.enabled != null) {
        try updateRoutineFields(allocator, input.db, input.io, task_id, input.body);
    }

    // Description branch. When `body.description` is present (non-null),
    // overwrite the column with the new value. Empty string is the
    // canonical "no description" sentinel and IS persisted (NOT
    // skipped) — the user actively cleared the field, which the UI
    // renders as the "Add a description…" placeholder. Null means
    // "leave unchanged" (the caller didn't include the field in the
    // PUT body). Migration 061 added the column.
    //
    // Workaround for `SqliteBackend.exec` binding empty `[]const u8`
    // slices as SQL NULL (see project memory
    // `sqlite-backend-empty-slice-binds-as-null`): the column is
    // NOT NULL DEFAULT '' so binding NULL would fail with
    // `NOT NULL constraint failed`. We special-case the empty
    // string path to use the SQL `''` literal directly (a non-empty
    // string literal — SQLite binds it as the empty string, not NULL).
    if (input.body.description) |desc| {
        if (desc.len == 0) {
            input.db.exec(
                allocator,
                "UPDATE workspace_item_tasks SET description = '', updated_at = datetime('now') WHERE id = ?",
                &[_][]const u8{task_id},
            ) catch return error.FailedToUpdateTask;
        } else {
            input.db.exec(
                allocator,
                "UPDATE workspace_item_tasks SET description = ?, updated_at = datetime('now') WHERE id = ?",
                &[_][]const u8{ desc, task_id },
            ) catch return error.FailedToUpdateTask;
        }
    }

    // Conditional split: route name updates through the cascade
    // (updateTaskName → updateSessionName → SSE broadcast). The
    // legacy `session_id` body field is accepted for backward
    // compatibility (older client builds may still send it) but
    // is a no-op — `task.id` IS the session id per the
    // `task.id == session_id` convention (Migration 052 dropped
    // the redundant column).
    if (input.body.name) |n| {
        llm_history.updateTaskName(allocator, input.db, task_id, n) catch {
            return error.FailedToUpdateTask;
        };
    }

    return .{ .task_id = task_id };
}

/// Validate + recompute `next_run_at` + INSERT OR REPLACE the routines row
/// for `task_id` (creates a fresh row if the task is being promoted from
/// a standard task to a routine).
fn updateRoutineFields(
    allocator: std.mem.Allocator,
    sqlite_db: *nalarcore.sqlite.SqliteBackend,
    io: std.Io,
    task_id: []const u8,
    json_body: http_response.TaskUpdateRequest,
) TaskUpdateError!void {
    // Validate the cron (if a new schedule was provided). Bad cron
    // → 400 with no DB write.
    if (json_body.schedule) |schedule| {
        cron.validate(schedule) catch return error.InvalidCronExpression;
    }

    // Pull the existing routines row (if any) so we can substitute
    // missing fields. Use the public model helper.
    var existing_schedule: ?[]u8 = null;
    var existing_initial_prompt: ?[]u8 = null;
    var existing_enabled_int: []const u8 = "1";
    var existing_next_run_at: ?[]u8 = null;
    defer if (existing_schedule) |s| allocator.free(s);
    defer if (existing_initial_prompt) |p| allocator.free(p);
    defer if (existing_next_run_at) |n| allocator.free(n);

    if (loadExistingRoutine(allocator, sqlite_db, task_id)) |loaded| {
        existing_schedule = loaded.schedule;
        existing_initial_prompt = loaded.initial_prompt;
        existing_enabled_int = loaded.enabled_int;
        existing_next_run_at = loaded.next_run_at;
    } else |_| {
        // No existing routines row — this is a promote-to-routine
        // case. All substituted values are the column defaults.
        existing_next_run_at = null;
    }

    // Effective values (client value or existing default).
    const effective_schedule = json_body.schedule orelse existing_schedule orelse
        return error.MissingRoutineSchedule;
    const effective_initial_prompt = json_body.initial_prompt orelse existing_initial_prompt orelse
        return error.MissingRoutineInitialPrompt;
    const effective_enabled_str: []const u8 = if (json_body.enabled) |e|
        (if (e) "1" else "0")
    else
        existing_enabled_int;

    // Recompute next_run_at if the schedule is new (or no prior
    // row exists). The `fire.formatSqliteDatetime` helper produces
    // a "YYYY-MM-DD HH:MM:SS" string compatible with the
    // `routines.next_run_at` DATETIME column. Mirrors the create
    // handler's pattern.
    var next_run_at_owned: ?[]u8 = null;
    defer if (next_run_at_owned) |n| allocator.free(n);
    const next_run_at: []const u8 = if (json_body.schedule != null) blk: {
        const now_ns: i128 = std.Io.Timestamp.now(io, .real).nanoseconds;
        const next_ns = cron.nextFireTime(effective_schedule, now_ns) catch {
            return error.FailedToComputeNextFireTime;
        };
        const formatted = try fire.formatSqliteDatetime(allocator, next_ns);
        next_run_at_owned = formatted;
        break :blk formatted;
    } else existing_next_run_at orelse return error.MissingRoutineSchedule;

    // INSERT OR REPLACE: idempotent for the existing-row case,
    // creates a fresh row for the promote-from-standard case. The
    // `routine_{task_id}` id is stable (matches the create handler),
    // so subsequent calls just overwrite.
    const routine_id = try std.fmt.allocPrint(allocator, "routine_{s}", .{task_id});
    defer allocator.free(routine_id);
    sqlite_db.exec(allocator,
        "INSERT OR REPLACE INTO routines (id, task_id, schedule, initial_prompt, enabled, next_run_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, datetime('now'))",
        &[_][]const u8{ routine_id, task_id, effective_schedule, effective_initial_prompt, effective_enabled_str, next_run_at },
    ) catch return error.FailedToUpdateRoutine;
}

/// Snapshot of an existing `routines` row, with the raw TEXT values
/// the column stores (so we can re-INSERT them verbatim). Returns
/// `error.RoutineNotFound` if no row exists for `task_id`.
const ExistingRoutineSnapshot = struct {
    schedule: []u8,
    initial_prompt: []u8,
    enabled_int: []u8,
    next_run_at: []u8,
};

/// Load the columns of the `routines` row for `task_id` (if any) as
/// raw TEXT slices — used by the update handler to substitute missing
/// client fields before the INSERT OR REPLACE. Returns
/// `error.RoutineNotFound` when the row is missing. The caller's arena
/// (the per-request `ctx.allocator`) owns the returned strings.
fn loadExistingRoutine(allocator: std.mem.Allocator, db: *nalarcore.sqlite.SqliteBackend, task_id: []const u8) !ExistingRoutineSnapshot {
    var q = try db.query(allocator,
        "SELECT schedule, initial_prompt, enabled, next_run_at FROM routines r WHERE task_id = ?",
        &[_][]const u8{task_id},
    );
    defer q.deinit();
    const row = (try q.next()) orelse return error.RoutineNotFound;
    defer row.deinit(allocator);
    return .{
        .schedule = try allocator.dupe(u8, row.values[0]),
        .initial_prompt = try allocator.dupe(u8, row.values[1]),
        .enabled_int = try allocator.dupe(u8, row.values[2]),
        .next_run_at = try allocator.dupe(u8, row.values[3]),
    };
}

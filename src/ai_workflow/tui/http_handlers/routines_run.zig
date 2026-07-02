//! `POST /api/workspaces/:w/items/:i/tasks/:tid/run` — manual fire.
//!
//! Triggers a single immediate fire of a routine task. Returns the session id
//! (which equals the task id per the project's `task.id == session.id`
//! invariant for routine tasks).
//!
//! Calls `fire.fireRoutine(allocator, db, di, io, task_id)` directly — the
//! routine fire is submitted to the main process's Io group via
//! `di.group_emit_session_create.concurrent` (PR #8 architecture). No
//! sub-process, no separate thread.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunk-4.md
//!   (Task 4.4).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const fire = @import("../routines/fire.zig");

pub const RoutinesRunError = error{
    OutOfMemory,
    MissingTaskId,
    GlobalContextNotInitialized,
};

/// Use case input. The handler builds this from the request and passes it in.
const RoutinesRunInput = struct {
    task_id: []const u8,
    io: std.Io,
};

/// Use case result. Packed into the 200 OK response as
/// `{"success":true,"session_id":"<task_id>","status":"firing"}`.
const RoutinesRunResult = struct {
    task_id: []const u8,
};

/// Manual fire endpoint.
///
/// `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/run`
///
/// On success: `200 OK` with `{"success":true,"session_id":"<task_id>","status":"firing"}`.
///
/// Error mapping:
///   - missing `task_id`        → 400
///   - `error.GlobalContextNotInitialized` → 500 (singleton not yet set)
///   - `FireError.NotARoutine`  → 404
///   - `FireError.Disabled`     → 409
///   - `FireError.AlreadyRunning` → 409
///   - any other error          → 500
pub fn routinesRunHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const task_id = req.params.get("task_id") orelse "";

    const result = useCase(allocator, .{
        .task_id = task_id,
        .io = ctx.io,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.MissingTaskId => 400,
            error.GlobalContextNotInitialized => 500,
            error.RoutineNotFound => 404,
            error.RoutineDisabled => 409,
            error.RoutineAlreadyRunning => 409,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingTaskId => "task_id required",
            error.GlobalContextNotInitialized => "singleton not initialized",
            error.RoutineNotFound => "task is not a routine",
            error.RoutineDisabled => "routine is disabled",
            error.RoutineAlreadyRunning => "routine is already running",
            else => "fire failed",
        };
        return res.jsonResponse(.{ .status_code = status, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }) });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"session_id\":\"{s}\",\"status\":\"firing\"}}", .{result.task_id}),
    });
}

fn useCase(allocator: std.mem.Allocator, input: RoutinesRunInput) (RoutinesRunError || fire.FireError)!RoutinesRunResult {
    if (input.task_id.len == 0) return error.MissingTaskId;

    // The handler gets the Io group via the singleton — must call
    // `nalarcore.getSingleton()` to obtain the initialized `ContextIPCTui`
    // (which carries the Io group via `di.group_emit_session_create`).
    const di = nalarcore.getSingleton() catch return error.GlobalContextNotInitialized;
    const sqlite_db = di.db;

    // Call the fire pipeline. Errors map to HTTP status codes:
    //   - FireError.NotARoutine    → 404 (task is not a routine)
    //   - FireError.Disabled       → 409 (routine is disabled)
    //   - FireError.AlreadyRunning → 409 (routine is already running)
    //   - other                    → 500
    fire.fireRoutine(allocator, sqlite_db, di, input.io, input.task_id) catch |err| {
        std.log.err("routinesRunHandler: fireRoutine failed: {s}", .{@errorName(err)});
        return err;
    };

    return .{ .task_id = input.task_id };
}
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
    const io = ctx.io;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // Call the fire pipeline. Errors map to HTTP status codes:
    //   - FireError.NotARoutine    → 404
    //   - FireError.Disabled       → 409
    //   - FireError.AlreadyRunning → 409
    //   - other                    → 500
    fire.fireRoutine(allocator, sqlite_db, di, io, task_id) catch |err| switch (err) {
        fire.FireError.NotARoutine => return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task is not a routine" }),
        }),
        fire.FireError.Disabled => return res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine is disabled" }),
        }),
        fire.FireError.AlreadyRunning => return res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine is already running" }),
        }),
        else => {
            std.log.err("routinesRunHandler: fireRoutine failed: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "fire failed" }),
            });
        },
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"session_id\":\"{s}\",\"status\":\"firing\"}}", .{task_id}),
    });
}

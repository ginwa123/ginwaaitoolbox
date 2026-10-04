//! `POST /api/workspaces/:ws/items/:item/routines/:routine_id/run` —
//! manual fire of a workspace routine.
//!
//! Triggers a single immediate fire. Returns the routine id as
//! `session_id` (every fire of a routine appends to the same session
//! chat — the workspace-level analogue of the old
//! `task.id == session.id` convention).
//!
//! Calls `fire.fireWorkspaceRoutine(allocator, db, di, io,
//! routine_id)` directly — the fire is submitted to the main
//! process's Io group via `di.group_emit_session_create.concurrent`.
//! No sub-process, no separate thread.
//!
//! The routine is scoped to the parent item: a `routine_id` whose
//! `workspace_item_id` differs from `:item` returns 404 (same
//! item-scoping rule as the knowledge/tools sub-handlers).
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)
//! Task: task_1789032258828_0.

const std = @import("std");
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const http_response = @import("http_response.zig");
const fire = @import("../ai_workflow/tui/routines/fire.zig");
const model = @import("../ai_workflow/tui/routines/model.zig");

/// Manual fire endpoint.
///
/// `POST /api/workspaces/:workspace_id/items/:item_id/routines/:routine_id/run`
///
/// On success: `200 OK` with
/// `{"success":true,"session_id":"<routine_id>","status":"firing"}`.
///
/// Error mapping:
///   - missing `routine_id`        → 400
///   - `error.GlobalContextNotInitialized` → 500 (singleton not yet set)
///   - unknown id / wrong item     → 404
///   - `FireError.NotARoutine`     → 404
///   - `FireError.Disabled`        → 409
///   - `FireError.AlreadyRunning`  → 409
///   - any other error             → 500
pub fn workspaceRoutinesRunHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    const routine_id = req.params.get("routine_id") orelse "";
    if (routine_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine_id required" }),
        });
    }
    const item_id = req.params.get("item_id") orelse "";

    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // Item scoping: the routine must belong to the parent item in the
    // URL. A mismatch (or a missing row) is a 404 — never leak one
    // item's routine through another item's URL.
    if (item_id.len > 0) {
        const routine = model.loadWorkspaceRoutineById(allocator, sqlite_db, routine_id) catch {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine not found" }),
            });
        };
        defer routine.deinit(allocator);
        if (!std.mem.eql(u8, routine.workspace_item_id, item_id)) {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine not found" }),
            });
        }
    }

    // Call the fire pipeline. Errors map to HTTP status codes:
    //   - FireError.NotARoutine    → 404
    //   - FireError.Disabled       → 409
    //   - FireError.AlreadyRunning → 409
    //   - other                    → 500
    fire.fireWorkspaceRoutine(allocator, sqlite_db, di, io, routine_id) catch |err| switch (err) {
        fire.FireError.NotARoutine => return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "routine not found" }),
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
            std.log.err("workspaceRoutinesRunHandler: fireWorkspaceRoutine failed: {s}", .{@errorName(err)});
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "fire failed" }),
            });
        },
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"session_id\":\"{s}\",\"status\":\"firing\"}}", .{routine_id}),
    });
}

//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`
//! — trigger an LLM worker on an existing task's session WITHOUT queueing
//! a new user message.
//!
//! The agent resumes (or starts on) the chat history already in the
//! session. For tasks with no chat history, the agent responds based on
//! its system prompt alone — typically an offer-to-help clarification.
//!
//! Wire shape — note the difference from `POST /api/llm/session`:
//!   - No request body. All inputs come from the URL path.
//!   - `queue_message` is NOT accepted (the whole point of this
//!     endpoint is to trigger a worker WITHOUT queueing a message).
//!   - The workflow's `runAgenticMultiStepnew` is told via the new
//!     `skip_initial_queue_message: true` flag (see root.zig +
//!     workflow.zig) to skip its initial `insertQueueMessage` call.
//!
//! Errors:
//!   - 400 — `task_id` is missing or empty
//!   - 404 — task does not exist in `workspace_item_tasks`
//!   - 409 — a worker is already running for this task's session
//!   - 500 — singleton not initialized, DB failure, or `emit_run_agent` failure
//!
//! Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const sqlite = nalarcore.sqlite;
const http_response = @import("http_response.zig");

/// Trigger endpoint.
///
/// `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`
///
/// On success: `200 OK` with `{"success":true,"session_id":"<task_id>","status":"triggered"}`.
pub fn startAgentHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

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

    // 1) Validate the task exists. Use the same single-row lookup that
    //    task_delete.zig uses — `getWorkspaceItemTask` returns `null`
    //    when the row is absent (vs. propagating a NOT_FOUND error).
    const task_opt = ai_mod.workspace_item_tasks.getWorkspaceItemTask(allocator, sqlite_db, task_id) catch null;
    const task = task_opt orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task not found" }),
        });
    };
    defer task.deinit(allocator);

    // 2) Reject if a worker is currently running. This is the
    //    primary guard against double-trigger; the frontend's
    //    `:disabled` state is best-effort. We check the worker
    //    table's `session_id` column (per the nalar convention
    //    `task.id == session.id`) via `isTaskRunning`.
    if (ai_mod.llm_history.isTaskRunning(allocator, sqlite_db, task_id)) {
        return res.jsonResponse(.{
            .status_code = 409,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worker already running" }),
        });
    }

    // 3) Read the session row so we can forward selected_profile_model
    //    + is_auto_retry_until_stop to the worker pool. The session
    //    row is created by the prior `/api/llm/session` POST or by
    //    `fireRoutine`; if neither has run for this task, the
    //    `insert_worker` step in `emit_run_agent` will upsert one
    //    using the task's name + cwd (matches the routine-fire
    //    pre-insert pattern). DB errors propagate to the function's
    //    caller (the router maps them to 500).
    var session_row = try sqlite_db.query(
        allocator,
        "SELECT COALESCE(selected_profile_model, ''), COALESCE(is_auto_retry_until_stop, '0') FROM sessions WHERE id = ?",
        &.{task_id},
    );
    defer session_row.deinit();

    var session_profile: []const u8 = "";
    var session_auto_retry: []const u8 = "0";
    if (try session_row.next()) |row| {
        defer row.deinit(allocator);
        if (row.values.len >= 2) {
            session_profile = row.values[0];
            session_auto_retry = row.values[1];
        }
    }

    // 4) Submit the LLM work to the Io group. The handler is a thin
    //    wrapper around `di.emit_run_agent` — same pattern as
    //    `routines_run.zig` (which wraps `fire.fireRoutine`). The
    //    new `skip_initial_queue_message: true` flag tells
    //    `runAgenticMultiStepnew` to skip its initial `insertQueueMessage`
    //    call, so the agent loop runs on the existing chat history
    //    alone. Empty `queue_message` is required (any value would be
    //    inserted into the queue without the flag).
    const resolved_cwd: []const u8 = if (task.cwd.len > 0) task.cwd else "";

    di.emit_run_agent(.{
        .session_id = task_id,
        .session_name = task.name,
        .queue_message = "",
        .cwd = resolved_cwd,
        .body_message = "",
        .allowed_tools = "",
        .image_urls = "",
        .selected_profile_model = session_profile,
        .is_auto_retry_until_stop = session_auto_retry,
        // NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
        // Tells the workflow to skip the initial insertQueueMessage.
        .skip_initial_queue_message = true,
    }) catch |err| {
        std.log.err("start_agent: emit_run_agent failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "emit_run_agent failed" }),
        });
    };

    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"session_id\":\"{s}\",\"status\":\"triggered\"}}", .{task_id}),
    });
}
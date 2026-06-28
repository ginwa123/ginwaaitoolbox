//! HTTP handler + use-case for `DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`.
//!
//! ## File structure
//!
//! This file holds BOTH the use-case (pure function over the DB and Io)
//! and the HTTP handler (thin orchestrator that validates the path
//! param, calls the use-case, and maps the outcome to an HTTP response):
//!
//! - `TaskDeleteOutcome` — the tagged union returned by the use-case
//!   (`deleted` / `running`). The handler maps each variant to a
//!   specific HTTP status code.
//! - `deleteTaskUseCase` — the **use-case** (pure-ish function; reads
//!   from the DB, performs cleanup, deletes the task row). The
//!   running-check is the new pre-flight validation: if the worker
//!   table has a row with `session_id = task_id` (per the project's
//!   `task.id == session.id` convention), the use-case refuses with
//!   `.running` and the handler maps that to HTTP 409 Conflict.
//! - `tasksDeleteHandler` — the **HTTP handler** (orchestrator).
//! - Sub-helpers — small focused functions used by the handler
//!   (response builders).
//!
//! ## Memory model
//!
//! Per the project convention (see `custom-http-server-per-request-arena`
//! memory), this handler does NOT add `defer allocator.free(...)` for
//! request-scoped allocations. The per-request `ArenaAllocator` reaps
//! them when the request finishes.
//!
//! ## Why the running-check matters
//!
//! Without the pre-flight check, deleting a task whose LLM call is
//! in-flight (streaming chunks via SSE, running tools, etc.) leaves the
//! worker process holding a stale row reference and the frontend's
//! chat view with a "task deleted" state while the worker is still
//! writing messages. Refusing the delete with 409 lets the frontend
//! prompt the user to stop the session first.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const memories_mod = nalarcore.memories;

// =====================================================================
// Domain types
// =====================================================================

/// Outcome of `deleteTaskUseCase`.
///
/// `.deleted` is the success outcome — the use-case either removed an
/// existing task (with all cleanup) or found no task to remove
/// (idempotent DELETE; matches the pre-refactor behavior).
///
/// `.running` means the task exists in `workspace_item_tasks` AND a
/// worker row exists in `worker` with `session_id = task_id`. The
/// handler maps this to 409 Conflict. The payload is the worker id
/// (the primary key of the running worker) so the response can hint
/// "task is currently running (worker_id=X). Stop it first." when
/// useful for debugging.
pub const TaskDeleteOutcome = union(enum) {
    deleted,
    running: []const u8,
};

// =====================================================================
// Use-case (pure-ish)
// =====================================================================

/// Delete a workspace-item task. Returns `.deleted` on success
/// (including the idempotent "task did not exist" case) or
/// `.running { worker_id }` when a worker is currently processing
/// the task.
///
/// Side effects on `.deleted`:
///   - For memory tasks: the underlying .md file in
///     `<workspace_item.path>/.nalar/memories/<name>.md` is removed
///     (idempotent — no-op if already missing).
///   - For routine tasks: the matching row in `routines` is removed
///     so the scheduler does not pick up a routine whose task no
///     longer exists.
///   - The `workspace_item_tasks` row is removed last.
///
/// On `.running`: NO side effects. The task row is left untouched so
/// the running worker can complete and the frontend can decide what
/// to do (typically: call `POST /sessions/:id/stop` first, then retry).
///
/// Errors:
///   - `error.OutOfMemory` — allocator failure (propagated up).
///   - DB errors during cleanup propagate as `error{...}` from the
///     underlying `db.exec`. The task row is left untouched when a
///     cleanup step fails (no partial-delete).
pub fn deleteTaskUseCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *nalarcore.sqlite.SqliteBackend,
    task_id: []const u8,
) !TaskDeleteOutcome {
    // 1. Look up the task so we can:
    //    a) check the worker table for an in-flight session,
    //    b) clean up associated resources (routines row, .md file).
    const task_opt = ai_mod.workspace_item_tasks.getWorkspaceItemTask(allocator, db, task_id) catch null;
    if (task_opt) |task| {
        defer task.deinit(allocator);

        // 2. Refuse if the task is currently running. The worker
        //    table's `session_id` column holds the task id (the
        //    project's `task.id == session.id` convention). A row
        //    there means the LLM is streaming or a tool is running;
        //    deleting now would orphan the worker's state.
        //
        //    We do this BEFORE any cleanup so a refused delete leaves
        //    the task (and its routines / .md file) exactly as it was.
        if (ai_mod.llm_history.isTaskRunning(db, task_id)) {
            // Look up the running worker's id so the 409 response
            // can include it (helpful for debugging — the frontend
            // can map worker_id back to its SSE stream).
            const worker_id = getRunningWorkerId(allocator, db, task_id) catch "";
            return .{ .running = worker_id };
        }

        // 3a. Memory-task cleanup: delete the .md file from
        //     `<workspace_item.path>/.nalar/memories/<task_name>`. We
        //     only attempt this if the parent workspace_item still
        //     exists and has a path (otherwise the file is
        //     unreachable anyway).
        if (std.mem.eql(u8, task.task_type, "memory")) {
            const item_opt = ai_mod.workspace_item_tasks.getWorkspaceItem(allocator, db, task.workspace_item_id) catch null;
            if (item_opt) |item| {
                defer item.deinit(allocator);
                if (item.path) |cwd| {
                    if (memories_mod.get_local_memories_path_for_dir(allocator, cwd)) |dir_path| {
                        defer allocator.free(dir_path);
                        // The .md filename == task.name. The name
                        // passes isValidMemoryName today (the
                        // create handler validates it), but be
                        // defensive — the helper returns false
                        // safely on invalid input.
                        _ = memories_mod.deleteLocalMemoryFile(allocator, io, dir_path, task.name);
                    }
                }
            }
        }

        // 3b. Routine-task cleanup: delete the routines row.
        //     Standard tasks have no extra table.
        if (std.mem.eql(u8, task.task_type, "routine")) {
            db.exec(allocator,
                "DELETE FROM routines WHERE task_id = ?",
                &[_][]const u8{task_id},
            ) catch {
                // Don't delete the task row if the routines row
                // couldn't be removed — the scheduler would otherwise
                // fire an orphan routine on the next tick. Return
                // the error to the caller.
                return error.RoutineCleanupFailed;
            };
        }
    } else {
        // Task doesn't exist — same as the pre-refactor behavior,
        // fall through and let the DELETE be idempotent (DELETE on a
        // missing row is a no-op at the SQL level).
    }

    // 4. Delete the task row itself. This is a no-op when the row
    //    didn't exist (idempotent DELETE).
    ai_mod.workspace_item_tasks.deleteWorkspaceItemTask(allocator, db, task_id) catch {
        return error.TaskDeleteFailed;
    };

    return .deleted;
}

/// Look up the running worker id for a task (the primary key of the
/// row in `worker` whose `session_id = task_id`). Returns "" if no
/// worker is found or on query failure (the caller treats "" as
/// "running but unknown worker id" — the 409 message still surfaces).
fn getRunningWorkerId(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    task_id: []const u8,
) ![]const u8 {
    const sql = "SELECT id FROM worker WHERE session_id = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{task_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        return try allocator.dupe(u8, row.values[0]);
    }
    return try allocator.dupe(u8, "");
}

// =====================================================================
// Handler
// =====================================================================

/// `DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`.
///
/// Thin orchestrator over `deleteTaskUseCase`:
///   1. validate `:task_id` path parameter (inline)
///   2. resolve DB handle via `nalarcore.getSingleton`
///   3. `deleteTaskUseCase` (use-case)
///   4. map outcome to HTTP response (200 / 409 / 500)
///
/// Returns:
///   - 200 OK with `{success: true, id}` on `.deleted`
///   - 409 Conflict with `{error: "Task is currently running…"}` on `.running`
///   - 500 Internal Server Error on use-case failure
pub fn tasksDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Validate `:task_id` path parameter.
    const task_id = req.params.get("task_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    };
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    // 2. Resolve DB handle via the nalar singleton.
    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Internal error" }) });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case.
    const outcome = deleteTaskUseCase(allocator, io, sqlite_db, task_id) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{
            .@"error" = switch (err) {
                error.RoutineCleanupFailed => "Failed to delete routine row",
                error.TaskDeleteFailed => "Failed to delete task",
            },
        }) });
    };

    // 4. Map the use-case outcome to an HTTP response.
    switch (outcome) {
        .deleted => {
            return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTaskDeleteResponse(allocator, .{ .id = task_id, .success = true }) });
        },
        .running => |worker_id| {
            const msg = if (worker_id.len > 0)
                try std.fmt.allocPrint(allocator, "Task is currently running (worker_id={s}). Stop the session before deleting.", .{worker_id})
            else
                try allocator.dupe(u8, "Task is currently running. Stop the session before deleting.");
            // The arena reaps msg when the request finishes — no
            // explicit free needed (per-request arena pattern).
            return res.jsonResponse(.{ .status_code = 409, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = msg }) });
        },
    }
}

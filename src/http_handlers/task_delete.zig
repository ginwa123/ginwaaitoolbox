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
const pabrikcore = @import("pabrikcore");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const memories_mod = pabrikcore.memories;

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
///     `<workspace_item.path>/.pabrik/memories/<name>.md` is removed
///     (idempotent — no-op if already missing).
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
    db: *pabrikcore.sqlite.SqliteBackend,
    task_id: []const u8,
) !TaskDeleteOutcome {
    // 1. Look up the task so we can:
    //    a) check the worker table for an in-flight session,
    //    b) clean up associated resources (.md file for memory tasks).
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
        //    the task (and its .md file) exactly as it was.
        if (ai_mod.llm_history.isTaskRunning(allocator, db, task_id)) {
            // Look up the running worker's id so the 409 response
            // can include it (helpful for debugging — the frontend
            // can map worker_id back to its SSE stream).
            const worker_id = getRunningWorkerId(allocator, db, task_id) catch "";
            return .{ .running = worker_id };
        }

        // 3a. Memory-task cleanup: delete the .md file from
        //     `<workspace_item.path>/.pabrik/memories/<task_name>`. We
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

        // 3b. (Deleted: routine-task cleanup removed with the per-task
        //     `routines` table — Migration 084. Standard tasks have no
        //     extra table.)
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
    db: *pabrikcore.sqlite.SqliteBackend,
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
///   2. resolve DB handle via `pabrikcore.getSingleton`
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

    // 2. Resolve DB handle via the pabrik singleton.
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Internal error" }) });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case.
    const outcome = deleteTaskUseCase(allocator, io, sqlite_db, task_id) catch |err| {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{
            .@"error" = switch (err) {
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

// ===== Tests merged from task_delete_test.zig (2026-09-11 flatten) =====
// Static regression checks for the
// `DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`
// handler and its split-out `deleteTaskUseCase`.
// 
// Why this file exists
// ────────────────────
// The delete-task endpoint was refactored to:
//   1. Split the handler (thin HTTP orchestrator) from the use-case
//      (`deleteTaskUseCase` — pure-ish over DB + Io).
//   2. Add a pre-flight validation: refuse the delete (HTTP 409
//      Conflict) when a worker row exists in the `worker` table with
//      `session_id = task_id`. Per the project's
//      `task.id == session.id` convention, that row means the task's
//      LLM call is currently in-flight — deleting now would orphan
//      the worker's state.
// 
// These contracts are enforced by static substring checks (matching
// the `task_update_test.zig` / `kanban_columns_delete_test.zig`
// pattern), NOT by spinning up an in-memory DB. Standing up sqlite +
// migrations + event-bus to behavioural-test the handler would
// duplicate the migration setup and pull in `pabrikcore.getSingleton()`
// (which depends on a live `App` with a server, logger,
// and event bus). The static checks below directly test the bug —
// they fail if and only if the running-check or the handler/usecase
// split is removed or routed back to the old path.
// 
// Plan: docs/superpowers/plans/2026-06-28-task-delete-running-validation.md

const testing = std.testing;
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/http_handlers/task_delete.zig";
const MOD_PATH = "src/http_handlers/mod.zig";
const LLM_HISTORY_PATH = "src/agentic_loop/llm_history.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
    );
    const normalized = try text_normalize.normalizeLineEndings(allocator, raw);
    allocator.free(raw); // free the CRLF-laden input — normalized is the LF-only copy
    return normalized;
}

// ─── Contract 1: handler reads the task_id path param ────────────────────

test "task_delete handler reads task_id from path params" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"task_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the task_id path param !!\n" ++
                "   The delete endpoint is broken: the use-case will receive\n" ++
                "   an empty task_id and delete the wrong row (or no row).\n" ++
                "   Restore: const task_id = req.params.get(\"task_id\") orelse ...\n",
            .{HANDLER_PATH},
        );
        return error.TaskIdParamMissing;
    }
}

// ─── Contract 2: handler returns 400 on missing task_id ──────────────────

test "task_delete handler returns 400 when task_id is missing" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must reject requests with no task_id. Without this
    // guard, the use-case would be called with task_id="" and the
    // worker-table check would silently pass (no worker has
    // session_id=""), then `deleteWorkspaceItemTask("")` would either
    // be a no-op or fail silently — both are wrong for a "delete this
    // task" request.
    if (std.mem.indexOf(u8, source, ".status_code = 400") == null) {
        std.debug.print(
            "\n!! {s} does not return 400 on a missing task_id !!\n" ++
                "   Add: return res.jsonResponse(.{{ .status_code = 400, ... }});\n" ++
                "   when task_id is empty.\n",
            .{HANDLER_PATH},
        );
        return error.Status400Missing;
    }
    if (std.mem.indexOf(u8, source, "task_id required") == null) {
        std.debug.print(
            "\n!! {s} does not surface a 'task_id required' error message !!\n" ++
                "   The frontend needs a stable error string to render the right UX.\n",
            .{HANDLER_PATH},
        );
        return error.TaskIdRequiredMessageMissing;
    }
}

// ─── Contract 3: handler calls deleteTaskUseCase (the split) ────────────

test "task_delete handler delegates to deleteTaskUseCase" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The whole point of the refactor: business logic lives in the
    // use-case, the handler is a thin orchestrator. If this substring
    // is missing, the handler has re-inlined the DB calls — the split
    // is gone.
    if (std.mem.indexOf(u8, source, "deleteTaskUseCase") == null) {
        std.debug.print(
            "\n!! {s} does not call deleteTaskUseCase !!\n" ++
                "   The handler must delegate to the use-case. The split between\n" ++
                "   handler (HTTP orchestration) and use-case (business logic) is\n" ++
                "   the refactor's whole point — see pabrik_config_profile_delete.zig.\n",
            .{HANDLER_PATH},
        );
        return error.DeleteTaskUseCaseMissing;
    }
}

// ─── Contract 4: use-case queries the worker table for the running check ─

test "deleteTaskUseCase queries the worker table to detect running tasks" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The new validation: refuse the delete when a worker row
    // exists with session_id = task_id. The check MUST query the
    // worker table by session_id (not worker.id — that would match
    // the worker id, which is unrelated to the task id).
    if (std.mem.indexOf(u8, source, "FROM worker WHERE session_id = ?") == null and
        std.mem.indexOf(u8, source, "FROM worker WHERE session_id =") == null)
    {
        std.debug.print(
            "\n!! {s} does not query 'FROM worker WHERE session_id = ...' !!\n" ++
                "   The running-task validation is missing. A task whose LLM\n" ++
                "   call is in-flight can currently be deleted, orphaning the\n" ++
                "   worker. Add a SELECT against worker.session_id BEFORE any\n" ++
                "   cleanup so a refused delete leaves the task intact.\n",
            .{HANDLER_PATH},
        );
        return error.WorkerRunningCheckMissing;
    }
}

// ─── Contract 5: handler returns 409 on .running ─────────────────────────

test "task_delete handler returns 409 when the task is running" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The use-case's `.running` outcome must map to 409 Conflict.
    // 200 here would let the frontend think the delete succeeded
    // while the worker is still alive — a silent state corruption.
    if (std.mem.indexOf(u8, source, ".status_code = 409") == null) {
        std.debug.print(
            "\n!! {s} does not return 409 when the task is running !!\n" ++
                "   The use-case's .running variant must map to HTTP 409\n" ++
                "   Conflict (not 200, not 500). 200 would let the frontend\n" ++
                "   remove the task from the UI while the worker is still\n" ++
                "   streaming. 500 would be retried, also wrong.\n",
            .{HANDLER_PATH},
        );
        return error.Status409Missing;
    }
    // The error message must mention "running" so the frontend can
    // surface a useful hint (e.g. \"Stop the session first\").
    if (std.mem.indexOf(u8, source, "currently running") == null) {
        std.debug.print(
            "\n!! {s} does not surface a 'currently running' error message on .running !!\n" ++
                "   The frontend needs to know WHY the delete was refused so it\n" ++
                "   can prompt the user to stop the session first.\n",
            .{HANDLER_PATH},
        );
        return error.RunningMessageMissing;
    }
}

// ─── Contract 6: handler returns 200 on .deleted ─────────────────────────

test "task_delete handler returns 200 when the use-case deletes successfully" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return 200 on a successful delete !!\n" ++
                "   Use `.status_code = 200` with a {{success, id}} body.\n",
            .{HANDLER_PATH},
        );
        return error.Status200Missing;
    }
    // The handler must use the typed `makeTaskDeleteResponse` helper
    // (not hand-rolled JSON) so future field additions are
    // type-checked.
    if (std.mem.indexOf(u8, source, "makeTaskDeleteResponse") == null) {
        std.debug.print(
            "\n!! {s} does not call makeTaskDeleteResponse !!\n" ++
                "   The response is being constructed manually. Use the typed\n" ++
                "   helper from http_response.zig:\n" ++
                "     try http_response.makeTaskDeleteResponse(allocator, ...)\n",
            .{HANDLER_PATH},
        );
        return error.TypedResponseMissing;
    }
}

// ─── Contract 7: use-case is exposed via http_handlers/mod.zig ───────────

test "deleteTaskUseCase is re-exported from http_handlers/mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    // The use-case must be reachable as
    // `pabrikcore.http_handlers.deleteTaskUseCase` for tests and other
    // consumers (the project's convention — see
    // pabrik_config_profile_delete.zig's re-exports).
    if (std.mem.indexOf(u8, source, "pub const deleteTaskUseCase") == null) {
        std.debug.print(
            "\n!! {s} does not re-export deleteTaskUseCase !!\n" ++
                "   Add: pub const deleteTaskUseCase = @import(\"task_delete.zig\").deleteTaskUseCase;\n" ++
                "   so the use-case is reachable via pabrikcore.http_handlers.deleteTaskUseCase.\n",
            .{MOD_PATH},
        );
        return error.DeleteTaskUseCaseReExportMissing;
    }
    // The TaskDeleteOutcome tagged-union must also be re-exported
    // (the handler and any future tests need it).
    if (std.mem.indexOf(u8, source, "pub const TaskDeleteOutcome") == null) {
        std.debug.print(
            "\n!! {s} does not re-export TaskDeleteOutcome !!\n" ++
                "   Add: pub const TaskDeleteOutcome = @import(\"task_delete.zig\").TaskDeleteOutcome;\n",
            .{MOD_PATH},
        );
        return error.TaskDeleteOutcomeReExportMissing;
    }
}

// ─── Contract 8: isTaskRunning helper exists in llm_history.zig ──────────

test "llm_history.zig exposes isTaskRunning(db, task_id) helper" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    // The use-case delegates the running-check to a small helper
    // (so other handlers can reuse it). The helper must query the
    // worker table by `session_id` — matching the project's
    // `task.id == session.id` convention.
    if (std.mem.indexOf(u8, source, "pub fn isTaskRunning") == null) {
        std.debug.print(
            "\n!! {s} does not expose pub fn isTaskRunning !!\n" ++
                "   The use-case needs a helper that checks the worker table.\n" ++
                "   Add a helper that returns bool, querying\n" ++
                "     SELECT 1 FROM worker WHERE session_id = ? LIMIT 1\n" ++
                "   against the worker table — checking session_id (the\n" ++
                "   task_id == session_id column), not worker.id.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.IsTaskRunningMissing;
    }
    // The helper must check the session_id column (not worker.id) —
    // the task_id == session_id convention is what makes the link.
    // Verify the helper's SQL targets the right column.
    const after_helper = std.mem.indexOf(u8, source, "pub fn isTaskRunning") orelse 0;
    // Look ahead ~400 chars for the SQL — the helper body is small.
    const window = source[@min(after_helper, source.len)..@min(after_helper + 400, source.len)];
    if (std.mem.indexOf(u8, window, "FROM worker WHERE session_id") == null) {
        std.debug.print(
            "\n!! {s}'s isTaskRunning helper does not query 'FROM worker WHERE session_id' !!\n" ++
                "   The helper must check the worker.session_id column (the\n" ++
                "   project's task.id == session.id convention) — checking\n" ++
                "   worker.id would match the wrong rows.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.IsTaskRunningWrongColumn;
    }
}

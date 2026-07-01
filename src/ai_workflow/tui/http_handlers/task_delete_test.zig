//! Static regression checks for the
//! `DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id`
//! handler and its split-out `deleteTaskUseCase`.
//!
//! Why this file exists
//! ────────────────────
//! The delete-task endpoint was refactored to:
//!   1. Split the handler (thin HTTP orchestrator) from the use-case
//!      (`deleteTaskUseCase` — pure-ish over DB + Io).
//!   2. Add a pre-flight validation: refuse the delete (HTTP 409
//!      Conflict) when a worker row exists in the `worker` table with
//!      `session_id = task_id`. Per the project's
//!      `task.id == session.id` convention, that row means the task's
//!      LLM call is currently in-flight — deleting now would orphan
//!      the worker's state.
//!
//! These contracts are enforced by static substring checks (matching
//! the `task_update_test.zig` / `kanban_columns_delete_test.zig`
//! pattern), NOT by spinning up an in-memory DB. Standing up sqlite +
//! migrations + event-bus to behavioural-test the handler would
//! duplicate the migration setup and pull in `nalarcore.getSingleton()`
//! (which depends on a live `ContextIPCTui` with a server, logger,
//! and event bus). The static checks below directly test the bug —
//! they fail if and only if the running-check or the handler/usecase
//! split is removed or routed back to the old path.
//!
//! Plan: docs/superpowers/plans/2026-06-28-task-delete-running-validation.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/task_delete.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/llm_history.zig";

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(256 * 1024),
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
                "   the refactor's whole point — see nalar_config_profile_delete.zig.\n",
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
    // `nalarcore.http_handlers.deleteTaskUseCase` for tests and other
    // consumers (the project's convention — see
    // nalar_config_profile_delete.zig's re-exports).
    if (std.mem.indexOf(u8, source, "pub const deleteTaskUseCase") == null) {
        std.debug.print(
            "\n!! {s} does not re-export deleteTaskUseCase !!\n" ++
                "   Add: pub const deleteTaskUseCase = @import(\"task_delete.zig\").deleteTaskUseCase;\n" ++
                "   so the use-case is reachable via nalarcore.http_handlers.deleteTaskUseCase.\n",
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

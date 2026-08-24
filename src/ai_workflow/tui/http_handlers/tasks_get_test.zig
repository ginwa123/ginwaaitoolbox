//!
//! Static-contract tests for the single-task GET endpoint
//! (`tasks_get.zig`, plan:
//! docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md).
//!
//! Why this file exists
//! ────────────────────
//! Opening the kanban Task details dialog used to refetch the WHOLE
//! task list (`GET .../tasks?limit=100`) and pluck one task — wasteful
//! on a 270+ task board (base64 image_urls, routine JOINs, a git
//! subprocess per row). The fix adds `GET .../tasks/:task_id` backed
//! by `llm_history.getWorkspaceItemTaskById`, and the frontend
//! `refreshTask` switches to it.
//!
//! These contracts are enforced by static substring checks (matching
//! the sibling `tasks_list_test.zig` pattern). The DB-layer behaviour
//! is covered behaviourally by the inline tests in `llm_history.zig`;
//! the wire behaviour is covered by
//! `tests/functional/kanban_task_get_test.py`.

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = @import("helpers").text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/tasks_get.zig";
const LLM_HISTORY_PATH = "src/ai_workflow/tui/agentic_loop/llm_history.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";
const MAIN_PATH = "src/main.zig";
const TEST_RUNNER_PATH = "src/ai_workflow/tui/test_runner.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test` runs).
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

// ─── Contract 1: handler delegates to the single-task DB function ─────────

test "tasks_get handler calls getWorkspaceItemTaskById" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // If the handler was reverted to the list endpoint, the dialog
    // open would refetch the whole board again (the bug this plan
    // fixes).
    if (std.mem.indexOf(u8, source, "getWorkspaceItemTaskById") == null) {
        std.debug.print(
            "\n!! {s} does not call getWorkspaceItemTaskById !!\n" ++
                "   The single-task contract is broken: the handler is\n" ++
                "   falling back to the list path, which refetches every\n" ++
                "   task on the board for one dialog open.\n" ++
                "   Restore the call:\n" ++
                "     ai_mod.llm_history.getWorkspaceItemTaskById(allocator, sqlite_db, item_id, task_id)\n" ++
                "   See docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md.\n",
            .{HANDLER_PATH},
        );
        return error.SingleTaskFunctionNotCalled;
    }
}

// ─── Contract 2: empty task_id is rejected with 400 ───────────────────────

test "tasks_get handler guards empty task_id with 400" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // SqliteBackend binds "" as SQL NULL — an unguarded empty task_id
    // would turn `WHERE t.id = ?` into `WHERE t.id IS NULL` (always
    // false, silently). The handler must 400 before any DB call.
    if (std.mem.indexOf(u8, source, "task_id required") == null) {
        std.debug.print(
            "\n!! {s} does not guard an empty task_id !!\n" ++
                "   The empty-slice-as-NULL binding rule (workspace\n" ++
                "   convention) requires a 400 before the DB call:\n" ++
                "     if (task_id.len == 0) return res.jsonResponse(.{{ .status_code = 400, ... }});\n" ++
                "   See docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md.\n",
            .{HANDLER_PATH},
        );
        return error.TaskIdGuardMissing;
    }
}

// ─── Contract 3: 404 when the task does not exist ─────────────────────────

test "tasks_get handler maps null DB result to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // A missing task (deleted, or wrong item in the path) must be a
    // clean 404 — the frontend's getTask() resolves null on it.
    if (std.mem.indexOf(u8, source, "task not found") == null) {
        std.debug.print(
            "\n!! {s} does not map a missing task to 404 !!\n" ++
                "   Restore the null-result branch:\n" ++
                "     null => res.jsonResponse(.{{ .status_code = 404, .data = makeErrorResponse(... \"task not found\") }})\n" ++
                "   See docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md.\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundBranchMissing;
    }
}

// ─── Contract 4: mod.zig re-exports the handler ───────────────────────────

test "http_handlers mod re-exports tasksGetHandler" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "tasksGetHandler") == null) {
        std.debug.print(
            "\n!! {s} does not re-export tasksGetHandler !!\n" ++
                "   main.zig references ai_mod.http_handlers.tasksGetHandler;\n" ++
                "   without the re-export the route registration fails to compile.\n" ++
                "   Restore:\n" ++
                "     pub const tasksGetHandler = @import(\"tasks_get.zig\").tasksGetHandler;\n",
            .{MOD_PATH},
        );
        return error.HandlerNotReExported;
    }
}

// ─── Contract 5: route registered AFTER the list route (shadowing) ────────

test "main.zig registers GET tasks/:task_id after the list route" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MAIN_PATH);
    defer allocator.free(source);

    // matchRoute walks routes in registration order. The literal
    // single-task route must come after the list route so the list
    // path (`/tasks`) is never shadowed — and vice versa, the longer
    // `:task_id` path must exist at all.
    const list_route = "gs.router.get(\"/api/workspaces/:workspace_id/items/:item_id/tasks\", ai_mod.http_handlers.tasksListHandler)";
    const get_route = "gs.router.get(\"/api/workspaces/:workspace_id/items/:item_id/tasks/:task_id\", ai_mod.http_handlers.tasksGetHandler)";

    const list_idx = std.mem.indexOf(u8, source, list_route) orelse {
        std.debug.print("\n!! list route missing from {s} !!\n", .{MAIN_PATH});
        return error.ListRouteMissing;
    };
    const get_idx = std.mem.indexOf(u8, source, get_route) orelse {
        std.debug.print(
            "\n!! {s} does not register the single-task GET route !!\n" ++
                "   Restore:\n" ++
                "     {s}\n" ++
                "   (immediately after the tasksListHandler registration).\n",
            .{ MAIN_PATH, get_route },
        );
        return error.GetRouteMissing;
    };
    if (get_idx < list_idx) {
        std.debug.print(
            "\n!! single-task GET route registered BEFORE the list route in {s} !!\n" ++
                "   matchRoute walks routes in registration order; keep the\n" ++
                "   list route first (see router.zig route-order rule).\n",
            .{MAIN_PATH},
        );
        return error.RouteOrderShadowing;
    }
}

// ─── Contract 6: DB function exists with the expected signature ───────────

test "llm_history exposes getWorkspaceItemTaskById" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, LLM_HISTORY_PATH);
    defer allocator.free(source);

    const sig = "pub fn getWorkspaceItemTaskById(";
    if (std.mem.indexOf(u8, source, sig) == null) {
        std.debug.print(
            "\n!! {s} does not define `getWorkspaceItemTaskById` !!\n" ++
                "   The single-task DB function is missing, so the handler\n" ++
                "   has no way to fetch one task without the list query.\n" ++
                "   Restore:\n" ++
                "     pub fn getWorkspaceItemTaskById(allocator, db, workspace_item_id, task_id) !?WorkspaceItemTaskInfo\n" ++
                "   See docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md.\n",
            .{LLM_HISTORY_PATH},
        );
        return error.SingleTaskFnMissing;
    }
}

// ─── Contract 7: test runner registers this test file ─────────────────────

test "test_runner registers tasks_get_test" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, TEST_RUNNER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "tasks_get_test.zig") == null) {
        std.debug.print(
            "\n!! {s} does not import tasks_get_test.zig !!\n" ++
                "   Without the import these contracts never run.\n" ++
                "   Restore:\n" ++
                "     _ = @import(\"http_handlers/tasks_get_test.zig\");\n",
            .{TEST_RUNNER_PATH},
        );
        return error.TestNotRegistered;
    }
}

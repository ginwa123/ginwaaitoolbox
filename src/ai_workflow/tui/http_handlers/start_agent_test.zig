//! Static regression checks for the start_agent handler.
//!
//! Why this file exists
//! ────────────────────
//! The 2026-08-18-kanban-task-detail-start-agent plan introduces
//! `POST /api/workspaces/:w/items/:i/tasks/:tid/start_agent` — a
//! trigger-worker-on-existing-session endpoint. The handler is a
//! thin wrapper: it validates the task exists, checks no worker is
//! currently running, reads the session row, and calls
//! `di.emit_run_agent(...)` with `skip_initial_queue_message: true`.
//! All actual LLM work happens in `agentic_loop/workflow.zig` via the
//! `RunParamsNew` event (covered by inline workflow tests).
//!
//! The tests below check the *wrapper* contracts:
//!   1. Calls `nalarcore.getSingleton()` for the Io group (required to
//!      reach `di.emit_run_agent`).
//!   2. Calls `di.emit_run_agent` (NOT a no-op or stub).
//!   3. Sets `skip_initial_queue_message = true` (the whole point of
//!      this endpoint — without the flag, an empty `queue_message`
//!      would still insert an empty row into `session_queue_messages`).
//!   4. Validates task existence (404 path).
//!   5. Validates worker-running state (409 path).
//!   6. Returns 200 with `{success, session_id, status: 'triggered'}`
//!      on success.
//!   7. Empty `queue_message` in the emit_run_agent call (the flag
//!      suppresses the insert; an empty string is still safe).
//!
//! Mirrors the static-check pattern from `routines_run_test.zig` —
//! spinning up a sqlite DB + singleton for behavioural tests would
//! duplicate the migration setup that's covered by the inline
//! `workflow.zig` tests.
//!
//! Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const text_normalize = nalarcore.helpers.text_normalize;

const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/start_agent.zig";

/// Read a source file from disk, relative to the project root
/// (which is the cwd when `zig build test:ai_workflow:tui` runs).
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

// ─── Contract 1: handler gets the singleton for the Io group ──────────────

test "start_agent handler gets the singleton for emit_run_agent" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `nalarcore.getSingleton()` to obtain the
    // initialized `ContextIPCTui` (which carries the Io group via
    // `di.group_emit_session_create`). Without this, the handler has
    // no way to schedule the LLM work on the main process's runtime.
    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print(
            "\n!! {s} does not call getSingleton() !!\n" ++
                "   The Io-group-acquisition contract is broken: the handler\n" ++
                "   cannot reach `di.group_emit_session_create.concurrent` to\n" ++
                "   schedule the LLM trigger on the main process's Io runtime.\n" ++
                "   Add a nalarcore.getSingleton() call and map the error to 500.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "emit_run_agent") == null) {
        std.debug.print(
            "\n!! {s} does not call di.emit_run_agent !!\n" ++
                "   The trigger-pipeline contract is broken: the handler is not\n" ++
                "   a thin wrapper around `di.emit_run_agent`. Restore the call\n" ++
                "   to schedule the worker on the main process's Io group.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.EmitRunAgentCallMissing;
    }
}

// ─── Contract 2: handler sets skip_initial_queue_message = true ────────────

test "start_agent handler sets skip_initial_queue_message = true" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The whole point of this endpoint is to trigger a worker WITHOUT
    // queueing a new user message. Without the flag, the workflow's
    // `runAgenticMultiStepnew` would still call `insertQueueMessage`
    // (with the empty `queue_message`) and insert an empty row into
    // `session_queue_messages`. That's a wire-contract bug: the user
    // expects no new message in the chat history.
    if (std.mem.indexOf(u8, source, "skip_initial_queue_message = true") == null) {
        std.debug.print(
            "\n!! {s} does not set skip_initial_queue_message = true !!\n" ++
                "   The trigger-mode contract is broken: the worker will still\n" ++
                "   call insertQueueMessage on entry, leaving an empty row in\n" ++
                "   session_queue_messages. Set the flag in the emit_run_agent\n" ++
                "   struct literal so runAgenticMultiStepnew skips the insert.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.SkipInitialQueueMessageFlagMissing;
    }
}

// ─── Contract 3: handler emits an empty queue_message ─────────────────────

test "start_agent handler emits an empty queue_message" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // Defence-in-depth: even with the skip flag set, an explicit
    // empty `queue_message = ""` makes the wire semantics visible at
    // the call site. A future refactor that removes the flag (but
    // leaves a populated `queue_message`) would silently insert a new
    // user message on every Start-agent click.
    if (std.mem.indexOf(u8, source, ".queue_message = \"\"") == null) {
        std.debug.print(
            "\n!! {s} does not set queue_message = \"\" !!\n" ++
                "   The no-new-message contract is fragile: pass an explicit\n" ++
                "   empty queue_message so a future refactor that drops the\n" ++
                "   skip_initial_queue_message flag does NOT silently queue\n" ++
                "   a new user message. Set `.queue_message = \"\"` in the\n" ++
                "   emit_run_agent struct literal.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.QueueMessageEmptyMissing;
    }
}

// ─── Contract 4: missing task maps to 404 ────────────────────────────────

test "start_agent handler maps missing task to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "404") == null) {
        std.debug.print(
            "\n!! {s} does not return a 404 status code !!\n" ++
                "   The missing-task branch must produce `status_code = 404`.\n" ++
                "   Without it, a deleted task will return 500, which is\n" ++
                "   semantically wrong and breaks the client contract.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "task not found") == null) {
        std.debug.print(
            "\n!! {s} does not include a 'task not found' error message !!\n" ++
                "   The 404 error body must clearly state the task is missing.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundMessageMissing;
    }
}

// ─── Contract 5: worker-already-running maps to 409 ──────────────────────

test "start_agent handler maps worker-already-running to 409" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "409") == null) {
        std.debug.print(
            "\n!! {s} does not return a 409 status code !!\n" ++
                "   The already-running branch must produce `status_code = 409`.\n" ++
                "   409 = conflict — a worker is currently in flight for this\n" ++
                "   session. Without it, a double-trigger would silently start\n" ++
                "   a second worker (the user's intent is exactly one).\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.AlreadyRunningStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "isTaskRunning") == null) {
        std.debug.print(
            "\n!! {s} does not call isTaskRunning !!\n" ++
                "   The 409-already-running contract is broken: the handler\n" ++
                "   must query the worker table via isTaskRunning to detect\n" ++
                "   an in-flight worker for this session. Add the call before\n" ++
                "   emit_run_agent.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.IsTaskRunningCallMissing;
    }
}

// ─── Contract 6: success returns 200 with session_id JSON ───────────────

test "start_agent handler returns 200 with session_id on success" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // On success the handler returns 200 OK with a JSON body containing
    // `session_id` (which equals the task id per the project's
    // `task.id == session.id` invariant). The `status: "triggered"`
    // discriminator is what the frontend uses to close the dialog
    // (vs. falling into the "failed" branch).
    if (std.mem.indexOf(u8, source, "session_id") == null) {
        std.debug.print(
            "\n!! {s} does not return a `session_id` field !!\n" ++
                "   The success-response contract is broken: the client has\n" ++
                "   no way to confirm which session was triggered. Return\n" ++
                "   `{{\"success\":true,\"session_id\":\"<task_id>\",\"status\":\"triggered\"}}`\n" ++
                "   with status_code = 200.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.SessionIdResponseMissing;
    }
    if (std.mem.indexOf(u8, source, "\"triggered\"") == null) {
        std.debug.print(
            "\n!! {s} does not include status: 'triggered' !!\n" ++
                "   The success response must carry `\"status\":\"triggered\"`\n" ++
                "   so the frontend can branch on it (close the dialog when\n" ++
                "   'triggered', show errorMessage otherwise).\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.TriggeredStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "200") == null) {
        std.debug.print(
            "\n!! {s} does not return a 200 status code !!\n" ++
                "   The success branch must produce `status_code = 200`.\n" ++
                "   See docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md.\n",
            .{HANDLER_PATH},
        );
        return error.SuccessStatusMissing;
    }
}
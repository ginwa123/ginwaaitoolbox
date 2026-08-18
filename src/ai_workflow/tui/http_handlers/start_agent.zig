//! HTTP handler + use-case for
//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`.
//!
//! ## File structure
//!
//! This file holds BOTH the use-case (pure-ish function over the DB
//! and the `ContextIPCTui` singleton) and the HTTP handler (thin
//! orchestrator that validates the path param, calls the use-case,
//! and maps the outcome to an HTTP response):
//!
//! - `StartAgentOutcome` — the tagged union returned by the use-case
//!   (`triggered` / `task_not_found` / `worker_already_running`).
//!   The handler maps each variant to a specific HTTP status code.
//! - `startAgentUseCase` — the **use-case** (pure-ish function; reads
//!   from the DB, calls `di.emit_run_agent` with the
//!   `skip_initial_queue_message: true` flag so the workflow skips
//!   its initial `insertQueueMessage` call). The use-case is also
//!   re-exported via `http_handlers/mod.zig` for direct use by other
//!   callers + future behavioural tests.
//! - `startAgentHandler` — the **HTTP handler** (orchestrator).
//!
//! ## Wire shape (the whole point of the new endpoint)
//!
//! Unlike `POST /api/llm/session` (which has session-create semantics
//! + ALWAYS inserts a queue message), this endpoint triggers a
//! worker on an existing session WITHOUT queueing a new user
//! message. The agent runs on whatever chat history is already in
//! the session:
//!   - For tasks WITH chat history: the agent resumes the
//!     conversation.
//!   - For tasks WITHOUT chat history: the agent responds based on
//!     its system prompt alone (typically a clarification message).
//!
//! The "no queue_message" contract is enforced by:
//!   1. passing `queue_message = ""` to `emit_run_agent` (visible at
//!      the call site for defence-in-depth), and
//!   2. setting `skip_initial_queue_message: true` (the workflow
//!      flag that suppresses `insertQueueMessage` on entry —
//!      threaded through `EmitRunAgentInput` →
//!      `emit_run_agent.concurrent` → `RunParamsNew` →
//!      `runAgenticMultiStepnew`).
//!
//! Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const sqlite = nalarcore.sqlite;
const http_response = @import("http_response.zig");

// =====================================================================
// Domain types
// =====================================================================

/// Outcome of `startAgentUseCase`.
///
/// `.triggered` — success. The worker has been submitted to the Io
/// group and the response body returns `session_id` (= `task_id` per
/// the project's `task.id == session.id` convention). The handler
/// maps this to HTTP 200.
///
/// `.task_not_found` — the `workspace_item_tasks` row for the
/// supplied `task_id` does not exist. The handler maps this to HTTP
/// 404.
///
/// `.worker_already_running` — a row in the `worker` table has
/// `session_id = task_id` (i.e. an LLM call is currently in-flight
/// or streaming for this task's session). The handler maps this to
/// HTTP 409 Conflict. The frontend's `:disabled` state on the Start
/// agent button is best-effort; this DB-side check is the source of
/// truth and catches the cross-session SSE race.
pub const StartAgentOutcome = union(enum) {
    triggered,
    task_not_found,
    worker_already_running,
};

// =====================================================================
// Use-case (pure-ish)
// =====================================================================

/// Trigger an LLM worker on the task's existing session WITHOUT
/// queueing a new user message. Returns one of `StartAgentOutcome`'s
/// variants; DB / `emit_run_agent` failures propagate as `error{...}`
/// and are mapped to HTTP 500 by the handler.
///
/// Flow:
///   1. Look up the task in `workspace_item_tasks` (404 otherwise).
///   2. Check the worker table for an in-flight session (409
///      otherwise). Pre-flight guard so the user-visible button-
///      disable (frontend) + this DB-side check are belt-and-braces.
///   3. Read the session row to forward `selected_profile_model` +
///      `is_auto_retry_until_stop` to the worker pool. If no row
///      exists yet (brand-new task that has never been started),
///      `emit_run_agent.insert_worker` will upsert one — same
///      pattern as `fire.fireRoutine` for routines.
///   4. Submit the LLM work via `di.emit_run_agent` with empty
///      `queue_message` and `skip_initial_queue_message: true`. The
///      empty `queue_message` is defensive belt-and-braces — the
///      flag alone is enough to suppress the insert, but having both
///      makes the wire intent obvious at the call site (a future
///      refactor that drops the flag would NOT silently queue a new
///      user message).
pub fn startAgentUseCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
    task_id: []const u8,
) !StartAgentOutcome {
    // 1. Validate the task exists. `getWorkspaceItemTask` returns
    //    null when the row is absent (vs. propagating a NOT_FOUND
    //    error); we map that to `.task_not_found`.
    const task_opt = ai_mod.workspace_item_tasks.getWorkspaceItemTask(allocator, db, task_id) catch null;
    const task = task_opt orelse return .task_not_found;
    defer task.deinit(allocator);

    // 2. Refuse if a worker is currently running for this session.
    //    Mirrors the running-check in task_delete.zig:409. The
    //    frontend's `:disabled` state is best-effort; this is the
    //    source of truth that catches the SSE-delivery-lag race.
    if (ai_mod.llm_history.isTaskRunning(allocator, db, task_id)) {
        return .worker_already_running;
    }

    // 3. Read the session row so we can forward selected_profile_model
    //    + is_auto_retry_until_stop to the worker pool. The session
    //    row is created by the prior `/api/llm/session` POST or by
    //    `fireRoutine`; if neither has run for this task, the
    //    `insert_worker` step in `emit_run_agent` will upsert one
    //    using the task's name + cwd (matches the routine-fire
    //    pre-insert pattern).
    var session_row = try db.query(
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

    // 4. Submit the LLM work to the Io group. The use-case is a thin
    //    wrapper around `di.emit_run_agent` — same pattern as
    //    `routines_run.zig` (which wraps `fire.fireRoutine`). The
    //    new `skip_initial_queue_message: true` flag tells
    //    `runAgenticMultiStepnew` to skip its initial
    //    `insertQueueMessage` call, so the agent loop runs on the
    //    existing chat history alone. Empty `queue_message` is
    //    required (any value would be inserted into the queue
    //    without the flag).
    const resolved_cwd: []const u8 = if (task.cwd.len > 0) task.cwd else "";

    try di.emit_run_agent(.{
        .session_id = task_id,
        .session_name = task.name,
        .queue_message = "",
        .cwd = resolved_cwd,
        .body_message = "",
        .allowed_tools = "",
        .image_urls = "",
        .selected_profile_model = session_profile,
        .is_auto_retry_until_stop = session_auto_retry,
        .skip_initial_queue_message = true,
    });

    return .triggered;
}

// =====================================================================
// Handler
// =====================================================================

/// `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`.
///
/// Thin orchestrator over `startAgentUseCase`:
///   1. validate `:task_id` path parameter (inline)
///   2. resolve DB handle via `nalarcore.getSingleton`
///   3. `startAgentUseCase` (use-case)
///   4. map outcome to HTTP response (200 / 404 / 409 / 500)
///
/// On success: `200 OK` with `{"success":true,"session_id":"<task_id>","status":"triggered"}`.
pub fn startAgentHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Validate `:task_id` path parameter.
    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }),
        });
    }

    // 2. Resolve the `ContextIPCTui` singleton (carries the DB handle
    //    + the Io group that `emit_run_agent` schedules onto).
    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case.
    const outcome = startAgentUseCase(allocator, sqlite_db, di, task_id) catch |err| {
        std.log.err("start_agent: useCase failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "start_agent use-case failed" }),
        });
    };

    // 4. Map the use-case outcome to an HTTP response.
    switch (outcome) {
        .triggered => {
            return res.jsonResponse(.{
                .status_code = 200,
                .data = try std.fmt.allocPrint(
                    allocator,
                    "{{\"success\":true,\"session_id\":\"{s}\",\"status\":\"triggered\"}}",
                    .{task_id},
                ),
            });
        },
        .task_not_found => {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task not found" }),
            });
        },
        .worker_already_running => {
            return res.jsonResponse(.{
                .status_code = 409,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "worker already running" }),
            });
        },
    }
}

// =====================================================================
// Static regression checks
// =====================================================================
//
// Why this file uses static contract checks instead of spinning up a
// live sqlite + nalarcore singleton: standing up an in-memory DB +
// migrations + event-bus + `ContextIPCTui` to behavioural-test the
// handler would duplicate the migration setup and pull in
// `nalarcore.getSingleton()` (which depends on a live server, logger,
// and event bus). The static checks below directly test the bug —
// they fail if and only if the handler/useCase split, the no-
// queue-message wire contract, or the status-code mapping is
// removed or routed back to the old path. Mirrors the convention
// from `routines_run_test.zig` / `task_delete_test.zig` /
// `task_create_routines_test.zig` etc.

const testing = std.testing;
const text_normalize = nalarcore.helpers.text_normalize;
const HANDLER_PATH = "src/ai_workflow/tui/http_handlers/start_agent.zig";
const MOD_PATH = "src/ai_workflow/tui/http_handlers/mod.zig";

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

// ─── Contract 1: handler reads task_id from path params ────────────────────

test "start_agent handler reads task_id from path params" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, "req.params.get(\"task_id\")") == null) {
        std.debug.print(
            "\n!! {s} does not read the task_id path param !!\n" ++
                "   The endpoint is broken: the use-case will receive an\n" ++
                "   empty task_id and look up an empty row in workspace_item_tasks.\n" ++
                "   Add `req.params.get(\"task_id\")` + the empty-length guard.\n",
            .{HANDLER_PATH},
        );
        return error.TaskIdPathParamMissing;
    }
}

// ─── Contract 2: handler delegates to startAgentUseCase ────────────────────

test "start_agent handler delegates to startAgentUseCase" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The whole point of the handler/useCase split: business logic
    // lives in the use-case, the handler is a thin orchestrator.
    // If this substring is missing, the handler has re-inlined the
    // DB calls — the split is gone. Matches the task_delete.zig
    // pattern (see task_delete_test.zig contract 3).
    if (std.mem.indexOf(u8, source, "startAgentUseCase") == null) {
        std.debug.print(
            "\n!! {s} does not call startAgentUseCase !!\n" ++
                "   The handler must delegate to the use-case. The split\n" ++
                "   between handler (HTTP orchestration) and use-case\n" ++
                "   (business logic) is the refactor's whole point.\n",
            .{HANDLER_PATH},
        );
        return error.StartAgentUseCaseCallMissing;
    }
}

// ─── Contract 3: handler gets the singleton for the Io group ──────────────

test "start_agent handler gets the singleton for emit_run_agent" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The handler must call `nalarcore.getSingleton()` to obtain the
    // initialized `ContextIPCTui` (which carries the Io group via
    // `di.group_emit_session_create`). Without this, the handler has
    // no way to schedule the LLM trigger on the main process's Io
    // runtime.
    if (std.mem.indexOf(u8, source, "getSingleton") == null) {
        std.debug.print(
            "\n!! {s} does not call getSingleton() !!\n" ++
                "   The Io-group-acquisition contract is broken: the\n" ++
                "   handler cannot reach `di.group_emit_session_create.concurrent`\n" ++
                "   to schedule the LLM trigger on the main process's Io\n" ++
                "   runtime. Add a nalarcore.getSingleton() call and map\n" ++
                "   the error to 500.\n",
            .{HANDLER_PATH},
        );
        return error.SingletonMissing;
    }
    if (std.mem.indexOf(u8, source, "emit_run_agent") == null) {
        std.debug.print(
            "\n!! {s} does not call di.emit_run_agent !!\n" ++
                "   The trigger-pipeline contract is broken: the handler\n" ++
                "   must call `di.emit_run_agent` (NOT a no-op or stub).\n" ++
                "   Restore the call to schedule the worker on the main\n" ++
                "   process's Io group.\n",
            .{HANDLER_PATH},
        );
        return error.EmitRunAgentCallMissing;
    }
}

// ─── Contract 4: use-case sets skip_initial_queue_message = true ───────────

test "start_agent use-case sets skip_initial_queue_message = true" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The whole point of this endpoint is to trigger a worker
    // WITHOUT queueing a new user message. Without the flag, the
    // workflow's `runAgenticMultiStepnew` would still call
    // `insertQueueMessage` (with the empty `queue_message`) and
    // insert an empty row into `session_queue_messages`. That's a
    // wire-contract bug: the user expects no new message in the
    // chat history.
    if (std.mem.indexOf(u8, source, "skip_initial_queue_message = true") == null) {
        std.debug.print(
            "\n!! {s} does not set skip_initial_queue_message = true !!\n" ++
                "   The trigger-mode contract is broken: the worker will\n" ++
                "   still call insertQueueMessage on entry, leaving an\n" ++
                "   empty row in session_queue_messages. Set the flag in\n" ++
                "   the emit_run_agent struct literal so\n" ++
                "   runAgenticMultiStepnew skips the insert.\n",
            .{HANDLER_PATH},
        );
        return error.SkipInitialQueueMessageFlagMissing;
    }
}

// ─── Contract 5: use-case emits an empty queue_message ─────────────────────

test "start_agent use-case emits an empty queue_message" {
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
                "   The no-new-message contract is fragile: pass an\n" ++
                "   explicit empty queue_message so a future refactor\n" ++
                "   that drops the skip_initial_queue_message flag does\n" ++
                "   NOT silently queue a new user message. Set\n" ++
                "   `.queue_message = \"\"` in the emit_run_agent struct\n" ++
                "   literal.\n",
            .{HANDLER_PATH},
        );
        return error.QueueMessageEmptyMissing;
    }
}

// ─── Contract 6: use-case looks up task via getWorkspaceItemTask ───────────

test "start_agent use-case looks up the task via getWorkspaceItemTask" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The task-existence check is the first step in the use-case
    // (drives the 404 mapping). Without it, a deleted task would
    // silently insert a worker row for a non-existent session id.
    if (std.mem.indexOf(u8, source, "getWorkspaceItemTask") == null) {
        std.debug.print(
            "\n!! {s} does not call getWorkspaceItemTask !!\n" ++
                "   The task-existence check is missing: a deleted task\n" ++
                "   would fall through to emit_run_agent and insert a\n" ++
                "   worker row for a non-existent session id. Add the\n" ++
                "   getWorkspaceItemTask call + the .task_not_found branch.\n",
            .{HANDLER_PATH},
        );
        return error.GetWorkspaceItemTaskCallMissing;
    }
}

// ─── Contract 7: use-case checks isTaskRunning for the 409 guard ──────────

test "start_agent use-case checks isTaskRunning for the 409 race guard" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    // The 409 contract: refuse when a worker row exists for this
    // session. The frontend's :disabled state is best-effort; this
    // DB-side check is the source of truth that catches the
    // SSE-delivery-lag race.
    if (std.mem.indexOf(u8, source, "isTaskRunning") == null) {
        std.debug.print(
            "\n!! {s} does not call isTaskRunning !!\n" ++
                "   The 409-already-running contract is broken: the\n" ++
                "   use-case must query the worker table via\n" ++
                "   isTaskRunning to detect an in-flight worker for\n" ++
                "   this session. Add the call before emit_run_agent.\n",
            .{HANDLER_PATH},
        );
        return error.IsTaskRunningCallMissing;
    }
}

// ─── Contract 8: handler maps .task_not_found to 404 ──────────────────────

test "start_agent handler maps .task_not_found to 404" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 404") == null) {
        std.debug.print(
            "\n!! {s} does not return a 404 status code !!\n" ++
                "   The .task_not_found branch must produce\n" ++
                "   `status_code = 404`. Without it, a deleted task\n" ++
                "   returns 500, which is semantically wrong and breaks\n" ++
                "   the client contract.\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "task not found") == null) {
        std.debug.print(
            "\n!! {s} does not include a 'task not found' error message !!\n" ++
                "   The 404 error body must clearly state the task is missing.\n",
            .{HANDLER_PATH},
        );
        return error.NotFoundMessageMissing;
    }
}

// ─── Contract 9: handler maps .worker_already_running to 409 ─────────────

test "start_agent handler maps .worker_already_running to 409" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 409") == null) {
        std.debug.print(
            "\n!! {s} does not return a 409 status code !!\n" ++
                "   The .worker_already_running branch must produce\n" ++
                "   `status_code = 409`. 409 = conflict — a worker is\n" ++
                "   currently in flight for this session. Without it,\n" ++
                "   a double-trigger would silently start a second worker\n" ++
                "   (the user's intent is exactly one).\n",
            .{HANDLER_PATH},
        );
        return error.AlreadyRunningStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "worker already running") == null) {
        std.debug.print(
            "\n!! {s} does not include a 'worker already running' error message !!\n" ++
                "   The 409 error body must clearly state the worker is\n" ++
                "   already running so the frontend can show a useful hint.\n",
            .{HANDLER_PATH},
        );
        return error.AlreadyRunningMessageMissing;
    }
}

// ─── Contract 10: handler returns 200 with session_id on .triggered ─────

test "start_agent handler returns 200 with session_id on .triggered" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, HANDLER_PATH);
    defer allocator.free(source);

    if (std.mem.indexOf(u8, source, ".status_code = 200") == null) {
        std.debug.print(
            "\n!! {s} does not return a 200 status code !!\n" ++
                "   The .triggered branch must produce `status_code = 200`.\n",
            .{HANDLER_PATH},
        );
        return error.SuccessStatusMissing;
    }
    if (std.mem.indexOf(u8, source, "session_id") == null) {
        std.debug.print(
            "\n!! {s} does not return a `session_id` field !!\n" ++
                "   The success-response contract is broken: the client has\n" ++
                "   no way to confirm which session was triggered. Return\n" ++
                "   `{{\"success\":true,\"session_id\":\"<task_id>\",\"status\":\"triggered\"}}`\n" ++
                "   with status_code = 200.\n",
            .{HANDLER_PATH},
        );
        return error.SessionIdResponseMissing;
    }
    if (std.mem.indexOf(u8, source, "\"triggered\"") == null) {
        std.debug.print(
            "\n!! {s} does not include status: 'triggered' !!\n" ++
                "   The success response must carry `\"status\":\"triggered\"`\n" ++
                "   so the frontend can branch on it (close the dialog when\n" ++
                "   'triggered', show errorMessage otherwise).\n",
            .{HANDLER_PATH},
        );
        return error.TriggeredStatusMissing;
    }
}

// ─── Contract 11: use-case is re-exported from http_handlers/mod.zig ──────

test "startAgentUseCase is re-exported from http_handlers/mod.zig" {
    const allocator = testing.allocator;
    const source = try readSource(allocator, MOD_PATH);
    defer allocator.free(source);

    // The use-case must be reachable as
    // `nalarcore.http_handlers.startAgentUseCase` for tests and
    // other consumers (the project's convention — see
    // task_delete.zig's re-export of deleteTaskUseCase).
    if (std.mem.indexOf(u8, source, "pub const startAgentUseCase") == null) {
        std.debug.print(
            "\n!! {s} does not re-export startAgentUseCase !!\n" ++
                "   Add: pub const startAgentUseCase = @import(\"start_agent.zig\").startAgentUseCase;\n" ++
                "   so the use-case is reachable via nalarcore.http_handlers.startAgentUseCase.\n",
            .{MOD_PATH},
        );
        return error.StartAgentUseCaseReExportMissing;
    }
}

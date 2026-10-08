//! HTTP handler + use-case for
//! `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`.
//!
//! ## File structure
//!
//! This file holds BOTH the use-case (pure-ish function over the DB
//! and the `App` singleton) and the HTTP handler (thin
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
const pabrikcore = @import("pabrikcore");
const auth_common = @import("auth_common.zig");
const gserverz = pabrikcore.gserverz;
const ai_mod = pabrikcore.ai_mod;
const sqlite = pabrikcore.sqlite;
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
///      pattern as `fire.fireWorkspaceRoutine` for workspace routines.
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
    di: *pabrikcore.App,
    task_id: []const u8,
    owner: []const u8,
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
    //    `fireWorkspaceRoutine`; if neither has run for this task, the
    //    `insert_worker` step in `emit_run_agent` will upsert one
    //    using the task's name + cwd (matches the routine-fire
    //    pre-insert pattern).
    var session_profile: []const u8 = "";
    var session_auto_retry: []const u8 = "0";
    // Owned dupes live at function scope so they outlive `emit_run_agent`
    // below (which dupes them synchronously into the long-lived allocator).
    // The `Rows` query itself stays in a tight block scope so its open
    // read statement does not pin the WAL across the emit write.
    var session_profile_owned: ?[]u8 = null;
    var session_auto_retry_owned: ?[]u8 = null;
    defer {
        if (session_profile_owned) |b| allocator.free(b);
        if (session_auto_retry_owned) |b| allocator.free(b);
    }
    {
        // Block scope, NOT function scope: `db.query` hands back a `Rows`
        // holding an UNFINALIZED `sqlite3_stmt`, which is an open read
        // transaction on the shared connection. At function scope the
        // statement stayed open across `di.emit_run_agent` below, which
        // itself writes to the DB (`updateSessionLastHumanTouchedAt`) and
        // then spawns the agentic loop onto another thread. An open read
        // statement pins the WAL's read mark, which is what keeps the
        // `-wal` file growing instead of being checkpointed back.
        var session_row = try db.query(
            allocator,
            "SELECT COALESCE(selected_profile_model, ''), COALESCE(is_auto_retry_until_stop, '0') FROM sessions WHERE id = ?",
            &.{task_id},
        );
        defer session_row.deinit();

        // `row.deinit` frees every `row.values[i]` at the end of the row
        // scope below, but `emit_run_agent` reads these slices afterwards —
        // borrow-then-free copies freed memory into the worker params, and
        // `workflow.zig`'s non-empty write-back then persists the garbage
        // as the session's profile (observed on the wire as
        // `selected_profile_model: [170, 170, ...]` — Zig's 0xAA freed/
        // byte pattern, serialized as a JSON array because it is not valid
        // UTF-8). Dupe first, mirroring `wakeSessionForCompletion` in
        // cleanup_stale_background_process.zig; the function-scope frees
        // above are paired with the dupes (harmless on the request arena,
        // required if the handler ever runs on a non-arena allocator).
        if (try session_row.next()) |row| {
            defer row.deinit(allocator);
            if (row.values.len >= 2) {
                // Already-corrupted rows (0xAA poison from before the fix)
                // are invalid UTF-8 — fall back to empty so we never
                // forward garbage to the worker (which would re-persist it).
                const raw_profile = row.values[0];
                const raw_retry = row.values[1];
                if (std.unicode.utf8ValidateSlice(raw_profile)) {
                    session_profile_owned = try allocator.dupe(u8, raw_profile);
                    session_profile = session_profile_owned.?;
                }
                // is_auto_retry_until_stop is "0"/"1" — same guard for symmetry.
                if (std.unicode.utf8ValidateSlice(raw_retry) and raw_retry.len > 0) {
                    session_auto_retry_owned = try allocator.dupe(u8, raw_retry);
                    session_auto_retry = session_auto_retry_owned.?;
                }
            }
        }
    }

    // 4. Submit the LLM work to the Io group. The use-case is a thin
    //    wrapper around `di.emit_run_agent` — same pattern as
    //    `workspace_routines_run.zig` (which wraps
    //    `fire.fireWorkspaceRoutine`). The
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
        // Owner rides along so the concurrent insert_worker task stamps
        // the session row at INSERT time when it has to upsert one
        // (brand-new task, no session row yet). Otherwise the workflow
        // resolves the process-global config.json instead of the user's
        // users.config_json (plan 2026-09-25).
        .user_id = owner,
    });

    // Claim an ownerless session row the upsert above may have left behind
    // (INSERT OR IGNORE no-ops on an existing ownerless row). Only claims
    // ownerless rows, so a real owner is never overwritten.
    if (di.auth_enabled and owner.len > 0) {
        db.exec(
            allocator,
            "UPDATE sessions SET user_id = ? WHERE id = ? AND (user_id IS NULL OR user_id = '' OR user_id = 'user_system')",
            &[_][]const u8{ owner, task_id },
        ) catch {};
    }

    return .triggered;
}

// =====================================================================
// Handler
// =====================================================================

/// `POST /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id/start_agent`.
///
/// Thin orchestrator over `startAgentUseCase`:
///   1. validate `:task_id` path parameter (inline)
///   2. resolve DB handle via `pabrikcore.getSingleton`
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

    // 2. Resolve the `App` singleton (carries the DB handle
    //    + the Io group that `emit_run_agent` schedules onto).
    const di = pabrikcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case. Owner rides along so the worker's session
    // upsert keeps the row owned under `--auth` (plan 2026-09-25).
    var owner_buf: [128]u8 = undefined;
    const owner: []const u8 = auth_common.resolveOwnerInto(&owner_buf, req.headers) orelse "";
    const outcome = startAgentUseCase(allocator, sqlite_db, di, task_id, owner) catch |err| {
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

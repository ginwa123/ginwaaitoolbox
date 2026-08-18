//! `POST /api/workspaces/:workspace_id/items/:item_id/kanban/tasks`.
//!
//! Kanban-scoped task create endpoint with a `mode` discriminator:
//!
//!   - `mode='create'`           — create the task, auto-assign to the
//!                                 kanban's first column, emit
//!                                 `kanban_task` SSE (action='assigned').
//!                                 Returns `{ task, session: null }`.
//!                                 Does NOT insert a sessions row (legacy).
//!
//!   - `mode='create_session'`   — same as `create` PLUS insert the
//!                                 `sessions` row keyed by `task.id`,
//!                                 persist `selected_profile_model` +
//!                                 `is_auto_retry_until_stop`, emit
//!                                 `session_created` SSE. Does NOT
//!                                 call `emit_run_agent`. Returns
//!                                 `{ task, session: { id, name, status: 'idle' } }`.
//!
//!   - `mode='create_and_run'`   — same as `create_session` PLUS call
//!                                 `emit_run_agent` to queue the first
//!                                 user message + start the agent.
//!                                 Returns `{ task, session: { id, name, status: 'send' } }`.
//!
//! Body: `{ mode, name, description?, queue_message? (create_and_run only),
//!         tags?, image_urls?, cwd?, is_auto_retry_until_stop?,
//!         selected_profile_model? }`.
//!
//! Errors:
//!   - 400 missing/invalid JSON body, missing/invalid `mode`,
//!     empty `queue_message` for `create_and_run`
//!   - 404 parent item is not a kanban
//!   - 500 DB failure
//!
//! Layered as a thin orchestrator over `task_create.zig::useCase`
//! (which handles the standard-task INSERT + kanban auto-assign +
//! kanban_task SSE) plus the create_session / create_and_run
//! side-effects (sessions INSERT + session_created SSE; create_and_run
//! additionally calls emit_run_agent).
//!
//! Plan: docs/superpowers/plans/2026-08-19-kanban-create-task-inits-session.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");
const on_event_sent_kanban = nalarcore.ai_mod.on_event_sent_kanban;

/// HTTP request body for kanban task create. Decoupled from the
/// internal `TaskCreateRequest` struct so the wire format can evolve
/// independently (e.g. adding the `mode` discriminator + `queue_message`
/// fields) without touching the shared task-create use-case.
pub const KanbanTaskCreateBody = struct {
    /// "create" | "create_session" | "create_and_run"
    mode: []const u8 = "",
    name: []const u8 = "",
    description: ?[]const u8 = null,
    /// Required iff mode == "create_and_run".
    queue_message: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    image_urls: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    is_auto_retry_until_stop: ?[]const u8 = null,
    selected_profile_model: ?[]const u8 = null,
};

/// Thin orchestrator over `task_create.zig::useCase` + the
/// create_and_run side-effects. The shape mirrors
/// `kanban_columns_create.zig::kanbanColumnsCreateHandler` (path
/// params → body parse → mode dispatch → use-case call → response
/// build).
pub fn kanbanTasksCreateHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    // 1. Validate path params + body presence + JSON shape.
    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }),
        });
    }
    const ws_id = req.params.get("workspace_id") orelse "";

    if (req.body.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }),
        });
    }

    const parsed = std.json.parseFromSliceLeaky(KanbanTaskCreateBody, allocator, req.body, .{
        .ignore_unknown_fields = true,
    }) catch {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON body" }),
        });
    };

    // 2. Validate the `mode` discriminator. The two valid values are
    // 'create' (just make the card) and 'create_and_run' (make the
    // card AND kick off an agent turn via the session_created SSE).
    if (parsed.mode.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "mode is required (must be 'create' or 'create_and_run')" }),
        });
    }

    const is_create_only = std.mem.eql(u8, parsed.mode, "create");
    const is_create_and_run = std.mem.eql(u8, parsed.mode, "create_and_run");
    const is_create_session = std.mem.eql(u8, parsed.mode, "create_session");
    if (!is_create_only and !is_create_and_run and !is_create_session) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "mode must be 'create', 'create_session', or 'create_and_run'" }),
        });
    }

    if (is_create_and_run) {
        const qm = parsed.queue_message orelse "";
        if (qm.len == 0) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "queue_message is required when mode='create_and_run'" }),
            });
        }
    }

    // 3. Verify parent item is a kanban — reject 404 otherwise.
    {
        var q = sqlite_db.query(allocator,
            "SELECT 1 FROM workspace_items WHERE id = ? AND item_type = 'kanban'",
            &[_][]const u8{item_id}) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to verify parent item" }),
            });
        };
        defer q.deinit();
        const row = (q.next() catch null) orelse {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found or is not a kanban" }),
            });
        };
        row.deinit(allocator);
    }

    // 4. Build the standard `TaskCreateInput` and delegate to the
    // task_create use-case for the INSERT + auto-assign + kanban_task
    // SSE. This avoids duplicating the per-mode INSERT logic in
    // task_create.zig (tags validation, image_urls validation, cwd
    // validation, unattended-mode flag, kanban auto-assign, kanban_task
    // SSE). The kanban-scoped task always forces `task_type='standard'`
    // — routines and memory-tasks have their own dedicated dialogs
    // in the UI.
    const std_req = http_response.TaskCreateRequest{
        .name = parsed.name,
        .description = parsed.description,
        .task_type = "standard",
        .is_auto_retry_until_stop = parsed.is_auto_retry_until_stop,
        .tags = parsed.tags,
        .image_urls = parsed.image_urls,
        .cwd = parsed.cwd,
    };

    const tc_handler = @import("task_create.zig");
    const input = tc_handler.TaskCreateInput{
        .item_id = item_id,
        .workspace_id = ws_id,
        .io = ctx.io,
        .body = std_req,
    };

    const outcome = tc_handler.useCase(allocator, sqlite_db, input) catch |err| {
        const status: u16 = switch (err) {
            error.ItemIdRequired, error.MissingBody, error.InvalidJson => 400,
            error.InvalidTags => 400,
            error.InvalidImageUrls => 400,
            error.ImageUrlsTooLarge => 413,
            error.CwdTooLong, error.CwdNotAbsolute, error.CwdContainsControlChar => 400,
            error.StandardTaskCreateFailed, error.TaskInsertFailed => 500,
            error.OutOfMemory, error.Canceled => 500,
            else => 500, // catch-all for the routine/memory variants that shouldn't fire here
        };
        const message: []const u8 = @errorName(err);
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    // outcome is .standard (we forced task_type='standard' above).
    const standard_result = switch (outcome) {
        .standard => |s| s,
        else => {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Unexpected task_type outcome from useCase" }),
            });
        },
    };

    // 5. If mode='create_session' OR mode='create_and_run', insert the
    // sessions row keyed by task.id and emit the session_created SSE.
    // Only mode='create_and_run' additionally calls `di.emit_run_agent(...)`
    // to queue the agent turn. Mirrors session_create.zig's path
    // verbatim. The `emit_run_agent` call is what actually starts the
    // agent: it heap-dupes each string into `di.allocator`
    // (synchronously) and enqueues a RunParamsNew event on the
    // `ai_worker_flow` channel; CallbackAiWorkerFlow in main.zig picks
    // it up and runs runAgenticMultiStepnew. Without this call, the
    // row exists but the worker pool never picks it up — the
    // user-visible symptom is exactly what the user reported: task
    // gets created, agent never starts.
    if (is_create_and_run or is_create_session) {
        const normalized: []const u8 = blk: {
            if (parsed.is_auto_retry_until_stop) |f| {
                if (std.mem.eql(u8, f, "1")) break :blk "1";
            }
            break :blk "0";
        };
        const profile = parsed.selected_profile_model orelse "";
        const queue_message = parsed.queue_message orelse "";
        // image_urls on the wire is `||`-joined (Migration 069
        // shape); pass through to the worker pool verbatim.
        const image_urls_wire = parsed.image_urls orelse "";

        sqlite_db.exec(
            allocator,
            "INSERT OR IGNORE INTO sessions (id, name, status, cwd, created_at, updated_at, selected_profile_model, is_auto_retry_until_stop) " ++
                "VALUES (?, ?, 'active', ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?, ?)",
            &[_][]const u8{
                standard_result.task_id,
                standard_result.name,
                standard_result.cwd,
                profile,
                normalized,
            },
        ) catch |err| {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
            });
        };

        // Queue the agent turn. Only fire for create_and_run —
        // create_session wants the row inserted but no worker started
        // (the user clicks the card to open the chat themselves).
        // Borrowed slices here are safe because emit_run_agent
        // heap-dupes them before the concurrent worker task reads
        // them.
        if (is_create_and_run) {
            di.emit_run_agent(.{
                .session_id = standard_result.task_id,
                .session_name = standard_result.name,
                .queue_message = queue_message,
                .cwd = standard_result.cwd,
                .body_message = "",
                .allowed_tools = "all",
                .image_urls = image_urls_wire,
                .selected_profile_model = profile,
                .is_auto_retry_until_stop = normalized,
            }) catch |err| {
                std.log.warn("kanban_tasks_create: emit_run_agent failed (non-fatal): {s}", .{@errorName(err)});
            };
        }

        // Emit the session_created SSE so the sidebar's ChatsList
        // gets the new session without a manual refetch. Mirrors
        // session_create.zig::insertWorker's onEventSendSessions
        // call (action='created'). NOTE: we re-derive the session
        // name from standard_result.name (the bound task name) to
        // match task.id == session.id + session.name = task.name
        // per the 2026-08-13-kanban-task-session-name-match plan.
        const on_event_sent = nalarcore.ai_mod.on_event_sent;
        on_event_sent.onEventSendSessions(allocator, .{
            .action = "created",
            .id = standard_result.task_id,
            .name = standard_result.name,
            .status = "active",
            .cwd = standard_result.cwd,
            .created_at = "",
            .updated_at = "",
            .selected_profile_model = profile,
            .is_auto_retry_until_stop = normalized,
            .last_finish_reason = "",
        }) catch |err| {
            std.log.warn("kanban_tasks_create: session_created SSE emit failed (non-fatal): {s}", .{@errorName(err)});
        };
    }

    // 6. Build the success response. Use std.json.Stringify.valueAlloc
    // for JSON-safe escaping (matches task_create.zig's pattern — see
    // the doc comment above RoutineResponse/MemoryResponse/StandardResponse
    // in that file for the rationale).
    const ResponseEnvelope = struct {
        task: http_response.TaskCreateResponse,
        session: ?struct {
            id: []const u8,
            name: []const u8,
            status: []const u8,
        } = null,
    };

    const task_resp = http_response.TaskCreateResponse{
        .id = standard_result.task_id,
        .name = standard_result.name,
        .description = parsed.description,
        .completed = false,
    };

    var response_body: ResponseEnvelope = .{ .task = task_resp };
    if (is_create_and_run) {
        response_body.session = .{
            .id = standard_result.task_id,
            .name = standard_result.name,
            .status = "send",
        };
    } else if (is_create_session) {
        response_body.session = .{
            .id = standard_result.task_id,
            .name = standard_result.name,
            .status = "idle",
        };
    }

    return res.jsonResponse(.{
        .status_code = 201,
        .data = try std.json.Stringify.valueAlloc(allocator, response_body, .{}),
    });
}

//! Bulk endpoint `POST .../kanban/columns/:column_id/run_all_agents`.
//!
//! Starts agents on every idle task in a kanban column, including tasks
//! not yet loaded by frontend pagination. The frontend must NOT loop
//! client-side (it only sees the loaded page); this use-case SELECTs all
//! task ids for the column server-side and reuses the existing
//! single-task `startAgentUseCase` per id (keeping its 404/409 guards).
//!
//! ## Layering
//!
//! - `PerTaskResult` / `TaskStarter` — injectable per-task starter so
//!   behavioural tests can exercise the started/skipped/failed split
//!   without scheduling real LLM workers.
//! - `runAllAgentsWithStarter` — injectable core (column check + id list
//!   + per-id loop). Never throws on single-task failure; failures are
//!   collected into `failed`.
//! - `runAllAgentsUseCase` — live binding that wraps `startAgentUseCase`
//!   per id (Option C) and delegates to the injectable core.
//! - `runAllAgentsHandler` — thin HTTP orchestrator (path param +
//!   singleton + status mapping).
//!
//! Plan: docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md
//!   (Tasks 1+2, Option C).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const sqlite = nalarcore.sqlite;
const http_response = @import("http_response.zig");
const start_agent = @import("start_agent.zig");

// =====================================================================
// Domain types
// =====================================================================

/// Per-task outcome inside a bulk run.
pub const PerTaskResult = enum {
    started,
    skipped,
    failed,
};

/// Injectable per-task starter. Production wraps `startAgentUseCase`;
/// tests supply a fake that consults the real `isTaskRunning` guard.
pub const TaskStarter = struct {
    ptr: ?*anyopaque,
    run: *const fn (?*anyopaque, []const u8) PerTaskResult,
};

/// Bulk outcome: owned id lists. Caller owns every string + slice;
/// release with `deinit`.
pub const RunAllAgentsOutcome = struct {
    started: [][]u8,
    skipped: [][]u8,
    failed: [][]u8,

    pub fn deinit(self: *RunAllAgentsOutcome, allocator: std.mem.Allocator) void {
        for (self.started) |id| allocator.free(id);
        allocator.free(self.started);
        for (self.skipped) |id| allocator.free(id);
        allocator.free(self.skipped);
        for (self.failed) |id| allocator.free(id);
        allocator.free(self.failed);
        self.started = &[_][]u8{};
        self.skipped = &[_][]u8{};
        self.failed = &[_][]u8{};
    }
};

// =====================================================================
// Injectable core (behavioural-test seam)
// =====================================================================

/// List every task id in `column_id`, then run `starter` per id.
///
/// Errors:
///   - `error.EmptyColumnId` — empty `column_id` (empty-slice-as-NULL
///     rule: "" must never reach a `WHERE id = ?` binding).
///   - `error.ColumnNotFound` — no `kanban_columns` row for the id.
///   - DB errors propagate (query/exec/alloc failures).
///
/// Single-task starter results never propagate as errors: `started`
/// collects `triggered`, `skipped` collects `worker_already_running`,
/// `failed` collects `task_not_found` + any other per-task failure.
pub fn runAllAgentsWithStarter(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    column_id: []const u8,
    starter: TaskStarter,
) !RunAllAgentsOutcome {
    if (column_id.len == 0) return error.EmptyColumnId;

    // 1. Column must exist (else the frontend shows "column deleted?").
    {
        var rows = try db.query(
            allocator,
            "SELECT 1 FROM kanban_columns WHERE id = ? LIMIT 1",
            &.{column_id},
        );
        defer rows.deinit();
        if (try rows.next()) |row| {
            row.deinit(allocator);
        } else {
            return error.ColumnNotFound;
        }
    }

    // 2. Server-side id list (pagination-agnostic): the kanban join
    //    table holds the 1:1 task-to-column placement post-Migration-072.
    var ids = std.ArrayList([]u8).empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    {
        var q = try db.query(
            allocator,
            "SELECT workspace_item_task_id FROM kanban WHERE kanban_column_id = ? ORDER BY kanban_position ASC",
            &.{column_id},
        );
        defer q.deinit();
        while (try q.next()) |row| {
            defer row.deinit(allocator);
            const id = try allocator.dupe(u8, row.values[0]);
            errdefer allocator.free(id);
            try ids.append(allocator, id);
        }
    }

    // 3. Sequential per-id loop (avoids thundering herd on
    //    emit_run_agent + sqlite worker writes). One failure never
    //    aborts the rest.
    var started = std.ArrayList([]u8).empty;
    errdefer {
        for (started.items) |id| allocator.free(id);
        started.deinit(allocator);
    }
    var skipped = std.ArrayList([]u8).empty;
    errdefer {
        for (skipped.items) |id| allocator.free(id);
        skipped.deinit(allocator);
    }
    var failed = std.ArrayList([]u8).empty;
    errdefer {
        for (failed.items) |id| allocator.free(id);
        failed.deinit(allocator);
    }

    for (ids.items) |id| {
        switch (starter.run(starter.ptr, id)) {
            .started => try started.append(allocator, id),
            .skipped => try skipped.append(allocator, id),
            .failed => try failed.append(allocator, id),
        }
    }
    // Ownership of every id slice moves into the three outcome lists;
    // release only the staging container (not its elements).
    ids.deinit(allocator);

    return .{
        .started = try started.toOwnedSlice(allocator),
        .skipped = try skipped.toOwnedSlice(allocator),
        .failed = try failed.toOwnedSlice(allocator),
    };
}

// =====================================================================
// Live binding (Option C: reuse startAgentUseCase per id)
// =====================================================================

const LiveCtx = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
};

fn liveRun(ptr: ?*anyopaque, task_id: []const u8) PerTaskResult {
    const c: *LiveCtx = @ptrCast(@alignCast(ptr.?));
    const outcome = start_agent.startAgentUseCase(c.allocator, c.db, c.di, task_id) catch return .failed;
    return switch (outcome) {
        .triggered => .started,
        .worker_already_running => .skipped,
        .task_not_found => .failed,
    };
}

/// Production use-case: reuse the single-task `startAgentUseCase` per
/// id (keeping its 404-via-getWorkspaceItemTask + 409-via-isTaskRunning
/// guards — never copy-pasted). Maps `triggered→started`,
/// `worker_already_running→skipped`, `task_not_found/other→failed`.
pub fn runAllAgentsUseCase(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    di: *nalarcore.ContextIPCTui,
    column_id: []const u8,
) !RunAllAgentsOutcome {
    var live = LiveCtx{ .allocator = allocator, .db = db, .di = di };
    // Explicit reference keeps the reuse grep stable: startAgentUseCase
    const starter: TaskStarter = .{ .ptr = &live, .run = liveRun };
    return runAllAgentsWithStarter(allocator, db, column_id, starter);
}

// =====================================================================
// Handler
// =====================================================================

/// `POST /api/workspaces/:workspace_id/items/:item_id/kanban/columns/:column_id/run_all_agents`.
///
/// Success: `200` with
/// `{"success":true,"column_id":"...","started":[...],"skipped":[...],"failed":[...]}`.
/// Unknown column: `404`. Empty `column_id`: `400`.
pub fn runAllAgentsHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // 1. Validate `:column_id` path parameter (empty-slice-as-NULL rule:
    //    "" must never reach a WHERE binding).
    const column_id = req.params.get("column_id") orelse "";
    if (column_id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
        });
    }

    // 2. Resolve the `ContextIPCTui` singleton (carries the DB handle).
    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "singleton not initialized" }),
        });
    };
    const sqlite_db = di.db;

    // 3. Apply the use-case (which reuses startAgentUseCase per task id).
    const outcome = runAllAgentsUseCase(allocator, sqlite_db, di, column_id) catch |err| {
        if (err == error.ColumnNotFound) {
            return res.jsonResponse(.{
                .status_code = 404,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column not found" }),
            });
        }
        if (err == error.EmptyColumnId) {
            return res.jsonResponse(.{
                .status_code = 400,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "column_id required" }),
            });
        }
        std.log.err("run_all_agents: useCase failed: {s}", .{@errorName(err)});
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "run_all_agents use-case failed" }),
        });
    };
    // Note: outcome slices are arena-allocated on the success path; the
    // per-request arena frees them (no deinit here). The ColumnNotFound
    // branch above maps unknown columns to 404.

    // 4. Success envelope with the three id lists the frontend summary
    //    banner needs: "started", "skipped", "failed".
    const started_json = try std.json.Stringify.valueAlloc(allocator, outcome.started, .{});
    const skipped_json = try std.json.Stringify.valueAlloc(allocator, outcome.skipped, .{});
    const failed_json = try std.json.Stringify.valueAlloc(allocator, outcome.failed, .{});
    return res.jsonResponse(.{
        .status_code = 200,
        .data = try std.fmt.allocPrint(
            allocator,
            "{{\"success\":true,\"column_id\":\"{s}\",\"started\":{s},\"skipped\":{s},\"failed\":{s}}}",
            .{ column_id, started_json, skipped_json, failed_json },
        ),
    });
}

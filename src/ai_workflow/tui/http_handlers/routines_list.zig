//! `GET /api/routines` — list every routine across all workspaces,
//! sorted by `next_run_at ASC NULLS LAST` (the next-to-fire routines
//! are first; never-fired routines float to the bottom).
//!
//! The existing `GET /api/workspaces/.../items/.../tasks` endpoint
//! returns the same `next_run_at` per task, but filtered to one
//! workspace item at a time. This endpoint is the global "what's
//! about to fire?" view — used by the user to see, at a glance, all
//! of their routines and when each will next run.
//!
//! JOIN chain: `routines → workspace_item_tasks → workspace_items`
//! surfaces `workspace_id` (so the caller can navigate from the
//! listing to the source) and `task.name` (so the listing is
//! human-readable).
//!
//! No pagination (routine count is small — dozens to low hundreds).
//! No filters (v1). Returns enabled AND disabled routines; the
//! `enabled: false` flag tells the UI to render them greyed out.
//!
//! Plan: docs/plans/2026-06-15-routines-list-endpoint.md

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = @import("http_response.zig");

/// `GET /api/routines`
///
/// Response: `{ "routines": [...], "count": N }` where each entry
/// carries `workspace_id` + `workspace_item_id` + `task_name` so the
/// caller can navigate.
///
/// Error mapping:
///   - `error.GlobalContextNotInitialized` → 500 (singleton not yet set)
///   - any DB error                          → 500
pub fn routinesListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req; // GET, no body / query params
    const allocator = ctx.allocator;

    const di = nalarcore.getSingleton() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Global context not initialized" }) });
    };
    const sqlite_db = di.db;

    // JOIN chain: routines → workspace_item_tasks (for task_name) →
    // workspace_items (for workspace_id). Every routine has a task
    // (FOREIGN KEY), and every task has a workspace_item (NOT NULL),
    // so the INNER JOINs are total — a routine without a task would
    // be a referential-integrity bug, not a normal case.
    //
    // The `CASE WHEN r.next_run_at IS NULL THEN 1 ELSE 0 END` puts
    // never-fired routines (NULL next_run_at) at the bottom of the
    // listing. SQLite's NULLS LAST syntax isn't supported on the
    // project's SQLite version; the CASE expression is the portable
    // workaround.
    const sql =
        \\SELECT
        \\  r.id, r.task_id, i.workspace_id, t.workspace_item_id, t.name,
        \\  r.schedule, r.initial_prompt, r.enabled, r.last_run_at,
        \\  r.next_run_at, r.last_status, r.last_error
        \\FROM routines r
        \\JOIN workspace_item_tasks t ON r.task_id = t.id
        \\JOIN workspace_items i ON t.workspace_item_id = i.id
        \\ORDER BY
        \\  CASE WHEN r.next_run_at IS NULL THEN 1 ELSE 0 END,
        \\  r.next_run_at ASC
    ;

    var rows = sqlite_db.query(allocator, sql, &.{}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch routines" }) });
    };
    defer rows.deinit();

    var entries = std.ArrayList(http_response.RoutinesListEntry).empty;
    defer entries.deinit(allocator);

    while (try rows.next()) |row| {
        defer row.deinit(allocator);

        // r.enabled is INTEGER 0/1 stored as TEXT in the Row API
        // (every column comes back as text). Anything non-"1" → false.
        const enabled_int = std.fmt.parseInt(i64, row.values[7], 10) catch 0;

        // r.last_status is TEXT, may be NULL. NULL or empty → return
        // null (== "never fired", same semantic as RoutineRunStatus.idle).
        // "success"/"failed"/"running" are returned as the same string
        // literals. Unknown values also → null (defensive default so
        // the API never returns an enum variant the frontend doesn't
        // know about). The returned strings are either null or
        // static literals — no use-after-free when the row is
        // deinit'd below.
        const last_status: ?[]const u8 = blk: {
            if (row.values[10].len == 0) break :blk null;
            if (std.mem.eql(u8, row.values[10], "success")) break :blk "success";
            if (std.mem.eql(u8, row.values[10], "failed")) break :blk "failed";
            if (std.mem.eql(u8, row.values[10], "running")) break :blk "running";
            break :blk null;
        };

        try entries.append(allocator, .{
            .id = try allocator.dupe(u8, row.values[0]),
            .task_id = try allocator.dupe(u8, row.values[1]),
            .workspace_id = try allocator.dupe(u8, row.values[2]),
            .workspace_item_id = try allocator.dupe(u8, row.values[3]),
            .task_name = try allocator.dupe(u8, row.values[4]),
            .schedule = try allocator.dupe(u8, row.values[5]),
            .initial_prompt = try allocator.dupe(u8, row.values[6]),
            .enabled = enabled_int == 1,
            .last_run_at = if (row.values[8].len == 0) null else try allocator.dupe(u8, row.values[8]),
            .next_run_at = try allocator.dupe(u8, row.values[9]),
            .last_status = last_status,
            .last_error = if (row.values[11].len == 0) null else try allocator.dupe(u8, row.values[11]),
        });
    }

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeRoutinesListResponse(allocator, entries.items) });
}

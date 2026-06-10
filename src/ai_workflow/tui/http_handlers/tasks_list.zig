const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// Default page size when the client doesn't pass `limit`.
const DEFAULT_PAGE_SIZE: u32 = 20;

/// Maximum page size (guards against a client asking for a million rows).
const MAX_PAGE_SIZE: u32 = 100;

/// GET /api/workspaces/:workspace_id/items/:item_id/tasks
/// Optional query params:
///   - limit: u32, defaults to 20, max 100
///   - cursor: string (the `created_at` of the last task from the previous page)
/// Response: `{ tasks: [...], count, has_more, next_cursor }`
pub fn tasksListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const query = req.query;

    // Parse limit (default 20, clamp to MAX_PAGE_SIZE; 0 → default).
    const limit_str = query.get("limit") orelse "20";
    const limit_parsed = std.fmt.parseInt(u32, limit_str, 10) catch DEFAULT_PAGE_SIZE;
    const limit: u32 = if (limit_parsed == 0)
        DEFAULT_PAGE_SIZE
    else if (limit_parsed > MAX_PAGE_SIZE)
        MAX_PAGE_SIZE
    else
        limit_parsed;

    // Optional cursor — null when absent or empty. The cursor is the
    // `created_at` string of the last task from the previous page.
    const cursor_raw = query.get("cursor");
    const cursor: ?[]const u8 = if (cursor_raw) |c| (if (c.len == 0) null else c) else null;

    const result = ai_mod.workspace_item_tasks.listWorkspaceItemTasksWithCursor(allocator, sqlite_db, item_id, limit, cursor) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch tasks" }) });
    };
    defer {
        for (result.tasks) |task| task.deinit(allocator);
        allocator.free(result.tasks);
    }

    // Convert to response format.
    var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
    defer task_responses.deinit(allocator);

    for (result.tasks) |task| {
        try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
            .id = task.id,
            .name = task.name,
            .workspace_item_id = task.workspace_item_id,
            .session_id = task.session_id,
            .created_at = task.created_at,
            .updated_at = task.updated_at,
        });
    }

    // next_cursor: the created_at of the last task in THIS page, when
    // has_more is true. null otherwise (so the frontend knows to stop).
    // The DB schema marks created_at NOT NULL, so this unwrap is safe
    // — but we defend with `orelse null` for the `?[]const u8` optional.
    const next_cursor: ?[]const u8 = blk: {
        if (!result.has_more) break :blk null;
        if (result.tasks.len == 0) break :blk null;
        break :blk result.tasks[result.tasks.len - 1].created_at orelse null;
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemTaskListResponse(allocator, task_responses.items, result.has_more, next_cursor) });
}

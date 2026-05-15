const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.ai_mod.models.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    // Parse request body
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    // Generate task ID using timestamp
    const ts = std.Io.Timestamp.now(ctx.io, .real);
    const task_id = try std.fmt.allocPrint(allocator, "task_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});

    const task = ai_mod.workspace_item_tasks.createWorkspaceItemTask(allocator, sqlite_db, task_id, json_body.name, item_id, json_body.session_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
    };
    defer task.deinit(allocator);

    return res.jsonResponse(.{ .status_code = 201, .data = try http_response.makeWorkspaceItemTaskResponse(allocator, http_response.WorkspaceItemTaskResponse{
        .id = task.id,
        .name = task.name,
        .workspace_item_id = task.workspace_item_id,
        .session_id = task.session_id,
        .created_at = task.created_at,
        .updated_at = task.updated_at,
    }) });
}


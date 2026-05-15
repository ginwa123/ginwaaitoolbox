const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
pub fn tasksDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.ai_mod.models.getSingleton();
    const sqlite_db = di.db;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    ai_mod.workspace_item_tasks.deleteWorkspaceItemTask(allocator, sqlite_db, task_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete task" }) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeTaskDeleteResponse(allocator, .{ .id = task_id, .success = true }) });
}


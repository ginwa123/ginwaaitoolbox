const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

/// DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
pub fn tasksDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const task_id = req.params.get("task_id") orelse "";
    if (task_id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "task_id required" }) });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            workspace_item_tasks.deleteWorkspaceItemTask(allocator, sqlite_db, task_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete task" }) });
            };

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try http_response.makeTaskDeleteResponse(allocator, .{ .id = task_id, .success = true }) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
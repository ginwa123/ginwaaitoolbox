const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

/// GET /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            const tasks = workspace_item_tasks.listWorkspaceItemTasks(allocator, sqlite_db, item_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch tasks" }) });
            };
            defer {
                for (tasks) |task| task.deinit(allocator);
                allocator.free(tasks);
            }

            // Convert to response format
            var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
            defer task_responses.deinit(allocator);

            for (tasks) |task| {
                try task_responses.append(allocator, http_response.WorkspaceItemTaskResponse{
                    .id = task.id,
                    .name = task.name,
                    .workspace_item_id = task.workspace_item_id,
                    .session_id = task.session_id,
                    .created_at = task.created_at,
                    .updated_at = task.updated_at,
                });
            }

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try http_response.makeWorkspaceItemTaskListResponse(allocator, task_responses.items) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
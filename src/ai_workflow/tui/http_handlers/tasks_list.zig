const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// GET /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksListHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const item_id = req.param("item_id") orelse "";
    if (item_id.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "item_id required" });
        return;
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            const tasks = workspace_item_tasks.listWorkspaceItemTasks(alloc, sqlite_db, item_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to fetch tasks" });
                return;
            };
            defer {
                for (tasks) |task| task.deinit(alloc);
                alloc.free(tasks);
            }

            // Convert to response format
            var task_responses = std.ArrayList(http_response.WorkspaceItemTaskResponse).empty;
            defer task_responses.deinit(alloc);

            for (tasks) |task| {
                try task_responses.append(alloc, http_response.WorkspaceItemTaskResponse{
                    .id = task.id,
                    .name = task.name,
                    .workspace_item_id = task.workspace_item_id,
                    .session_id = task.session_id,
                    .created_at = task.created_at,
                    .updated_at = task.updated_at,
                });
            }

            res.status = 200;
            res.body = try http_response.makeWorkspaceItemTaskListResponse(alloc, task_responses.items);
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}

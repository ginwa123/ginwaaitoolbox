const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// DELETE /api/chats/:task_id - Delete task by ID only (no workspace/item path needed)
pub fn taskDeleteByIdHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const task_id = req.param("task_id") orelse "";
    if (task_id.len == 0) {
        res.status_code = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "task_id required" });
        return;
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            workspace_item_tasks.deleteWorkspaceItemTask(alloc, sqlite_db, task_id) catch {
                res.status_code = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to delete task" });
                return;
            };

            res.status_code = 200;
            res.body = try http_response.makeTaskDeleteResponse(alloc, .{ .id = task_id, .success = true });
            return;
        }
    }
    res.status_code = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}

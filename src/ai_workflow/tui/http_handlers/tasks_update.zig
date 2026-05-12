const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// PUT /api/workspaces/tasks/:task_id - Update task by ID only (no workspace/item needed)
pub fn tasksUpdateByIdHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const task_id = req.param("task_id") orelse "";
    if (task_id.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "task_id required" });
        return;
    }

    // Parse request body
    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Request body required" });
        return;
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskUpdateRequest, alloc, body, .{}) catch {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON" });
        return;
    };

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            workspace_item_tasks.updateWorkspaceItemTask(alloc, sqlite_db, task_id, json_body.name, json_body.session_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to update task" });
                return;
            };

            res.status = 200;
            res.body = try std.fmt.allocPrint(alloc, "{{\"success\":true,\"id\":\"{s}\"}}", .{task_id});
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}

/// PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
pub fn tasksUpdateHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const task_id = req.param("task_id") orelse "";
    if (task_id.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "task_id required" });
        return;
    }

    // Parse request body
    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Request body required" });
        return;
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskUpdateRequest, alloc, body, .{}) catch {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON" });
        return;
    };

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            workspace_item_tasks.updateWorkspaceItemTask(alloc, sqlite_db, task_id, json_body.name, json_body.session_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to update task" });
                return;
            };

            res.status = 200;
            res.body = try std.fmt.allocPrint(alloc, "{{\"success\":true,\"id\":\"{s}\"}}", .{task_id});
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}

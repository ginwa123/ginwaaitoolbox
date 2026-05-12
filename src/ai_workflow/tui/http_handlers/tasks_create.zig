const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksCreateHandler(
    self: *http_server.HttpServer.ServerHandler,
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

    // Parse request body
    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Request body required" });
        return;
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, alloc, body, .{}) catch {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON" });
        return;
    };

    // Generate task ID using timestamp from handler's io
    const ts = std.Io.Timestamp.now(self.io, .real);
    const task_id = try std.fmt.allocPrint(alloc, "task_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            const task = workspace_item_tasks.createWorkspaceItemTask(alloc, sqlite_db, task_id, json_body.name, item_id, json_body.session_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to create task" });
                return;
            };
            defer task.deinit(alloc);

            res.status = 201;
            res.body = try http_response.makeWorkspaceItemTaskResponse(alloc, http_response.WorkspaceItemTaskResponse{
                .id = task.id,
                .name = task.name,
                .workspace_item_id = task.workspace_item_id,
                .session_id = task.session_id,
                .created_at = task.created_at,
                .updated_at = task.updated_at,
            });
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}

fn useCase(alloc: std.mem.Allocator) !void {
    _ = alloc;
}

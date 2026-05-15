const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_item_tasks = nalarcore.workspace_item_tasks;
const http_response = nalarcore.http_response;

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    // Parse request body
    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Request body required" }) });
    }

    const json_body = std.json.parseFromSliceLeaky(http_response.TaskCreateRequest, allocator, body, .{}) catch {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    // Generate task ID using timestamp
    const ts = std.Io.Timestamp.now(ctx.io, .real);
    const task_id = try std.fmt.allocPrint(allocator, "task_{d}", .{@divTrunc(ts.nanoseconds, 1_000_000)});

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            const task = workspace_item_tasks.createWorkspaceItemTask(allocator, sqlite_db, task_id, json_body.name, item_id, json_body.session_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create task" }) });
            };
            defer task.deinit(allocator);

            return res.jsonResponse(allocator, .{ .status_code = 201, .data = try http_response.makeWorkspaceItemTaskResponse(allocator, http_response.WorkspaceItemTaskResponse{
                .id = task.id,
                .name = task.name,
                .workspace_item_id = task.workspace_item_id,
                .session_id = task.session_id,
                .created_at = task.created_at,
                .updated_at = task.updated_at,
            }) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
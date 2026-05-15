const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_items = nalarcore.workspace_items;
const http_response = nalarcore.http_response;

/// GET /api/workspaces/:workspace_id/items - Get all workspace items
pub fn workspaceItemsListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }) });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            const items = workspace_items.listWorkspaceItems(allocator, sqlite_db, workspace_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace items" }) });
            };
            defer {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            }

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try http_response.makeWorkspaceItemListResponse(allocator, items) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}

/// GET /api/workspaces/:workspace_id/items/:item_id - Get a single workspace item
pub fn workspaceItemsGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            const item = workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace item" }) });
            };

            if (item) |i| {
                defer i.deinit(allocator);
                return res.jsonResponse(allocator, .{ .status_code = 200, .data = try http_response.makeWorkspaceItemGetResponse(allocator, .{
                    .id = i.id,
                    .workspace_id = i.workspace_id,
                    .item_type = i.item_type,
                    .name = i.name,
                    .path = i.path,
                    .created_at = i.created_at,
                    .updated_at = i.updated_at,
                }) });
            } else {
                return res.jsonResponse(allocator, .{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found" }) });
            }
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
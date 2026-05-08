const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_items = nalarcore.workspace_items;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// GET /api/workspaces/:workspace_id/items - Get all workspace items
pub fn workspaceItemsListHandler(
    _: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const workspace_id = req.param("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "workspace_id required" });
        return;
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            const items = workspace_items.listWorkspaceItems(alloc, sqlite_db, workspace_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to fetch workspace items" });
                return;
            };
            defer {
                for (items) |item| item.deinit(alloc);
                alloc.free(items);
            }

            res.status = 200;
            res.body = try http_response.makeWorkspaceItemListResponse(alloc, items);
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}

/// GET /api/workspaces/:workspace_id/items/:item_id - Get a single workspace item
pub fn workspaceItemsGetHandler(
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

            const item = workspace_items.getWorkspaceItem(alloc, sqlite_db, item_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to fetch workspace item" });
                return;
            };

            if (item) |i| {
                defer i.deinit(alloc);
                res.status = 200;
                res.body = try http_response.makeWorkspaceItemGetResponse(alloc, .{
                    .id = i.id,
                    .workspace_id = i.workspace_id,
                    .item_type = i.item_type,
                });
                return;
            } else {
                res.status = 404;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Workspace item not found" });
                return;
            }
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
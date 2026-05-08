const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_items = nalarcore.workspace_items;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// DELETE /api/workspaces/:workspace_id/items/:item_id - Delete a workspace item
pub fn workspaceItemsDeleteHandler(
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

            // Check if item exists first
            const existing = workspace_items.getWorkspaceItem(alloc, sqlite_db, item_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to fetch workspace item" });
                return;
            };

            if (existing == null) {
                res.status = 404;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Workspace item not found" });
                return;
            }
            defer existing.?.deinit(alloc);

            // Delete the item
            workspace_items.deleteWorkspaceItem(alloc, sqlite_db, item_id) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to delete workspace item" });
                return;
            };

            res.status = 200;
            res.body = try http_response.makeWorkspaceItemResponse(alloc, .{ .id = item_id });
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
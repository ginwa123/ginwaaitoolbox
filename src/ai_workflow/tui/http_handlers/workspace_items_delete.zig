const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_items = nalarcore.workspace_items;
const http_response = nalarcore.http_response;

/// DELETE /api/workspaces/:workspace_id/items/:item_id - Delete a workspace item
pub fn workspaceItemsDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            // Check if item exists first
            const existing = workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace item" }) });
            };

            if (existing == null) {
                return res.jsonResponse(allocator, .{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found" }) });
            }
            defer existing.?.deinit(allocator);

            // Delete the item
            workspace_items.deleteWorkspaceItem(allocator, sqlite_db, item_id) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to delete workspace item" }) });
            };

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try http_response.makeWorkspaceItemResponse(allocator, .{ .id = item_id }) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
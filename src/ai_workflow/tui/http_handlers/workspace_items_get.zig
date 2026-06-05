const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// GET /api/workspaces/:workspace_id/items - Get all workspace items
pub fn workspaceItemsListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }) });
    }

    const items = ai_mod.workspace_items.listWorkspaceItems(allocator, sqlite_db, workspace_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace items" }) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemListObjectResponse(allocator, items) });
}

/// GET /api/workspaces/:workspace_id/items/:item_id - Get a single workspace item
pub fn workspaceItemsGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const item_id = req.params.get("item_id") orelse "";
    if (item_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "item_id required" }) });
    }

    const item = ai_mod.workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to fetch workspace item" }) });
    };

    if (item) |i| {
        return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemGetResponse(allocator, .{
            .id = i.id,
            .workspace_id = i.workspace_id,
            .item_type = i.item_type,
            .name = i.name,
            .path = i.path,
            .created_at = i.created_at,
            .updated_at = i.updated_at,
        }) });
    } else {
        return res.jsonResponse(.{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Workspace item not found" }) });
    }
}


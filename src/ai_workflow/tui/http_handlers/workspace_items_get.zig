const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = nalarcore.llm_history;

pub const WorkspaceItemsListError = error{
    OutOfMemory,
    DatabaseError,
};

pub const WorkspaceItemsGetError = error{
    OutOfMemory,
    WorkspaceItemNotFound,
    DatabaseError,
};

/// GET /api/workspaces/:workspace_id/items - Get all workspace items
pub fn workspaceItemsListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "workspace_id required" }) });
    }

    const items = useCaseList(allocator, sqlite_db, workspace_id) catch |err| {
        const message: []const u8 = switch (err) {
            error.DatabaseError => "Failed to fetch workspace items",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemListObjectResponse(allocator, items) });
}

fn useCaseList(allocator: std.mem.Allocator, sqlite_db: *nalarcore.sqlite.SqliteBackend, workspace_id: []const u8) WorkspaceItemsListError![]const llm_history.WorkspaceItemInfo {
    return ai_mod.workspace_items.listWorkspaceItems(allocator, sqlite_db, workspace_id) catch {
        return error.DatabaseError;
    };
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

    const item = useCaseGet(allocator, sqlite_db, item_id) catch |err| {
        const status: u16 = switch (err) {
            error.WorkspaceItemNotFound => 404,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.WorkspaceItemNotFound => "Workspace item not found",
            error.DatabaseError => "Failed to fetch workspace item",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkspaceItemGetResponse(allocator, .{
        .id = item.id,
        .workspace_id = item.workspace_id,
        .item_type = item.item_type,
        .name = item.name,
        .path = item.path,
        .created_at = item.created_at,
        .updated_at = item.updated_at,
    }) });
}

fn useCaseGet(allocator: std.mem.Allocator, sqlite_db: *nalarcore.sqlite.SqliteBackend, item_id: []const u8) WorkspaceItemsGetError!llm_history.WorkspaceItemInfo {
    const opt = ai_mod.workspace_items.getWorkspaceItem(allocator, sqlite_db, item_id) catch {
        return error.DatabaseError;
    };
    return opt orelse error.WorkspaceItemNotFound;
}
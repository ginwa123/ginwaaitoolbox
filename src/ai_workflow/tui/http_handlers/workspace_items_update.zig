const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const workspace_items = nalarcore.workspace_items;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// PUT /api/workspaces/:workspace_id/items/:item_id - Update a workspace item
pub fn workspaceItemsUpdateHandler(
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

    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Request body required" });
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON" });
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Get item_type (required in update)
    const item_type_val = root.get("item_type") orelse {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "item_type required" });
        return;
    };
    if (item_type_val != .string) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "item_type must be a string" });
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

            // Get the current workspace_id for the update
            const current_workspace_id = existing.?.workspace_id;

            // Update the item
            workspace_items.updateWorkspaceItem(alloc, sqlite_db, item_id, current_workspace_id, item_type_val.string) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to update workspace item" });
                return;
            };

            res.status = 200;
            res.body = try http_response.makeWorkspaceItemGetResponse(alloc, .{
                .id = item_id,
                .workspace_id = current_workspace_id,
                .item_type = item_type_val.string,
                .created_at = null,
                .updated_at = null,
            });
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
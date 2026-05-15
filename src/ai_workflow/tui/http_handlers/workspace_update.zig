const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;

/// PUT /api/workspaces/:id
pub fn workspaceUpdateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "id is required" }) });
    }

    const body = req.body;

    if (body.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    const name_val = root.get("name") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name is required" }) });
    };
    if (name_val != .string) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name must be a string" }) });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            sqlite_db.exec(allocator, "UPDATE workspaces SET name = ?, updated_at = datetime('now') WHERE id = ?", &.{ name_val.string, id }) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to update workspace" }) });
            };

            return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\",\"name\":\"{s}\"}}", .{ id, name_val.string }) });
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = "{\"error\":\"Server not initialized\"" });
}
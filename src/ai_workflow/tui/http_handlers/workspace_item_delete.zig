const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// DELETE /api/workspaces/:workspace_id/items/:item_id
pub fn workspaceItemDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const item_id = req.path_param("item_id") orelse "unknown";
    const allocator = ctx.allocator;
    const body = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{item_id});
    return res.jsonResponse(.{ .status_code = 200, .data = body });
}
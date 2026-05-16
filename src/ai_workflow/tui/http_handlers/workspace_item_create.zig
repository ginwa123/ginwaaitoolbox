const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// POST /api/workspaces/:workspace_id/items
pub fn workspaceItemCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const workspace_id = req.path_param("workspace_id") orelse "unknown";
    const allocator = ctx.allocator;
    const body = try std.fmt.allocPrint(allocator, "{{\"id\":\"item_placeholder\",\"workspace_id\":\"{s}\",\"name\":\"New Item\",\"icon\":\"📄\",\"path\":null}}", .{workspace_id});
    return res.jsonResponse(.{ .status_code = 201, .data = body });
}
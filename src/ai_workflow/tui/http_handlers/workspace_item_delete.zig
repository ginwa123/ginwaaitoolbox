const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// DELETE /api/workspaces/:workspace_id/items/:item_id
pub fn workspaceItemDeleteHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const item_id = req.param("item_id") orelse "unknown";
    res.body = try std.fmt.allocPrint(res.arena, "{{\"success\":true,\"id\":\"{s}\"}}", .{item_id});
}
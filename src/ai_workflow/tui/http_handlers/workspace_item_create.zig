const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// POST /api/workspaces/:workspace_id/items
pub fn workspaceItemCreateHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const workspace_id = req.param("workspace_id") orelse "unknown";
    res.status_code = 201;
    res.body = try std.fmt.allocPrint(res.arena, "{{\"id\":\"item_placeholder\",\"workspace_id\":\"{s}\",\"name\":\"New Item\",\"icon\":\"📄\",\"path\":null}}", .{workspace_id});
}
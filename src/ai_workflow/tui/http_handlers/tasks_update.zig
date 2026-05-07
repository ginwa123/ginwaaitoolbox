const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// PUT /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
pub fn tasksUpdateHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const task_id = req.param("task_id") orelse "unknown";
    res.body = try std.fmt.allocPrint(res.arena, "{{\"success\":true,\"id\":\"{s}\"}}", .{task_id});
}
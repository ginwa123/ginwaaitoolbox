const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const http_response = root_mod.http_response;

const httpz = http_server.httpz;

/// DELETE /api/workspaces/:workspace_id/items/:item_id/tasks/:task_id
pub fn tasksDeleteHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const task_id = req.param("task_id") orelse "unknown";
    res.body = try http_response.makeTaskDeleteResponse(res.arena, .{ .id = task_id });
}
const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const http_response = root_mod.http_response;

const httpz = http_server.httpz;

/// POST /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksCreateHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req;
    res.content_type = .JSON;
    res.status = 201;
    res.body = try http_response.makeTaskCreateResponse(res.arena, .{
        .id = "task_placeholder",
        .name = "New Task",
        .description = null,
        .completed = false,
    });
}
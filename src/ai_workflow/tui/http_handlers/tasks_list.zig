const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// GET /api/workspaces/:workspace_id/items/:item_id/tasks
pub fn tasksListHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req.param("item_id");
    res.content_type = .JSON;
    res.body = "{\"tasks\":[]}";
}
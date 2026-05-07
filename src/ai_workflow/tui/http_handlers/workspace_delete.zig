const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;

/// DELETE /api/workspaces/:id
pub fn workspaceDeleteHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const id = req.param("id") orelse "";
    if (id.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"id required\"}";
        return;
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            sqlite_db.exec(alloc, "DELETE FROM workspaces WHERE id = ?", &.{id}) catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to delete workspace\"}";
                return;
            };

            res.status = 200;
            res.body = try std.fmt.allocPrint(alloc, "{{\"success\":true,\"id\":\"{s}\"}}", .{id});
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
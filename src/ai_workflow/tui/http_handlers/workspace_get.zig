const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;

/// GET /api/workspaces/:id
pub fn workspaceGetHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
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

            var rows = sqlite_db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces WHERE id = ?", &.{id}) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };
            defer rows.deinit();

            const row = rows.next() catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to fetch row\"}";
                return;
            };
            if (row) |r| {
                defer r.deinit(alloc);
                const ws_id = r.values[0];
                const name = r.values[1];
                const created_at = r.values[2];
                const updated_at = r.values[3];
                res.status = 200;
                res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"}}", .{ ws_id, name, created_at, updated_at });
                return;
            } else {
                res.status = 404;
                res.body = "{\"error\":\"Workspace not found\"}";
                return;
            }
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;

/// GET /api/workspaces
pub fn workspacesListHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            var rows = sqlite_db.query(alloc, "SELECT id, session_id FROM workspaces ORDER BY rowid DESC", &[_][]const u8{}) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };
            defer rows.deinit();

            var json_buf = std.ArrayList(u8).empty;
            try json_buf.appendSlice(alloc, "{\"workspaces\":[");
            var first = true;
            while (true) {
                const row_opt = rows.next() catch {
                    res.status = 500;
                    res.body = "{\"error\":\"Failed to iterate rows\"}";
                    return;
                };
                const row = row_opt orelse break;
                defer row.deinit(alloc);
                if (!first) try json_buf.appendSlice(alloc, ",");
                first = false;
                const id = row.values[0];
                const session_id = row.values[1];
                try json_buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"session_id\":\"{s}\"}}", .{ id, session_id }));
            }
            try json_buf.appendSlice(alloc, "]}");
            res.status = 200;
            res.body = try json_buf.toOwnedSlice(alloc);
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
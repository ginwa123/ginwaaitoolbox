const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;

/// GET /api/workspaces
pub fn workspacesListHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            var rows = sqlite_db.query(alloc, "SELECT id, name, created_at, updated_at FROM workspaces ORDER BY created_at DESC", &[_][]const u8{}) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Database query failed" });
                return;
            };
            defer rows.deinit();

            var json_buf = std.ArrayList(u8).empty;
            try json_buf.appendSlice(alloc, "{\"workspaces\":[");
            var first = true;
            while (true) {
                const row_opt = rows.next() catch {
                    res.status = 500;
                    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to iterate rows" });
                    return;
                };
                const row = row_opt orelse break;
                defer row.deinit(alloc);
                if (!first) try json_buf.appendSlice(alloc, ",");
                first = false;
                const id = row.values[0];
                const name = row.values[1];
                const created_at = row.values[2];
                const updated_at = row.values[3];
                try json_buf.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\",\"icon\":\"📁\",\"items\":[],\"expanded\":false}}", .{ id, name, created_at, updated_at }));
            }
            try json_buf.appendSlice(alloc, "]}");
            res.status = 200;
            res.body = try json_buf.toOwnedSlice(alloc);
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const tui_check_session_exists = nalarcore.tui_check_session_exists;

/// Check if a session exists in the database
pub fn session_exist_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;
            const exists = tui_check_session_exists.check_session_exists(server.allocator, sqlite_db, session_id);
            res.status = 200;
            res.body = try std.fmt.allocPrint(req.arena, "{{\"session_id\":\"{s}\",\"exists\":{s}}}", .{ session_id, if (exists) "true" else "false" });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

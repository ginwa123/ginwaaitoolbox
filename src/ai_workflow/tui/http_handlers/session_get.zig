const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const llm_history = nalarcore.llm_history;

/// Get a session by ID
pub fn session_get_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
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
            const session = llm_history.get_session(alloc, sqlite_db, session_id) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };

            if (session) |s| {
                const response = try std.fmt.allocPrint(alloc, "{{\"sessionId\":\"{s}\",\"sessionDir\":\"{s}\",\"createdAt\":\"{s}\",\"agent\":\"{s}\",\"sessionName\":\"{s}\"}}", .{ s.session_id, s.session_dir, s.created_at, s.agent, s.session_name });
                s.deinit(alloc);
                res.status = 200;
                res.body = response;
            } else {
                res.status = 404;
                res.body = "{\"error\":\"Session not found\"}";
            }
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

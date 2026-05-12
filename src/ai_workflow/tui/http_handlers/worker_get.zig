const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const llm_history = nalarcore.llm_history;

/// Get a worker by session_id
pub fn worker_get_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
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

            const worker = llm_history.getWorkerBySessionId(alloc, sqlite_db, session_id) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };

            if (worker) |w| {
                const response = try std.fmt.allocPrint(alloc,
                    "{{\"sessionId\":\"{s}\",\"workingDirectory\":\"{s}\",\"lastActivity\":{},\"lastActivityDescription\":\"{s}\"}}",
                    .{ w.session_id, w.working_directory, w.last_activity, w.last_activity_description }
                );
                w.deinit(alloc);
                res.status = 200;
                res.body = response;
            } else {
                res.status = 404;
                res.body = "{\"error\":\"Worker not found\"}";
            }
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
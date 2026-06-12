const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const llm_history = nalarcore.llm_history;

/// Get a worker by session_id
pub fn workerGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse( .{ .status_code = 400, .data = "{\"error\":\"Missing session_id\"" });
    };

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            const worker = llm_history.getWorkerBySessionId(allocator, sqlite_db, session_id) catch {
                return res.jsonResponse( .{ .status_code = 500, .data = "{\"error\":\"Database query failed\"" });
            };

            if (worker) |w| {
                const response = try std.fmt.allocPrint(allocator,
                    "{{\"sessionId\":\"{s}\",\"workingDirectory\":\"{s}\",\"lastActivity\":{},\"lastActivityDescription\":\"{s}\"}}",
                    .{ w.session_id, w.working_directory, w.last_activity, w.last_activity_description }
                );
                w.deinit(allocator);
                return res.jsonResponse( .{ .status_code = 200, .data = response });
            } else {
                return res.jsonResponse( .{ .status_code = 404, .data = "{\"error\":\"Worker not found\"" });
            }
        }
    }
    return res.jsonResponse( .{ .status_code = 500, .data = "{\"error\":\"Server not initialized\"" });
}
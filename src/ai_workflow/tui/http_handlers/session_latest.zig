const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const session_helpers = nalarcore.session_helpers;

/// Get the latest session by working directory
pub fn session_latest_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;

    const query = try req.query();
    const cwd = query.get("cwd") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing cwd parameter\"}";
        return;
    };

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;
            var arena = std.heap.ArenaAllocator.init(server.allocator);
            defer arena.deinit();

            const latest_session = session_helpers.getLatestSessionByDir(arena.allocator(), sqlite_db, cwd) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };

            if (latest_session) |session| {
                defer {
                    arena.allocator().free(session.session_id);
                    arena.allocator().free(session.cwd);
                    arena.allocator().free(session.created_at);
                }
                res.status = 200;
                res.body = try std.fmt.allocPrint(req.arena, "{{\"session_id\":\"{s}\",\"cwd\":\"{s}\",\"created_at\":\"{s}\",\"found\":true}}", .{ session.session_id, session.cwd, session.created_at });
            } else {
                res.status = 200;
                res.body = "{\"found\":false}";
            }
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

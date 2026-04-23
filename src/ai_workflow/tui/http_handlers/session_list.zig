const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;
const llm_history = nalarcore.llm_history;

/// List all sessions - returns sessions from database with cursor pagination
/// Optionally filtered by session_dir query parameter
pub fn session_list_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const query = try req.query();
    const limit_str = query.get("limit") orelse "50";
    const cursor = query.get("cursor");
    const session_dir = query.get("session_dir"); // Optional filter by directory
    const limit_val = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            // Use unified getSessionListWithCursor with session_dir support
            const result = llm_history.getSessionListWithCursor(alloc, sqlite_db, null, null, session_dir, limit_val, cursor) catch {
                res.status = 500;
                res.body = "{\"error\":\"Database query failed\"}";
                return;
            };
            defer {
                for (result.sessions) |s| s.deinit(alloc);
                alloc.free(result.sessions);
            }

            // Determine if there are more results
            const has_more = result.sessions.len == @as(usize, limit_val);
            // Next cursor is the created_at of the last session
            const next_cursor: ?[]const u8 = if (result.sessions.len > 0)
                result.sessions[result.sessions.len - 1].created_at
            else
                null;

            // Build JSON response with cursor pagination
            const response = try llm_history.buildSessionListJson(alloc, result.sessions, result.total, has_more, next_cursor);

            res.status = 200;
            res.body = response;
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

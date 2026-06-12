const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const session_helpers = root_mod.session_helpers;
const http_response = root_mod.http_response;

/// Get the latest session by working directory
pub fn sessionLatestHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const cwd = req.query.get("cwd") orelse {
        return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing cwd parameter" }) });
    };

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*root_mod.ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const latest_session = session_helpers.getLatestSessionByDir(arena.allocator(), sqlite_db, cwd) catch {
                return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" }) });
            };

            if (latest_session) |session| {
                defer {
                    arena.allocator().free(session.session_id);
                    arena.allocator().free(session.cwd);
                    arena.allocator().free(session.created_at);
                }
                return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"cwd\":\"{s}\",\"created_at\":\"{s}\",\"found\":true}}", .{ session.session_id, session.cwd, session.created_at }) });
            } else {
                return res.jsonResponse( .{ .status_code = 200, .data = "{\"found\":false}" });
            }
        }
    }
    return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
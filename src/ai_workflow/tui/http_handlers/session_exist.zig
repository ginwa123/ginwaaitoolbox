const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const tui_check_session_exists = root_mod.tui_check_session_exists;
const http_response = root_mod.http_response;

/// Check if a session exists in the database
pub fn session_exist_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse( .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*root_mod.ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;
            const exists = tui_check_session_exists.check_session_exists(allocator, sqlite_db, session_id);
            return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"session_id\":\"{s}\",\"exists\":{s}}}", .{ session_id, if (exists) "true" else "false" }) });
        }
    }
    return res.jsonResponse( .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
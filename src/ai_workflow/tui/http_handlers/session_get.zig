const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;
const llm_history = ai_mod.llm_history;

/// Get a session by ID
pub fn session_get_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };
    const di = try nalarcore.ai_mod.models.getSingleton();
    const sqlite_db = di.db;

    const session = llm_history.get_session(allocator, sqlite_db, session_id) catch {
        return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" }) });
    };

    if (session) |s| {
        const response = try std.fmt.allocPrint(allocator, "{{\"sessionId\":\"{s}\",\"cwd\":\"{s}\",\"createdAt\":\"{s}\",\"agent\":\"{s}\",\"sessionName\":\"{s}\"}}", .{ s.session_id, s.cwd, s.created_at, s.agent, s.session_name });
        s.deinit(allocator);
        return res.jsonResponse(allocator, .{ .status_code = 200, .data = response });
    } else {
        return res.jsonResponse(allocator, .{ .status_code = 404, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Session not found" }) });
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}


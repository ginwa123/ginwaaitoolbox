const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;

const http_response = root_mod.http_response;

/// Ping endpoint for connection health checks
/// Returns connection status for a given session
pub fn ping_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };
    if (gserverz.global_server) |server| {
        const response = if (server.sse_manager.hasSession(session_id))
            try std.fmt.allocPrint(allocator, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"connected\":true}}", .{session_id})
        else
            try std.fmt.allocPrint(allocator, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{session_id});
        return res.jsonResponse(allocator, .{ .status_code = 200, .data = response });
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Server not initialized" }) });
}
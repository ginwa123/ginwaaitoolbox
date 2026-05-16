const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// Notify server that client is disconnecting from SSE stream
/// This removes ALL SSE connections for the session (forceful disconnect of entire session)
pub fn sseDisconnectHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.path_param("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"Missing session_id\"}" });
    };

    if (gserverz.global_server) |server| {
        const removed_count = server.sse_manager.removeSession(session_id);
        std.log.info("SSE: Session {s} disconnected, {d} client(s) removed", .{ session_id, removed_count });
        const body = try std.fmt.allocPrint(allocator, "{{\"status\":\"disconnected\",\"removed_clients\":{d}}}", .{removed_count});
        return res.jsonResponse(.{ .status_code = 200, .data = body });
    }

    return res.jsonResponse(.{ .status_code = 500, .data = "{\"error\":\"Server not available\"}" });
}

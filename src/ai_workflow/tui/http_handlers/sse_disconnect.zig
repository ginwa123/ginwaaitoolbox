const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// Notify server that client is disconnecting from SSE stream
/// This removes ALL SSE connections for the session (forceful disconnect of entire session)
pub fn sseDisconnectHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (http_server.global_server) |server| {
        const removed_count = server.sse_manager.removeSession(session_id);
        std.log.info("SSE: Session {s} disconnected, {d} client(s) removed", .{ session_id, removed_count });
        res.status = 200;
        res.body = try std.fmt.allocPrint(server.allocator, "{{\"status\":\"disconnected\",\"removed_clients\":{d}}}", .{removed_count});
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Server not available\"}";
}

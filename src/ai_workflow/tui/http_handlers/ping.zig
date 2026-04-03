const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// Ping endpoint for connection health checks
/// Returns connection status for a given session
pub fn ping_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };
    if (http_server.global_server) |server| {
        res.status = 200;
        if (server.sse_manager.hasSession(session_id)) {
            res.body = try std.fmt.allocPrint(req.arena, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"connected\":true}}", .{session_id});
        } else {
            res.body = try std.fmt.allocPrint(req.arena, "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",\"reconnect\":true}}", .{session_id});
        }
        return;
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}

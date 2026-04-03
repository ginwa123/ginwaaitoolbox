const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const cancellation_registry = root_mod.session.cancellation_registry;

const httpz = http_server.httpz;

/// Cancel an active session
/// Path param: session_id
/// Returns JSON with cancelled status
pub fn sessionCancelHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (cancellation_registry.get_global_registry()) |registry| {
        registry.cancel(session_id);
        res.status = 200;
        res.body = try std.fmt.allocPrint(req.arena, "{{\"status\":\"cancelled\",\"session_id\":\"{s}\"}}", .{session_id});
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Cancellation registry not available\"}";
}

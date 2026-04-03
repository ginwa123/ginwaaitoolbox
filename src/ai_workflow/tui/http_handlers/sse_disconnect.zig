const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// Notify server that client is disconnecting from SSE stream
/// This removes the SSE connection from the manager so server can clean up
pub fn sseDisconnectHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    res.content_type = .JSON;
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    if (http_server.global_server) |server| {
        server.sse_manager.remove(session_id);
        std.log.info("SSE client notified disconnect: session_id={s}", .{session_id});
        res.status = 200;
        res.body = "{\"status\":\"disconnected\"}";
        return;
    }

    res.status = 500;
    res.body = "{\"error\":\"Server not available\"}";
}

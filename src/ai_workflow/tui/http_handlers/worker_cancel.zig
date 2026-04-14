const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const session_registry = root_mod.session.session_registry;

const httpz = http_server.httpz;

/// Cancel a running worker
/// Path params:
///   - session_id: worker ID to cancel
/// Returns JSON with cancellation result
pub fn worker_cancel_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    // Check if session exists
    if (session_registry.get_global_registry()) |registry| {
        if (!registry.is_registered(session_id)) {
            res.status = 404;
            res.body = "{\"error\":\"Worker not found\"}";
            return;
        }
    }

    // Cancel and mark as stopped in session registry
    if (session_registry.get_global_registry()) |registry| {
        registry.cancel(session_id);
        registry.mark_stopped(session_id);
    }

    res.status = 200;
    res.body = try std.fmt.allocPrint(alloc,
        "{{\"id\":\"{s}\",\"cancelled\":true}}",
        .{session_id}
    );
}

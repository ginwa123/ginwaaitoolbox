const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const session_registry = root_mod.session.session_registry;

const httpz = http_server.httpz;

/// Get worker status
/// Path params:
///   - session_id: worker ID to check
/// Returns JSON with worker status info
pub fn worker_status_handler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"Missing session_id\"}";
        return;
    };

    // Get worker status from activity registry
    var status: []const u8 = "unknown";
    var is_running = false;
    var queue_count: u32 = 0;
    var is_registered = false;

    if (session_registry.get_global_registry()) |registry| {
        is_registered = registry.is_registered(session_id);

        if (registry.is_stopped(session_id)) {
            status = "stopped";
            is_running = false;
        } else if (registry.is_running(session_id)) {
            status = "running";
            is_running = true;
        } else if (is_registered) {
            status = "idle";
            is_running = false;
        } else {
            status = "not_found";
            is_running = false;
        }

        // Get queue count
        if (registry.message_queues.get(session_id)) |queue| {
            queue_count = @intCast(queue.items.len);
        }
    } else {
        res.status = 500;
        res.body = "{\"error\":\"Activity registry not available\"}";
        return;
    }

    res.status = 200;
    res.body = try std.fmt.allocPrint(alloc,
        "{{\"id\":\"{s}\",\"status\":\"{s}\",\"is_running\":{},\"queue_count\":{},\"registered\":{}}}",
        .{ session_id, status, is_running, queue_count, is_registered }
    );
}

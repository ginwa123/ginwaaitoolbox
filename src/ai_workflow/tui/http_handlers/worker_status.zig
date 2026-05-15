const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const session_registry = root_mod.session.session_registry;

/// Get worker status
/// Path params:
///   - session_id: worker ID to check
/// Returns JSON with worker status info
pub fn worker_status_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse( .{ .status_code = 400, .data = "{\"error\":\"Missing session_id\"" });
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
        return res.jsonResponse( .{ .status_code = 500, .data = "{\"error\":\"Activity registry not available\"" });
    }

    return res.jsonResponse( .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"status\":\"{s}\",\"is_running\":{},\"queue_count\":{},\"registered\":{}}}",
        .{ session_id, status, is_running, queue_count, is_registered }) });
}
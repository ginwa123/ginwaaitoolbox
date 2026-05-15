const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const session_registry = root_mod.session.session_registry;

/// Cancel a running worker
/// Path params:
///   - session_id: worker ID to cancel
/// Returns JSON with cancellation result
pub fn worker_cancel_handler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = "{\"error\":\"Missing session_id\"" });
    };

    // Check if session exists
    if (session_registry.get_global_registry()) |registry| {
        if (!registry.is_registered(session_id)) {
            return res.jsonResponse(allocator, .{ .status_code = 404, .data = "{\"error\":\"Worker not found\"" });
        }
    }

    // Cancel and mark as stopped in session registry
    if (session_registry.get_global_registry()) |registry| {
        registry.cancel(session_id);
        registry.mark_stopped(session_id);
    }

    return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"cancelled\":true}}",
        .{session_id}) });
}
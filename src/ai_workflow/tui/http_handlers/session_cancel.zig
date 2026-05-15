const std = @import("std");
const root_mod = @import("nalarcore");
const session_registry = root_mod.session.session_registry;
const gserverz = root_mod.gserverz;
const http_response = root_mod.http_response;

/// Cancel an active session
/// Path param: session_id
/// Returns JSON with cancelled status
pub fn sessionCancelHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    if (session_registry.get_global_registry()) |registry| {
        registry.cancel(session_id);
        return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"status\":\"cancelled\",\"session_id\":\"{s}\"}}", .{session_id}) });
    }

    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Cancellation registry not available" }) });
}
const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const session_registry = root_mod.session.session_registry;
const http_response = root_mod.http_response;

/// Delete a specific message from the session's message queue
/// Path param: session_id
/// Query param: message (the exact message string to delete)
/// Returns JSON with deletion status
pub fn sessionQueueDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    // Get message from query parameter
    const message = req.query.get("message") orelse {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing message query parameter" }) });
    };

    // Call the activity registry method
    if (session_registry.get_global_registry()) |registry| {
        registry.deleteQueueMessages(session_id, message);
        return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"status\":\"deleted\",\"session_id\":\"{s}\",\"message\":\"{s}\"}}", .{ session_id, message }) });
    }

    return res.jsonResponse(allocator, .{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Activity registry not available" }) });
}
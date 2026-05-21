const std = @import("std");
const nalarcore = @import("nalarcore");
const http_response = @import("http_response.zig");
const gserverz = nalarcore.gserverz;
const llm_history = nalarcore.llm_history;

/// Stop/cancel an LLM session by setting the cancelled flag in the database.
/// The workflow's loop will check this flag and break out, stopping the async IO.
pub fn sessionStopHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();

    // Extract session_id from URL path parameter ":session"
    const session_id = req.params.get("session") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id path parameter" }),
        });
    };

    // Cancel the session in the database (sets cancelled = 1)
    llm_history.cancelSession(allocator, di.db, session_id) catch |err| {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    const success_json = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"session_id\":\"{s}\"}}", .{session_id});
    return res.jsonResponse(.{
        .status_code = 200,
        .data = success_json,
    });
}

const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const gserverz = nalarcore.gserverz;
const http_response = nalarcore.http_response;
const notifications = nalarcore.notifications_mod;

/// POST /api/notify/test
///
/// Fires a fixed test OS notification so the user can verify their
/// system can display notifications without running a full LLM stream.
/// The request body is ignored — always uses the same test message.
///
/// On success:  200 {"ok": true}
/// On failure:  200 {"ok": false, "error": "<error name>"}
///
/// We return 200 on failure (not 500) because the typical failure
/// mode is "notify-send is not installed" — a 500 would make the
/// frontend think the backend is broken. The `ok: false` payload
/// gives the UI enough info to show a helpful hint.
pub fn notifyTestHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;
    const io = ctx.io;

    notifications.notify(io, allocator, "nalar notification test", "If you can read this, OS notifications work.") catch |err| {
        const err_msg = @errorName(err);
        const data = std.fmt.allocPrint(allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{err_msg}) catch {
            return res.jsonResponse(.{
                .status_code = 500,
                .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
            });
        };
        return res.jsonResponse(.{ .status_code = 200, .data = data });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = "{\"ok\":true}" });
}

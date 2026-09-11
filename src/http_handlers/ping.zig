//! Ping endpoint for connection health checks.
//!
//! Returns connection status for a given session:
//!   - 200 with `"connected": true` if the session has an active
//!     SSE stream
//!   - 200 with `"reconnect": true` if the session is registered
//!     but no live SSE stream
//!   - 400 if `session_id` is missing
//!   - 500 if the server singleton is not initialized
//!
//! Layered as `useCase` (resolve session + check SSE) and a thin
//! handler that maps the outcome + errors to status codes / JSON.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = nalarcore.http_response;

pub const PingError = error{
    ServerNotInitialized,
};

/// Tagged outcome of the ping use-case.
pub const PingResult = union(enum) {
    connected,
    reconnect,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(session_id: []const u8) PingError!PingResult {
    const server = gserverz.global_server orelse return error.ServerNotInitialized;
    if (server.sse_manager.hasSession(session_id)) return .connected;
    return .reconnect;
}

// =====================================================================
// Handler
// =====================================================================

pub fn pingHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
    _: *anyopaque,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Per `nalar-http-handler-thin-wrapper-pattern`, use
    // `req.params.get` rather than the (non-existent) `path_param`.
    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(allocator, .{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }),
        });
    };

    const outcome = useCase(session_id) catch |err| {
        const status: u16 = switch (err) {
            error.ServerNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.ServerNotInitialized => "Server not initialized",
        };
        return res.jsonResponse(allocator, .{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const connected_field = switch (outcome) {
        .connected => "\"connected\":true",
        .reconnect => "\"reconnect\":true",
    };
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"app_type\":\"tui\",\"command_type\":\"pong\",\"session_id\":\"{s}\",{s}}}",
        .{ session_id, connected_field },
    );
    return res.jsonResponse(allocator, .{ .status_code = 200, .data = body });
}
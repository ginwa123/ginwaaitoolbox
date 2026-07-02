//! `POST /test/shutdown` — gracefully shut the server down.
//!
//! Triggers `di.server.shutdown()` and returns 200 with a status
//! message. The server continues to serve in-flight requests after
//! this returns; the actual process exit happens once the listener
//! loop observes the shutdown flag.
//!
//! Layered as `useCase` (call shutdown) and a thin handler that
//! maps the outcome to the JSON response.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const http_response = nalarcore.http_response;

pub const ShutdownError = error{
    GlobalContextNotInitialized,
};

pub const ShutdownResponse = struct {
    message: []const u8,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase() ShutdownError!ShutdownResponse {
    const di = nalarcore.getSingleton() catch return error.GlobalContextNotInitialized;
    di.server.shutdown();
    return .{ .message = "Server shutdown initiated" };
}

// =====================================================================
// Handler
// =====================================================================

pub fn shutdownHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    _ = req;
    const allocator = ctx.allocator;

    const response = useCase() catch |err| {
        const status: u16 = switch (err) {
            error.GlobalContextNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.GlobalContextNotInitialized => "Global context not initialized",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}
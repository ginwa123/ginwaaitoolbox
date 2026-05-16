const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

pub const ShutdownResponse = struct {
    message: []const u8,
};

/// POST /test/shutdown
/// Gracefully shutdown the server
pub fn shutdownHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const di = try nalar_core.getSingleton();
    const allocator = ctx.allocator;
    _ = req;
    di.server.shutdown();
    const response = ShutdownResponse{ .message = "Server shutdown initiated" };
    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});

    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}


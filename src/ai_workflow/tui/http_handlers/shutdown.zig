const std = @import("std");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

pub const ShutdownResponse = struct {
    message: []const u8,
};

/// POST /test/shutdown
/// Gracefully shutdown the server
pub fn shutdownHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    _ = req;
    
    std.log.info("Shutdown request received, initiating graceful shutdown...", .{});
    
    // Use global_server to access the GinwaServer instance and call shutdown
    if (gserverz.global_server) |server| {
        server.shutdown();
    } else {
        std.log.err("Global server not available", .{});
    }
    
    const response = ShutdownResponse{ .message = "Server shutdown initiated" };
    const json_str = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(json_str);
    
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}
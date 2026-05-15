const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;

/// GET /health
pub fn healthHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    _ = req;
    const ts = std.Io.Clock.now(.real, ctx.io);
    const timestamp: i64 = ts.toSeconds();
    return res.jsonResponse(allocator, .{ .status_code = 200, .data = try http_response.makeHealthResponse(allocator, .{ .status = "ok", .timestamp = timestamp }) });
}

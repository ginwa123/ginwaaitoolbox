const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;

/// GET /health
pub fn healthHandler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    _ = req;
    res.content_type = .JSON;
    const ts = std.Io.Clock.now(.real, self.io);
    const timestamp: i64 = ts.toSeconds();
    res.body = try std.fmt.allocPrint(res.arena, "{{\"status\":\"ok\",\"timestamp\":{}}}", .{timestamp});
}

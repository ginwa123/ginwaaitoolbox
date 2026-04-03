const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;
const HandlerArgs = @import("mod.zig").HandlerArgs;

/// Handle incoming command messages asynchronously
/// Messages are processed in a detached thread for non-blocking operation
pub fn commandHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    if (http_server.global_server) |server| {
        if (server.message_handler) |msg_handler| {
            const body = req.body() orelse "";

            const args = try server.allocator.create(HandlerArgs);
            args.* = .{
                .allocator = server.allocator,
                .body = try server.allocator.dupe(u8, body),
                .handler = msg_handler,
                .ctx = server.ctx,
            };

            const thread = try std.Thread.spawn(.{}, struct {
                fn run(a: *HandlerArgs) void {
                    defer a.allocator.destroy(a);
                    defer a.allocator.free(a.body);
                    var arena = std.heap.ArenaAllocator.init(a.allocator);
                    defer arena.deinit();
                    a.handler(arena.allocator(), a.body, a.ctx);
                }
            }.run, .{args});
            thread.detach();
        }
    }

    res.status = 200;
    res.body = "ok";
}

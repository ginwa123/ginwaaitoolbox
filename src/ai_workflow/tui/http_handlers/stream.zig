const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;

const httpz = http_server.httpz;
const SseStreamCtx = @import("mod.zig").SseStreamCtx;

fn sseStreamHandler(ctx: SseStreamCtx, stream: std.net.Stream) void {
    std.log.info("SSE stream handler started: session_id={s}", .{ctx.session_id});

    ctx.server.sse_manager.register(ctx.session_id, stream) catch {
        std.log.err("SSE: Failed to register stream for session: {s}", .{ctx.session_id});
        return;
    };

    const connected_data = std.fmt.allocPrint(ctx.server.allocator, "event: connected\n{{\"session_id\":\"{s}\"}}\n\n", .{ctx.session_id}) catch {
        std.log.err("SSE: Failed to format connected event", .{});
        ctx.server.sse_manager.remove(ctx.session_id);
        return;
    };
    defer ctx.server.allocator.free(connected_data);

    stream.writeAll(connected_data) catch |err| {
        std.log.err("SSE: Failed to write connected event: {s}", .{@errorName(err)});
        ctx.server.sse_manager.remove(ctx.session_id);
        return;
    };

    std.log.info("SSE: Connected event sent for session: {s}", .{ctx.session_id});

    while (ctx.server.sse_manager.hasSession(ctx.session_id)) {
        std.Thread.sleep(5_000_000_000); // 5 seconds

        stream.writeAll(": keepalive\n\n") catch |err| {
            std.log.warn("SSE keepalive failed for session {s}: {s}", .{ ctx.session_id, @errorName(err) });
            break;
        };

        var i: usize = 0;
        while (i < 300 and ctx.server.sse_manager.hasSession(ctx.session_id)) : (i += 1) {
            std.Thread.sleep(100_000_000);
        }
    }

    std.log.info("SSE stream handler ending: session_id={s}", .{ctx.session_id});
    ctx.server.sse_manager.remove(ctx.session_id);
    ctx.server.allocator.free(ctx.session_id);
}

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const session_id = req.param("session_id") orelse {
        res.status = 400;
        res.body = "Missing session_id";
        return;
    };

    if (http_server.global_server) |server| {
        std.log.info("SSE STREAM CONNECTED: session_id={s}", .{session_id});

        const session_id_copy = try server.allocator.dupe(u8, session_id);
        errdefer server.allocator.free(session_id_copy);

        const ctx = SseStreamCtx{
            .server = server,
            .session_id = session_id_copy,
        };

        try res.startEventStream(ctx, sseStreamHandler);
    } else {
        res.status = 500;
        res.body = "Server not available";
    }
}

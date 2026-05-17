const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;

const SseStreamCtx = @import("mod.zig").SseStreamCtx;

pub const CallbackAiStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const session_id = data.session_id;
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const server = di.server;

        std.debug.print("SSE_DEBUG: callback for session {s}\n", .{session_id});

        di.session_map_lock.lock(di.io) catch {};
        defer di.session_map_lock.unlock(di.io);
        const client_id = ai_mod.getClientIdForSession(session_id, false) orelse return;
        std.debug.print("GILANG_SERVER 2: client_id={s}\n", .{client_id});

        std.debug.print("SSE_DEBUG: got client_id {s}, sending event\n", .{client_id});
        const event_str = std.fmt.allocPrint(allocator, "data: {s}\n\n", .{data.data}) catch return;
        defer allocator.free(event_str);

        var buf: std.ArrayList(u8) = .empty;
        if (data.event_type) |event_type| {
            buf.appendSlice(allocator, "event: ") catch return;
            buf.appendSlice(allocator, event_type) catch return;
            buf.append(allocator, '\n') catch return;
        }

        if (data.data.len == 0) {
            buf.appendSlice(allocator, "data: \n") catch return;
        } else {
            var iter = std.mem.splitScalar(u8, data.data, '\n');
            while (iter.next()) |line| {
                buf.appendSlice(allocator, "data: ") catch return;
                buf.appendSlice(allocator, line) catch return;
                buf.append(allocator, '\n') catch return;
            }
        }
        buf.append(allocator, '\n') catch return;
        const dataaaa = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(dataaaa);

        server.sse_manager.sendToClient(client_id, dataaaa) catch {};
    }
};

/// SSE stream endpoint - establishes persistent connection for real-time events
pub fn streamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalar_core.getSingleton();
    const global_allocator = di.allocator;

    const session_id = req.params.get("session_id") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing session_id" }) });
    };

    // Register the client_id mapping (set by http_server after registerClient)
    if (ctx.client_id) |client_id| {
        const session_id_copy = try global_allocator.dupe(u8, session_id);
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient(session_id_copy, client_id_copy, true) catch {};
    }

    const event_bus = di.event_bus;

    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, session_id, CallbackAiStream.callback) catch {};

    return error.WouldBlock; // Handler should not complete - connection stays open
}

const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;

const SseStreamCtx = @import("mod.zig").SseStreamCtx;

/// Callback for session SSE events - broadcasts to client
pub const CallbackSessionsStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const server = di.server;

        std.debug.print("SSE_SESSIONS_DEBUG: callback for routing key {s}\n", .{data.session_id});

        // Get client_id for "sessions" routing
        const client_id = ai_mod.getClientIdForSession("sessions") orelse {
            std.debug.print("SSE_SESSIONS_DEBUG: no client registered for sessions\n", .{});
            return;
        };

        std.debug.print("SSE_SESSIONS_DEBUG: client_id={s}, sending event\n", .{client_id});

        // Format SSE message with data prefix and blank line
        const event_str = std.fmt.allocPrint(allocator, "data: {s}\n\n", .{data.data}) catch return;
        defer allocator.free(event_str);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        // Add event type if present
        if (data.event_type) |event_type| {
            buf.appendSlice(allocator, "event: ") catch return;
            buf.appendSlice(allocator, event_type) catch return;
            buf.append(allocator, '\n') catch return;
        }

        // Split data by newlines and prefix with "data: "
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

        std.debug.print("SSE_SESSIONS_DEBUG: sending to client, len={d}\n", .{dataaaa.len});
        server.sse_manager.sendToClient(client_id, dataaaa) catch {
            std.debug.print("SSE_SESSIONS_DEBUG: failed to send to client\n", .{});
        };
    }
};

/// SSE stream endpoint for session events - subscribes to "sessions" routing key
/// Clients connect here to receive session list updates (created, updated, deleted)
pub fn sessionsStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = req;
    _ = res;

    const di = try nalar_core.getSingleton();
    const event_bus = di.event_bus;

    // Register client mapping for "sessions" routing key
    if (ctx.client_id) |client_id| {
        std.debug.print("SSE_SESSIONS_DEBUG: registering client {s} for sessions\n", .{client_id});
        ai_mod.registerSessionClient("sessions", client_id) catch {
            std.debug.print("SSE_SESSIONS_DEBUG: failed to register client\n", .{});
        };
    }

    // Subscribe to session events with callback
    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, "sessions", CallbackSessionsStream.callback) catch {
        std.debug.print("SSE_SESSIONS_DEBUG: failed to subscribe\n", .{});
    };

    std.debug.print("SSE_SESSIONS_DEBUG: handler complete, connection stays open\n", .{});

    return error.WouldBlock; // Keep connection open
}

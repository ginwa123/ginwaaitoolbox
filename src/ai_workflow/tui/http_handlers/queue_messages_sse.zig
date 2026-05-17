const std = @import("std");
const http_response = @import("http_response.zig");
const nalar_core = @import("nalarcore");
const gserverz = nalar_core.gserverz;
const logger = nalar_core.logger;
const ai_mod = nalar_core.ai_mod;

const SseStreamCtx = @import("mod.zig").SseStreamCtx;

/// Callback for queue_messages SSE events - broadcasts to client
pub const CallbackQueueMessagesStream = struct {
    pub fn callback(data: ai_mod.on_event_sent.SseEvent) void {
        const di = nalar_core.getSingleton() catch return;
        const allocator = di.allocator;
        const server = di.server;

        std.debug.print("SSE_QUEUE_DEBUG: callback for session {s}\n", .{data.session_id});

        di.session_map_lock.lock(di.io) catch {};
        defer di.session_map_lock.unlock(di.io);

        const copy_key_for_event_bus = std.fmt.allocPrint(allocator, "queue_messages_{s}", .{data.session_id}) catch return;
        defer allocator.free(copy_key_for_event_bus);

        const client_id = ai_mod.getClientIdForSession(copy_key_for_event_bus, false) orelse {
            std.debug.print("SSE_QUEUE_DEBUG: no client registered for session {s}\n", .{data.session_id});
            return;
        };

        std.debug.print("SSE_QUEUE_DEBUG: client_id={s}, sending event\n", .{client_id});

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

        server.sse_manager.sendToClient(client_id, dataaaa) catch {
            std.debug.print("SSE_QUEUE_DEBUG: failed to send to client\n", .{});
        };
    }
};

/// SSE stream endpoint for queue_messages events
/// Clients connect here to receive real-time queue message notifications for a specific session
pub fn queueMessagesStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = res;
    const di = try nalar_core.getSingleton();
    const global_allocator = di.allocator;
    const event_bus = di.event_bus;

    const session_id = req.params.get("session_id") orelse {
        return error.WouldBlock;
    };

    const copy_key_for_event_bus = try std.fmt.allocPrint(global_allocator, "queue_messages_{s}", .{session_id});
    defer global_allocator.free(copy_key_for_event_bus);

    // Pass session_id directly — registerSessionClient dupes internally
    if (ctx.client_id) |client_id| {
        const copy_key_for_register = try global_allocator.dupe(u8, copy_key_for_event_bus);
        defer global_allocator.free(copy_key_for_register);
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient(copy_key_for_register, client_id_copy, true) catch {
            std.debug.print("SSE_QUEUE_DEBUG: failed to register client\n", .{});
        };
    } // subscribe dupes the key internally, so defer-free is correct here

    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, copy_key_for_event_bus, CallbackQueueMessagesStream.callback) catch {
        std.debug.print("SSE_QUEUE_DEBUG: failed to subscribe to session {s}\n", .{session_id});
    };

    return error.WouldBlock;
}

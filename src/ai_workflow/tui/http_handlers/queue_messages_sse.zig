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

        const copy_key_for_event_bus = std.fmt.allocPrint(allocator, "queue_messages_{s}", .{data.session_id}) catch return;
        defer allocator.free(copy_key_for_event_bus);

        // Get ALL client_ids for this queue_messages session, not just the first
        const maybe_clients = ai_mod.getListClientsForSession(copy_key_for_event_bus, allocator, false) catch return;
        const client_ids = maybe_clients orelse {
            std.debug.print("SSE_QUEUE_DEBUG: no clients registered for session {s}\n", .{data.session_id});
            return;
        };

        if (client_ids.len == 0) {
            std.debug.print("SSE_QUEUE_DEBUG: no client registered for session {s}\n", .{data.session_id});
            return;
        }

        std.debug.print("SSE_QUEUE_DEBUG: sending to {d} clients\n", .{client_ids.len});

        // Build SSE message once (reused for all clients)
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

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

        const sse_event_data = buf.toOwnedSlice(allocator) catch return;
        defer allocator.free(sse_event_data);

        // Send to ALL clients for this queue_messages session
        for (client_ids) |client_id| {
            server.sse_manager.sendToClient(client_id, sse_event_data) catch {
                std.debug.print("SSE_QUEUE_DEBUG: failed to send to client\n", .{});
            };
        }
    }
};

/// SSE stream endpoint for queue_messages events
/// Clients connect here to receive real-time queue message notifications for a specific session
pub fn queueMessagesStreamHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    _ = res;
    const di = try nalar_core.getSingleton();
    const global_allocator = di.allocator;
    const server = di.server;
    const event_bus = di.event_bus;

    const session_id = req.params.get("session_id") orelse {
        return error.WouldBlock;
    };

    const copy_key_for_event_bus = try std.fmt.allocPrint(global_allocator, "queue_messages_{s}", .{session_id});
    defer global_allocator.free(copy_key_for_event_bus);

    // Pass session_id directly — registerSessionClient dupes internally
    if (ctx.client_id) |client_id| {
        const copy_key_for_register = try global_allocator.dupe(u8, copy_key_for_event_bus);
        const client_id_copy: [16]u8 = client_id;
        ai_mod.registerSessionClient(copy_key_for_register, client_id_copy, true) catch {
            std.debug.print("SSE_QUEUE_DEBUG: failed to register client\n", .{});
        };

        // Send "connected" event so the SseClient transitions out of
        // 'connecting'. Mirrors worker_sse.zig and sessions_sse.zig.
        // Without this handshake, the frontend SseStatusBadge stays
        // stuck on "Connecting…" even though the stream is live.
        const connected_event = "event: connected\ndata: {\"connected\": true}\n\n";
        server.sse_manager.sendToClient(client_id_copy, connected_event) catch {};
    } // subscribe dupes the key internally, so defer-free is correct here

    event_bus.subscribe(ai_mod.on_event_sent.SseEvent, copy_key_for_event_bus, CallbackQueueMessagesStream.callback) catch {
        std.debug.print("SSE_QUEUE_DEBUG: failed to subscribe to session {s}\n", .{session_id});
    };

    return error.WouldBlock;
}

const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;
const event_bus_mod = nalarcore.event_bus;
const SseEvent = mod.SseEvent;

pub const DeleteQueueMessagesInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    is_emit_sse: bool,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    message: []const u8,
};

/// Delete a specific queued message and emit SSE event
pub fn deleteQueuedMessage(
    obj: DeleteQueueMessagesInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const event_bus = obj.event_bus;

    const session_id = obj.session_id;
    const message = obj.message;
    const is_emit_sse = obj.is_emit_sse;

    const sql = "DELETE FROM session_queue_messages WHERE session_id = ? AND message = ? ";
    try db.exec(allocator, sql, &.{ session_id, message });

    if (is_emit_sse) {
        if (event_bus) |ev| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            const payload = .{
                .action = "deleted",
                .message = message,
                .session_id = session_id,
            };
            try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
                .whitespace = .indent_4,
            })});

            const data_copy = try allocator.dupe(u8, buf.items);
            const event = SseEvent{
                .session_id = session_id,
                .data = data_copy,
                .event_type = "queue_deleted",
            };

            // Per-session emit (kept for any future server-side fan-out that
            // needs only this session's queue messages).
            const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
            defer allocator.free(key);
            ev.emit(SseEvent, key, event);
            // Central broadcast: subscribers to bare "queue" receive ALL sessions'
            // queue messages (including deletes). The frontend listener filter
            // narrows to the current session_id on the JS side.
            ev.emit(SseEvent, "queue", event);
        }
    }
}

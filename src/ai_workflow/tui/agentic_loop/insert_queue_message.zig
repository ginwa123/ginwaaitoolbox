const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const event_bus_mod = nalarcore.event_bus;
const on_event_sent = @import("../mod.zig").on_event_sent;

pub const InsertQueueMessageInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    session_id: []const u8,
    message: []const u8,
    image_url: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
};

/// Queue a message for a session and emit SSE event to notify connected clients
pub fn insertQueueMessage(
    obj: InsertQueueMessageInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const event_bus = obj.event_bus;

    const session_id = obj.session_id;
    const message = obj.message;
    const image_url = obj.image_url;
    const is_emit_sse = obj.is_emit_sse;

    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(std.Options.debug_io, .real).nanoseconds});
    defer allocator.free(id);

    const sql = "INSERT INTO session_queue_messages (id, session_id, message, image_url) VALUES (?, ?, ?, ?)";
    const copy_image_url = try allocator.dupe(u8, image_url);
    defer allocator.free(copy_image_url);

    try db.exec(allocator, sql, &.{ id, session_id, message, copy_image_url });

    // Emit SSE event to notify connected clients
    if (is_emit_sse) {
        if (event_bus) |ev| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            const payload = .{
                .action = "queued",
                .id = id,
                .message = message,
                .session_id = session_id,
                .image_url = image_url,
            };
            try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{
                .whitespace = .indent_4,
            })});

            const data_copy = try allocator.dupe(u8, buf.items);
            const event = on_event_sent.SseEvent{
                .session_id = session_id,
                .data = data_copy,
                .event_type = "queue_queued",
            };

            // Per-session emit (kept for any future server-side fan-out that
            // needs only this session's queue messages).
            const key = try std.fmt.allocPrint(allocator, "queue_messages_{s}", .{session_id});
            defer allocator.free(key);
            ev.emit(on_event_sent.SseEvent, key, event);
            // Central broadcast: subscribers to bare "queue" receive ALL sessions'
            // queue messages. The frontend listener filter narrows to the current
            // session_id on the JS side.
            ev.emit(on_event_sent.SseEvent, "queue", event);
        }
    }
}

const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const event_bus_mod = nalarcore.event_bus;
const onEventSendWorkers = mod.onEventSendWorkers;

pub const DeleteWorkerInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    session_id: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
};

pub fn deleteWorker(
    obj: DeleteWorkerInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;
    const is_emit_sse = obj.is_emit_sse;
    const event_bus = obj.event_bus;
    const logger = obj.logger;

    const sql = "DELETE FROM worker WHERE id = ?";
    try db.exec(allocator, sql, &.{session_id});

    if (is_emit_sse) {
        if (event_bus) |ev| {
            // Emit worker deleted event so connected SSE clients can drop the entry
            onEventSendWorkers(allocator, .{
                .action = "deleted",
                .id = session_id,
                .session_id = "",
                .working_directory = "",
                .last_activity = 0,
                .last_activity_description = "",
                .created_at = "",
                .event_bus = ev,
            }) catch |err| {
                logger.?.errFmt("[DELETE WORKER] Failed to send worker event: {s}\n", .{@errorName(err)});
            };
        }
    }
}

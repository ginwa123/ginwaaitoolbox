const std = @import("std");
const mod = @import("mod.zig");
const nalarcore =  mod.nalarcore;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const helpers = nalarcore.helpers;
const onEventSendWorkers = mod.onEventSendWorkers;
const event_bus_mod = nalarcore.event_bus;


pub const UpsertWorkerInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    worker_id: []const u8,
    session_id: []const u8,
    working_directory: []const u8,
    event_bus: ?*event_bus_mod.EventBus,
    is_emit_sse: bool,
};

/// Register or update a worker
pub fn upsertWorker(obj: UpsertWorkerInput) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const logger = obj.logger;

    const worker_id = obj.worker_id;
    const session_id = obj.session_id;
    const working_directory = obj.working_directory;
    const is_emit_sse = obj.is_emit_sse;
    const event_bus = obj.event_bus;

    // Check if the worker already exists so we can emit the correct SSE action.
    const check_sql =
        \\SELECT 1
        \\FROM worker
        \\WHERE id = ?
        \\LIMIT 1;
    ;

    var rows = try db.query(allocator, check_sql, &.{worker_id});
    defer rows.deinit();

    const exists = (try rows.next()) != null;

    // Insert or update the worker.
    const worker_sql =
        \\INSERT INTO worker (
        \\    id,
        \\    session_id,
        \\    working_directory,
        \\    last_activity,
        \\    last_activity_description
        \\)
        \\VALUES (
        \\    ?,
        \\    ?,
        \\    ?,
        \\    strftime('%s', 'now'),
        \\    ''
        \\)
        \\ON CONFLICT(id) DO UPDATE SET
        \\    session_id = excluded.session_id,
        \\    working_directory = excluded.working_directory,
        \\    last_activity = excluded.last_activity,
        \\    last_activity_description = excluded.last_activity_description;
    ;

    try db.exec(
        allocator,
        worker_sql,
        &.{
            worker_id,
            session_id,
            working_directory,
        },
    );

    // Ensure the session exists.
    const session_sql =
        \\INSERT INTO sessions (
        \\    id,
        \\    name,
        \\    status,
        \\    created_at,
        \\    updated_at
        \\)
        \\VALUES (
        \\    ?,
        \\    ?,
        \\    'active',
        \\    CURRENT_TIMESTAMP,
        \\    CURRENT_TIMESTAMP
        \\)
        \\ON CONFLICT(id) DO UPDATE SET
        \\    name = excluded.name,
        \\    status = excluded.status,
        \\    updated_at = CURRENT_TIMESTAMP;
    ;

    try db.exec(
        allocator,
        session_sql,
        &.{
            session_id,
            session_id,
        },
    );

    // update workspace_item_tasks if exists
    try db.exec(allocator, "UPDATE workspace_item_tasks SET updated_at = datetime('now') WHERE id = ?", &.{session_id});

    if (!is_emit_sse) return;

    if (event_bus == null) return;

    const action = if (exists) "updated" else "created";
    const now_timestamp: i64 = helpers.unixTimestamp();

    onEventSendWorkers(allocator, .{
        .action = action,
        .id = worker_id,
        .session_id = session_id,
        .working_directory = working_directory,
        .last_activity = now_timestamp,
        .last_activity_description = "",
        .created_at = "",
        .event_bus = event_bus.?,
    }) catch |err| {
        if (logger) |log| {
            log.errFmt(
                "[upsertWorker] Failed to send worker event: {s}\n",
                .{@errorName(err)},
            );
        }
    };
}

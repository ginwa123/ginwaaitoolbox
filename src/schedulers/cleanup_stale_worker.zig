const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const delete_worker_mod = @import("../ai_workflow/tui/agentic_loop/delete_worker.zig");
const ActiveLoops = @import("../ai_workflow/tui/agentic_loop/ActiveLoops.zig").ActiveLoops;
const event_bus_mod = nalarcore.event_bus;
const logger_mod = nalarcore.loggermod;

/// How old `worker.last_activity_nano` must be (in seconds) before the
/// cleanup tick considers the row stale. 10 minutes per the user spec.
pub const stale_threshold_seconds: i64 = 600;

pub const CleanupStaleWorkerInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
    active_loops: *ActiveLoops,
    now_unix: i64,
    threshold_seconds: i64 = stale_threshold_seconds,
};

pub const CleanupResult = struct {
    stale_count: usize = 0,
    deleted_count: usize = 0,
    removed_loop_count: usize = 0,
};

/// Delete every worker row whose `last_activity_nano` is older than
/// `now_unix - threshold_seconds` (or NULL), and clear any matching
/// `ActiveLoops` entry first. Reuses `deleteWorker` so the SSE
/// `action="deleted"` event fires and the UI updates.
///
/// Per-row isolation: if one row's `deleteWorker` fails, log via
/// `logger.?errFmt` and continue to the next row — the cron tick
/// must NOT abort the whole batch on a single bad row.
pub fn cleanupStaleWorkers(input: CleanupStaleWorkerInput) anyerror!CleanupResult {
    const allocator = input.allocator;
    const db = input.db;
    const io = input.io;
    const event_bus = input.event_bus;
    const active_loops = input.active_loops;
    const logger = input.logger;

    var result = CleanupResult{};
    const cutoff = input.now_unix - input.threshold_seconds;
    const cutoff_str = try std.fmt.allocPrint(allocator, "{d}", .{cutoff});
    defer allocator.free(cutoff_str);

    const sql =
        \\SELECT id, session_id
        \\FROM worker
        \\WHERE last_activity_nano IS NULL OR last_activity_nano < ?
    ;

    var rows = try db.query(allocator, sql, &.{cutoff_str});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);

        const id = row.values[0];
        const session_id = row.values[1];
        result.stale_count += 1;

        // Always try to clear the matching ActiveLoops entry first
        // (idempotent — no-op if absent). Covers the "stale in DB
        // AND in memory" case (a `kill -9` left both, and the
        // active_loops.remove prevents the user from being told
        // "session is busy" forever).
        const had_loop = active_loops.contains(io, session_id);
        active_loops.remove(io, session_id);
        if (had_loop) result.removed_loop_count += 1;

        // Delete the worker row + emit the SSE `action="deleted"`
        // event. `deleteWorker` uses `id` as the primary key, which
        // matches the worker.id column (== session_id in practice
        // — see update_worker.zig:503).
        delete_worker_mod.deleteWorker(.{
            .allocator = allocator,
            .db = db,
            .logger = logger,
            .session_id = id,
            .event_bus = event_bus,
            .is_emit_sse = true,
        }) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_worker] deleteWorker failed for session_id={s}: {s}\n",
                    .{ id, @errorName(err) },
                );
            }
            continue;
        };

        result.deleted_count += 1;
    }

    return result;
}

/// Cron callback. Signature is fixed by
/// `cronjob_manager.register` (`src/modules/custom_http_server/src/cronjob_manager.zig:87`):
/// `*const fn (ctx: ?*anyopaque, now_unix: i64) void`.
///
/// Returns `void` (not `!void`) — DB errors are caught and logged
/// inside, never propagated. The cron thread MUST NOT panic.
pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;

    const di = nalarcore.getSingleton() catch return;
    const allocator = di.allocator;
    const logger = di.logger;

    // Per-tick arena — all SQL allocations live for the duration of
    // the cleanupStaleWorkers call. Cheaper than per-row alloc/free.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = cleanupStaleWorkers(.{
        .allocator = a,
        .io = di.io,
        .db = di.db,
        .logger = logger,
        .event_bus = di.event_bus,
        .active_loops = di.active_loops,
        .now_unix = now_unix,
    }) catch |err| {
        logger.errFmt("[cleanup_stale_worker] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    logger.infoFmt(
        "[cleanup_stale_worker] tick summary: stale={d} deleted={d} removed_loops={d}",
        .{ result.stale_count, result.deleted_count, result.removed_loop_count },
    );
}
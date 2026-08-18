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
    _ = input;
    return error.NotImplemented;
}

/// Cron callback. Signature is fixed by
/// `cronjob_manager.register` (`src/modules/custom_http_server/src/cronjob_manager.zig:87`):
/// `*const fn (ctx: ?*anyopaque, now_unix: i64) void`.
///
/// Returns `void` (not `!void`) — DB errors are caught and logged
/// inside, never propagated. The cron thread MUST NOT panic.
pub fn handle(ctx: ?*anyopaque, now_unix: i64) void {
    _ = ctx;
    std.debug.print("[cronjob] heartbeat fired at now={d}\n", .{now_unix});
}

// Suppress unused-import warnings on the stub; removed when the
// implementation lands.
comptime {
    _ = delete_worker_mod;
}
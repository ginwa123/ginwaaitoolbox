const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const logger_mod = nalarcore.loggermod;
const sqlite = nalarcore.sqlite;
const isWorkerCancelled = mod.isWorkerCancelled;
const IsWorkerCancelledInput = mod.IsWorkerCancelledInput;

const WorkflowNanoSleepTimespec = extern struct {
    sec: c_long,
    nsec: c_long,
};
extern "c" fn nanosleep(req: *const WorkflowNanoSleepTimespec, rem: ?*WorkflowNanoSleepTimespec) c_int;

pub const RetryDelayMsInput = struct {
    allocator: std.mem.Allocator,
    delay_ms: u32,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    io: std.Io,
    logger: *logger_mod.Logger,
};

pub fn retryDelayMs(
    obj: RetryDelayMsInput,
) bool {
    const allocator = obj.allocator;
    const delay_ms = obj.delay_ms;
    const db = obj.db;
    const session_id = obj.session_id;
    const io = obj.io;
    const logger = obj.logger;

    if (delay_ms == 0) return true;

    const deadline_ns: i96 = std.Io.Clock.now(.real, io).nanoseconds +
        @as(i96, @intCast(delay_ms)) * std.time.ns_per_ms;

    while (true) {
        // Cancellation check — same shape as the loop-top check at
        // workflow.zig:276 so the cancel UX is consistent.
        if (isWorkerCancelled(IsWorkerCancelledInput{
            .allocator = allocator,
            .db = db,
            .session_id = session_id,
        })) {
            const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
            const remaining_ns: i96 = @max(deadline_ns - now_ns, 0);
            const remaining_ms: u32 = @intCast(@divFloor(remaining_ns, std.time.ns_per_ms));
            logger.infoFmt(
                "Retry delay interrupted by worker cancellation: session_id={s} remaining={d}ms",
                .{ session_id, remaining_ms },
            );
            return false;
        }
        if (std.Io.Clock.now(.real, io).nanoseconds >= deadline_ns) return true;

        const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
        const remaining_ms: u32 = @intCast(@divFloor(
            deadline_ns - now_ns,
            std.time.ns_per_ms,
        ));
        const chunk_ms: u32 = if (remaining_ms > 50) 50 else remaining_ms;

        const ts = WorkflowNanoSleepTimespec{
            .sec = 0,
            .nsec = chunk_ms * std.time.ns_per_ms,
        };
        _ = nanosleep(&ts, null);
    }
}

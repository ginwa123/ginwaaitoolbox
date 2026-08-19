const std = @import("std");
const nalarcore = @import("nalarcore");
const isWorkerCancelled = @import("is_worker_cancelled.zig").isWorkerCancelled;

const logger_mod = nalarcore.loggermod;
const sqlite = nalarcore.sqlite;
const IsWorkerCancelledInput = @import("is_worker_cancelled.zig").IsWorkerCancelledInput;

// Portable sleep helper. We can't use std.c.timespec directly because
// it's broken on Windows in Zig 0.16 (see test_sleep.zig for the
// upstream analysis). We define our own nanosleep-equivalent here
// using `c_long` (Linux/macOS c_long = i64, Windows c_long = i32 —
// both fit `chunk_ms * std.time.ns_per_ms` for any sane chunk_ms
// value, since chunk_ms is bounded at 50 in the call below).
//
// Why c_long and not std.c.timespec.sec/nsec directly? Because
// std.c.timespec is the upstream-broken type — the struct literal
// `.{ .sec = X, .nsec = Y }` won't compile on Windows. Defining a
// custom extern struct here keeps the test portable.
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
        const remaining_ns: i96 = @max(deadline_ns - now_ns, 0);
        const remaining_ms: u32 = @intCast(@divFloor(
            remaining_ns,
            std.time.ns_per_ms,
        ));
        const chunk_ms: u32 = if (remaining_ms > 50) 50 else remaining_ms;

        const ts = WorkflowNanoSleepTimespec{
            .sec = 0,
            // Explicit c_long cast — `chunk_ms * std.time.ns_per_ms`
            // produces a `u32` (chunk_ms's type) which the linker
            // can't coerce to c_long on Windows (where c_long=i32).
            // Cast through c_long so the struct literal type-checks
            // on every POSIX. Runtime values: 50ms * 1M ns/ms = 50M ns
            // — fits i32 comfortably.
            .nsec = @as(c_long, @intCast(chunk_ms * std.time.ns_per_ms)),
        };
        _ = nanosleep(&ts, null);
    }
}

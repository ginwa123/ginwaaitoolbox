const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const nalarcore = @import("nalarcore");
const isWorkerCancelled = @import("is_worker_cancelled.zig").isWorkerCancelled;

const logger_mod = nalarcore.loggermod;
const sqlite = nalarcore.sqlite;
const IsWorkerCancelledInput = @import("is_worker_cancelled.zig").IsWorkerCancelledInput;

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
            .nsec = chunk_ms * std.time.ns_per_ms,
        };
        _ = nanosleep(&ts, null);
    }
}

fn setupDb() !struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
} {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc, "CREATE TABLE workers (id TEXT PRIMARY KEY)", &.{});
    return .{ .db = db, .threaded = threaded };
}

fn teardownDb(s: *@TypeOf(setupDb() catch unreachable)) void {
    s.db.deinit();
    s.threaded.deinit();
}

test "retryDelayMs does not panic over 200 calls with delay_ms = 1 (race-window stress)" {
    if (builtin.mode != .Debug) return error.SkipZigTest;

    var s = try setupDb();
    defer teardownDb(&s);
    const alloc = testing.allocator;

    var lg = logger_mod.Logger.init(alloc, std.testing.io, .{});
    defer lg.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const result = retryDelayMs(.{
            .allocator = alloc,
            .delay_ms = 1,
            .db = &s.db,
            .session_id = "race_test_session",
            .io = s.threaded.io(),
            .logger = &lg,
        });
        try testing.expect(result == true);
    }
}

//! Immediate background-command completion watcher.
//!
//! A `command background=true` completion is otherwise only noticed by the
//! per-minute `cleanup_stale_background_process` cron (notify-then-delete +
//! wake). This module schedules a fire-and-forget Io-task watcher at exec
//! time on `di.group_bg_watchers` that polls `isProcessRunning(pid)` every
//! 2s and inserts the queue message the moment the command exits — no cron
//! wait. The group is process-lifetime and never awaited or cancelled
//! (same as `group_emit_session_create`).
//!
//! True event-driven wait is impossible: the bg PID is a grandchild
//! (`nohup cmd &` inside a shell that exits — not our child, no waitpid).
//! A shell-wrapper+HTTP-callback alternative is rejected (new endpoint +
//! auth surface). Polling is the only option; the cron remains as fallback
//! (cap expiry, spawn failure, crash between save and spawn).
//!
//! Concurrency: the cron already uses `di.db` + `emit_run_agent`
//! concurrently with request handlers, so watcher-task DB/emit use is the
//! same class. The task never panics — every failure is caught and logged.
//!
//! Ownership (per-request arena rule): the spawn call dupes
//! session_id/command/log_path/pid_str with `di.allocator` (process
//! lifetime — NEVER the request ctx allocator). The Io task frees them on
//! exit. Notify buffers live in a per-watch arena.

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const event_bus_mod = nalarcore.event_bus;
const bg_proc = nalarcore.ai_mod.background_process;
const cleanup = nalarcore.cleanup_stale_background_process;
// NOTE: do NOT use `bg_proc.isProcessRunning` — `background_process.zig`
// resolves it via `root_mod.helpers.process_status`, but root dropped the
// `helpers` re-export (root.zig:637), so that decl no longer compiles when
// referenced. Use the supported `@import("helpers")` route directly (same
// as cleanup_stale_background_process.zig).
const process_status = @import("helpers").process_status;
const migration = @import("../../../migrations/migration.zig");
const testing = std.testing;

/// Poll interval between `isProcessRunning` checks (production).
pub const watcher_poll_interval_ns: u64 = 2 * std.time.ns_per_s;
/// Cap on poll iterations (~24h at the default 2s interval). On expiry the
/// task exits silently — the cron is the fallback.
pub const watcher_max_iters: usize = 43200;

/// Testable core args — explicit handles (no singleton) so unit tests stay
/// hermetic (own :memory: DB, event_bus=null).
pub const WatchCoreArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
    session_id: []const u8,
    pid_num: u32,
    pid_str: []const u8,
    command: []const u8,
    log_path: []const u8,
    poll_interval_ns: u64 = watcher_poll_interval_ns,
    max_iters: usize = watcher_max_iters,
};

/// Poll until the PID dies (or the cap hits), then notify + delete.
/// Returns true iff notified AND the row was deleted (caller wakes).
/// Never panics — notify/delete failures are caught, logged, return false
/// (cron fallback retries next tick).
pub fn watchAndNotify(args: WatchCoreArgs) bool {
    const pid_i32: i32 = @as(i32, @intCast(args.pid_num));
    var i: usize = 0;
    while (i < args.max_iters) : (i += 1) {
        if (!process_status.isProcessRunning(pid_i32)) break;
        std.Io.sleep(args.io, .{ .nanoseconds = args.poll_interval_ns }, .real) catch {};
    }
    // Cap hit with the process still alive — exit silently, cron covers it.
    if (process_status.isProcessRunning(pid_i32)) return false;

    // Per-call arena for the notify buffers (same as the cron pass-1.5:
    // insertQueueMessage binds synchronously, so arena lifetime covering
    // the call is enough; the arena frees log_content + message in one
    // shot so DebugAllocator tests don't leak).
    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const notified = cleanup.notifySingleBackgroundCompletion(.{
        .allocator = a,
        .io = args.io,
        .db = args.db,
        .logger = args.logger,
        .event_bus = args.event_bus,
        .session_id = args.session_id,
        .pid_num = args.pid_num,
        .pid_str = args.pid_str,
        .command = args.command,
        .log_path = args.log_path,
    });
    if (!notified) return false;

    bg_proc.delete(args.db, a, args.session_id, args.pid_num) catch |err| {
        if (args.logger) |log| {
            log.errFmt(
                "[background_watcher] delete failed for session {s} pid {s}: {s} — cron fallback retries\n",
                .{ args.session_id, args.pid_str, @errorName(err) },
            );
        }
        return false;
    };
    return true;
}

/// Io-task-owned args — every slice is heap-duped with `di.allocator` at
/// schedule time and freed by the task on exit.
const WatchArgs = struct {
    di: *nalarcore.ContextIPCTui,
    session_id: []u8,
    pid: u32,
    pid_str: []u8,
    command: []u8,
    log_path: []u8,
    poll_interval_ns: u64,
    max_iters: usize,
};

/// Io-task entry — owns the dupes, frees them on exit. Never panics.
/// Top-level `fn(args: WatchArgs) void` so `group.concurrent` can schedule
/// it (single-struct tuple is passed through as the one param).
fn watchFn(args: WatchArgs) void {
    const di = args.di;
    const gpa = di.allocator;
    defer gpa.free(args.session_id);
    defer gpa.free(args.pid_str);
    defer gpa.free(args.command);
    defer gpa.free(args.log_path);

    // Per-watch arena for the notify buffers (insertQueueMessage binds
    // synchronously, so arena lifetime covering the call is enough).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const done = watchAndNotify(.{
        .allocator = a,
        .io = di.io,
        .db = di.db,
        .logger = di.logger,
        .event_bus = di.event_bus,
        .session_id = args.session_id,
        .pid_num = args.pid,
        .pid_str = args.pid_str,
        .command = args.command,
        .log_path = args.log_path,
        .poll_interval_ns = args.poll_interval_ns,
        .max_iters = args.max_iters,
    });
    if (!done) return;
    cleanup.wakeSessionForCompletion(di, a, args.session_id);
}

/// Schedule the fire-and-forget watcher task. Returns void — every failure
/// (dupe OOM, concurrent() error such as error.ConcurrencyUnavailable on a
/// bare blocking Io) is silent (cron fallback covers production; unit tests
/// cover the watcher core directly via `watchAndNotify`).
/// Must be called AFTER `background_process.save` succeeds, with the
/// borrowed slices still alive (they are duped synchronously here).
pub fn spawnCompletionWatcher(
    di: *nalarcore.ContextIPCTui,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
) void {
    spawnCompletionWatcherWithPoll(di, session_id, pid, command, log_path, watcher_poll_interval_ns, watcher_max_iters);
}

/// Schedule with an explicit poll interval / cap (test hook; production passes
/// the defaults via `spawnCompletionWatcher`).
pub fn spawnCompletionWatcherWithPoll(
    di: *nalarcore.ContextIPCTui,
    session_id: []const u8,
    pid: u32,
    command: []const u8,
    log_path: []const u8,
    poll_interval_ns: u64,
    max_iters: usize,
) void {
    const gpa = di.allocator;
    const sid = gpa.dupe(u8, session_id) catch return;
    errdefer gpa.free(sid);
    const cmd = gpa.dupe(u8, command) catch return;
    errdefer gpa.free(cmd);
    const lp = gpa.dupe(u8, log_path) catch return;
    errdefer gpa.free(lp);
    const pid_str = std.fmt.allocPrint(gpa, "{d}", .{pid}) catch return;
    errdefer gpa.free(pid_str);

    const args = WatchArgs{
        .di = di,
        .session_id = sid,
        .pid = pid,
        .pid_str = pid_str,
        .command = cmd,
        .log_path = lp,
        .poll_interval_ns = poll_interval_ns,
        .max_iters = max_iters,
    };
    // Fire-and-forget on the process-lifetime group (same as
    // `group_emit_session_create` — never awaited or cancelled). On
    // concurrent() error (notably error.ConcurrencyUnavailable on a bare
    // blocking Io, same as tools_exec_spawn_sub_agent.zig) free the dupes
    // here (the task never started, so it cannot free them); on success
    // the task owns them.
    di.group_bg_watchers.concurrent(di.io, watchFn, .{args}) catch {
        gpa.free(sid);
        gpa.free(cmd);
        gpa.free(lp);
        gpa.free(pid_str);
        return;
    };
}

// ─── Tests (inline, project convention) ──────────────────────────────────────

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,

    fn deinit(self: *TestCtx) void {
        self.db.deinit();
        self.threaded.deinit();
    }
};

fn setupCtx() !TestCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{
        .db = db,
        .threaded = threaded,
    };
}

test "watchAndNotify notifies a dead PID immediately then deletes the row" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bg.log", .data = "watcher saw exit" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const log_path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "bg.log" });
    defer testing.allocator.free(log_path);

    // 999_999_999 is virtually guaranteed to NOT exist — the first
    // isProcessRunning check breaks immediately, no sleep.
    const dead_pid: u32 = 999_999_999;
    try bg_proc.save(&ctx.db, testing.allocator, "s_watch", dead_pid, "sleep 30", log_path, 1);

    const done = watchAndNotify(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .session_id = "s_watch",
        .pid_num = dead_pid,
        .pid_str = "999999999",
        .command = "sleep 30",
        .log_path = log_path,
        .poll_interval_ns = 10 * std.time.ns_per_ms,
        .max_iters = 500,
    });
    try testing.expect(done);

    // Queue envelope present.
    var q = try ctx.db.query(testing.allocator, "SELECT message FROM session_queue_messages WHERE session_id = ?", &.{"s_watch"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(testing.allocator);
    const msg = row.values[0];
    try testing.expect(std.mem.indexOf(u8, msg, "<background_command>") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "<pid>999999999</pid>") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "<command>sleep 30</command>") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "watcher saw exit") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "\"\"\"\"\"") == null);

    // Bg row deleted.
    var r = try ctx.db.query(testing.allocator, "SELECT 1 FROM session_background_process WHERE session_id = ?", &.{"s_watch"});
    defer r.deinit();
    try testing.expect((try r.next()) == null);
}

test "background_watcher schedules via Io group, never std.Thread.spawn (static-contract grep)" {
    // The watcher must stay on the repo's fire-and-forget async pattern
    // (`di.group_bg_watchers.concurrent`, same as `group_emit_session_create`
    // — never awaited or cancelled). If a future refactor reintroduces
    // `std.Thread.spawn` here, this test fails closed with an actionable
    // error. Precedent: command.zig cmd-fallback static-contract test.
    const src = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "src/ai_workflow/tui/agentic_loop/background_watcher.zig",
        testing.allocator,
        std.Io.Limit.unlimited,
    );
    defer testing.allocator.free(src);

    // Window the scan to the implementation above this test: this test's
    // own source contains the forbidden literals (in the indexOf calls +
    // error strings below), so an unwindowed scan would self-match and
    // fail forever. Cut at this test's opening line.
    const marker = "test \"background_watcher schedules via Io group";
    const cut = std.mem.indexOf(u8, src, marker) orelse src.len;
    const impl = src[0..cut];

    if (std.mem.indexOf(u8, impl, "std.Thread.spawn") != null) {
        std.debug.print(
            "\n!! background_watcher.zig reintroduced std.Thread.spawn — use di.group_bg_watchers.concurrent instead !!\n",
            .{},
        );
        return error.RawThreadReintroduced;
    }
    if (std.mem.indexOf(u8, impl, "WatchThreadArgs") != null) {
        std.debug.print(
            "\n!! background_watcher.zig still has WatchThreadArgs — renamed to WatchArgs !!\n",
            .{},
        );
        return error.StaleThreadArgsName;
    }
    try testing.expect(std.mem.indexOf(u8, impl, "group_bg_watchers.concurrent") != null);
}

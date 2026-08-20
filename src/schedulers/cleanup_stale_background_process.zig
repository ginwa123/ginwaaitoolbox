//! Cronjob — delete stale rows from `session_background_process` whose PID
//! is no longer alive.
//!
//! Per the user spec, the only criterion for "stale" is "is the process
//! actually running?". The `status` column is deliberately ignored — it
//! can be stale (e.g. a `kill -9` left the row at `status='running'`
//! because the defer that updates it never ran), and a process can be
//! alive while the row says otherwise. The cross-platform
//! `helpers.process_status.isProcessRunning(pid)` helper is the source
//! of truth.
//!
//! Architecture: pure helper `cleanupStaleBackgroundProcesses(input) !CleanupResult`
//! does the work; thin `handle(ctx, now_unix) void` wrapper pulls
//! `*ContextIPCTui` from the singleton and calls the helper. Per row:
//! parse (session_id, pid), call `isProcessRunning`, keep if alive,
//! DELETE otherwise.
//!
//! Cron registration is in `src/main.zig` right after the
//! `cleanup_stale_worker` registration, fired every minute on the minute.
//!
//! Schema (mirrors migration 014 — `src/migrations/migration.zig:218`):
//! ```sql
//! CREATE TABLE session_background_process (
//!     session_id TEXT NOT NULL,
//!     pid INTEGER NOT NULL,
//!     command TEXT NOT NULL,
//!     log_path TEXT NOT NULL,
//!     started_at INTEGER NOT NULL,
//!     status TEXT NOT NULL DEFAULT 'running',
//!     PRIMARY KEY (session_id, pid)
//! )
//! ```
//!
//! The DELETE must use BOTH (session_id, pid) because the PRIMARY KEY
//! is composite.

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const process_status = nalarcore.helpers.process_status;
const logger_mod = nalarcore.loggermod;
const testing = std.testing;

pub const CleanupStaleBackgroundProcessInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
};

pub const CleanupResult = struct {
    checked_count: usize = 0,
    kept_count: usize = 0,
    deleted_count: usize = 0,
};

// ─── Production helper ────────────────────────────────────────────────────
//
// Iterate every row in `session_background_process`. For each row,
// check the actual OS process via `helpers.process_status.isProcessRunning`.
// If alive → keep. If dead → DELETE the row. The `status` column is
// deliberately IGNORED — it can drift from reality (a `kill -9` leaves
// it at `'running'` because the defer that updates it never ran; or a
// process can be alive while the row says otherwise).
//
// Per-row isolation: if one row's DELETE fails, log via
// `logger.?errFmt` and continue to the next row. The cron tick must
// NOT abort the whole batch on a single bad row.

pub fn cleanupStaleBackgroundProcesses(input: CleanupStaleBackgroundProcessInput) anyerror!CleanupResult {
    const allocator = input.allocator;
    const db = input.db;
    const logger = input.logger;

    var result = CleanupResult{};

    // Select the composite PK columns so we can use them in the
    // DELETE WHERE clause. The `status` column is intentionally NOT
    // selected — it has no bearing on the keep/delete decision.
    const select_sql =
        \\SELECT session_id, pid
        \\FROM session_background_process
    ;

    var rows = try db.query(allocator, select_sql, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(allocator);

        if (row.values.len < 2) continue;
        const session_id = row.values[0];
        const pid_str = row.values[1];

        result.checked_count += 1;

        // Defensive: skip rows with malformed PIDs rather than panic.
        // A row with a non-numeric PID is unrecoverable corruption.
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch continue;

        // The single source of truth: is the process actually alive?
        // Cross-platform — uses kill(pid, 0) on POSIX, OpenProcess
        // with QUERY_LIMITED on Windows.
        if (process_status.isProcessRunning(pid)) {
            result.kept_count += 1;
            continue;
        }

        // Process is dead — DELETE the row. Composite PK means we
        // MUST match both session_id AND pid (the same PID can exist
        // under multiple sessions; deleting only by pid would
        // clobber unrelated rows).
        const delete_sql =
            \\DELETE FROM session_background_process
            \\WHERE session_id = ? AND pid = ?
        ;
        db.exec(allocator, delete_sql, &.{ session_id, pid_str }) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] DELETE failed for session_id={s} pid={s}: {s}\n",
                    .{ session_id, pid_str, @errorName(err) },
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
    _ = now_unix;

    const di = nalarcore.getSingleton() catch return;
    const allocator = di.allocator;
    const logger = di.logger;

    // Per-tick arena — all SQL string allocations live for the
    // duration of the cleanupStaleBackgroundProcesses call. Cheaper
    // than per-row alloc/free and the arena frees them in one shot
    // when this scope exits.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = cleanupStaleBackgroundProcesses(.{
        .allocator = a,
        .db = di.db,
        .logger = logger,
    }) catch |err| {
        logger.errFmt("[cleanup_stale_background_process] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    logger.infoFmt(
        "[cleanup_stale_background_process] tick summary: checked={d} kept={d} deleted={d}",
        .{ result.checked_count, result.kept_count, result.deleted_count },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────
//
// Inline tests, matching the project convention for files that have
// impl + tests (delete_worker.zig, cleanup_stale_worker.zig).
// Aggregated into the test module graph via src/root.zig's test block.

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

    // Mirror the production schema exactly (migration 014 — src/migrations/migration.zig:218).
    // Hand-rolling here is acceptable for tests, matching cleanup_stale_worker.zig's pattern.
    try db.exec(alloc,
        \\CREATE TABLE session_background_process (
        \\    session_id TEXT NOT NULL,
        \\    pid INTEGER NOT NULL,
        \\    command TEXT NOT NULL,
        \\    log_path TEXT NOT NULL,
        \\    started_at INTEGER NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'running',
        \\    PRIMARY KEY (session_id, pid)
        \\)
    , &.{});

    return .{
        .db = db,
        .threaded = threaded,
    };
}

/// Insert a background-process row. `pid` is passed as an `i64` so SQLite
/// can coerce it to INTEGER (matching the production column type).
///
/// Uses `bufPrint` with a stack buffer so the test doesn't leak through
/// the DebugAllocator (PIDs fit easily in 32 bytes — i64 max is 19 chars).
fn seedRow(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    pid: i64,
    status: []const u8,
) !void {
    const sql =
        \\INSERT INTO session_background_process
        \\    (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, 'echo hi', '/tmp/log', 1, ?)
    ;
    var pid_buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    try db.exec(alloc, sql, &.{ session_id, pid_str, status });
}

/// Count rows for a given session_id. Returns 0 when none.
fn rowCountForSession(
    db: *sqlite.SqliteBackend,
    arena_alloc: std.mem.Allocator,
    session_id: []const u8,
) !usize {
    var rows = try db.query(arena_alloc, "SELECT 1 FROM session_background_process WHERE session_id = ?", &.{session_id});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(arena_alloc);
        count += 1;
    }
    return count;
}

test "cleanupStaleBackgroundProcesses deletes a row whose PID is no longer running" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // 999_999_999 is virtually guaranteed to NOT exist on any sane system.
    try seedRow(&ctx.db, testing.allocator, "s_dead", 999_999_999, "running");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead"));
}

test "cleanupStaleBackgroundProcesses keeps a row whose PID is still running (self)" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // Self PID — guaranteed alive for the lifetime of this test process.
    const self_pid = process_status.getCurrentProcessIdInt();
    try seedRow(&ctx.db, testing.allocator, "s_alive", @intCast(self_pid), "stopped"); // status column is irrelevant per user spec

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
    try testing.expectEqual(@as(usize, 1), result.kept_count);
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive"));
}

test "cleanupStaleBackgroundProcesses ignores the status column: keeps an alive row even when status='failed'" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();
    // Status 'failed' is stale — but the PID is alive, so we keep it.
    try seedRow(&ctx.db, testing.allocator, "s_alive_failed", @intCast(self_pid), "failed");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 1), result.kept_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_failed"));
}

test "cleanupStaleBackgroundProcesses ignores the status column: deletes a dead row even when status='running'" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    // Status 'running' is stale (e.g. kill -9 left the row) — but the PID is dead, so we delete it.
    try seedRow(&ctx.db, testing.allocator, "s_dead_running", 999_999_998, "running");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_running"));
}

test "cleanupStaleBackgroundProcesses processes a mixed batch and reports kept vs deleted correctly" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();

    try seedRow(&ctx.db, testing.allocator, "s_alive_a", @intCast(self_pid), "running");
    try seedRow(&ctx.db, testing.allocator, "s_alive_b", @intCast(self_pid), "stopped");
    try seedRow(&ctx.db, testing.allocator, "s_dead_a", 999_999_997, "running");
    try seedRow(&ctx.db, testing.allocator, "s_dead_b", 999_999_996, "stopped");
    try seedRow(&ctx.db, testing.allocator, "s_dead_c", 999_999_995, "failed");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 5), result.checked_count);
    try testing.expectEqual(@as(usize, 2), result.kept_count);
    try testing.expectEqual(@as(usize, 3), result.deleted_count);

    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_a"));
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_b"));
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_a"));
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_b"));
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead_c"));
}

test "cleanupStaleBackgroundProcesses is a no-op when the table is empty" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 0), result.checked_count);
    try testing.expectEqual(@as(usize, 0), result.kept_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
}

test "cleanupStaleBackgroundProcesses keeps a row whose PID is running even with malformed status string" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();
    // 'banana' is a garbage status value — but since we ignore status entirely,
    // the row is kept as long as the PID is alive.
    try seedRow(&ctx.db, testing.allocator, "s_alive_garbage_status", @intCast(self_pid), "banana");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 1), result.kept_count);
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_garbage_status"));
}

test "cleanupStaleBackgroundProcesses returns the DB error when the session_background_process table is missing" {
    // Build a DB WITHOUT the table — the helper must propagate the
    // error rather than panic. The cron wrapper (handle) is responsible
    // for catching + logging.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    // NO CREATE TABLE — the query will fail with "no such table".

    const result = cleanupStaleBackgroundProcesses(.{
        .allocator = alloc,
        .db = &db,
        .logger = null,
    });

    // We don't pin the exact error variant — SqliteBackend maps
    // missing-table to PrepareFailed (Sqlite.zig:568) which the helper
    // propagates verbatim.
    try testing.expectError(error.PrepareFailed, result);
}

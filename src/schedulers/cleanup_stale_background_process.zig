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
const process_status = @import("helpers").process_status;
const logger_mod = nalarcore.loggermod;
// `migration.zig` lives in `src/migrations/` — one `..` up from
// `src/schedulers/`. Per project memory `project-test-use-migrations-module`:
// test setupDb MUST use `MigrationManager.registerAllMigrations +
// runMigrations()` to spin up an in-memory DB that walks ALL migrations
// from 001 → latest, never hand-roll CREATE TABLE bodies. The migration
// chain is the single source of truth; hand-rolled schemas drift from
// production the moment a new column or trigger lands.
const migration = @import("../migrations/migration.zig");
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
// Two-pass cleanup. Pass 1: SELECT every (session_id, pid) pair and
// check the actual OS process via
// `helpers.process_status.isProcessRunning`. Dead processes are
// collected. Pass 2: batch DELETE all collected rows in one (or a few)
// statements. The `status` column is deliberately IGNORED — it can
// drift from reality (a `kill -9` leaves it at `'running'` because the
// defer that updates it never ran; or a process can be alive while the
// row says otherwise).
//
// Batching is chunked at `max_pairs_per_stmt` pairs per DELETE
// statement because SQLite's default `SQLITE_MAX_VARIABLE_NUMBER` is
// 999 and each pair binds 2 params — 499 pairs max per statement.
// Anything more becomes a second DELETE.
//
// Per-chunk isolation: if one batch DELETE fails, log via
// `logger.?errFmt` and continue to the next chunk. The cron tick
// must NOT abort the whole cleanup on a single bad chunk.

/// Max (session_id, pid) pairs per single DELETE statement.
/// `SQLITE_MAX_VARIABLE_NUMBER` defaults to 999; each pair = 2 params.
const max_pairs_per_stmt: usize = 499;

pub fn cleanupStaleBackgroundProcesses(input: CleanupStaleBackgroundProcessInput) anyerror!CleanupResult {
    const allocator = input.allocator;
    const db = input.db;
    const logger = input.logger;

    var result = CleanupResult{};

    // Per-call arena for the dead-rows collection. The slice pointers
    // we collect from `row.values[0]` / `row.values[1]` are owned by
    // the row and freed on `row.deinit`; without the arena, we'd have
    // to dupe each one (or worse, use-after-free). Using a per-call
    // arena gives us "borrow the row's slice memory" semantics with
    // zero per-row alloc/free overhead — the arena frees everything
    // in one shot when this function returns.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pass 1: SELECT every (session_id, pid) pair. For each row, ask
    // the OS whether the process is alive. Dead rows get collected
    // for the batch DELETE in pass 2.
    const DeadPair = struct {
        session_id: []const u8,
        pid: []const u8,
    };
    var dead: std.ArrayListUnmanaged(DeadPair) = .empty;
    defer dead.deinit(a);

    const select_sql =
        \\SELECT session_id, pid
        \\FROM session_background_process
    ;

    var rows = try db.query(a, select_sql, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(a);

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

        // Process is dead — collect (session_id, pid) for the batch
        // DELETE in pass 2.
        //
        // CRITICAL: row.values[i] is freed by `row.deinit(a)` (which
        // fires at the end of this iteration block). Without duping,
        // the slices stored in `dead` would dangle by the time pass 2
        // runs. Duping into the arena gives us stable copies that
        // outlive every row.deinit() and live until arena.deinit() at
        // the end of this function.
        const sid_copy = a.dupe(u8, session_id) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(session_id) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        const pid_copy = a.dupe(u8, pid_str) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(pid) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        dead.append(a, .{ .session_id = sid_copy, .pid = pid_copy }) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] dead-list append failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
    }

    if (dead.items.len == 0) return result;

    // Pass 2: batch DELETE all collected rows in chunks. Each chunk
    // builds ONE statement of the form
    //   DELETE FROM session_background_process
    //   WHERE (session_id = ? AND pid = ?)
    //      OR (session_id = ? AND pid = ?)
    //      OR ...
    // The OR-chain form is the simplest portable SQLite pattern; it
    // binds exactly 2 params per pair and avoids the version-fuss of
    // row-value `IN ((?, ?), ...)` syntax. Composite PK means we MUST
    // match both session_id AND pid — the same PID can exist under
    // multiple sessions and deleting only by pid would clobber
    // unrelated rows.
    var chunk_start: usize = 0;
    while (chunk_start < dead.items.len) {
        const chunk_end = @min(chunk_start + max_pairs_per_stmt, dead.items.len);
        const chunk = dead.items[chunk_start..chunk_end];

        // Build SQL + params in the arena — both are scoped to this
        // chunk iteration so the arena frees them when chunk_start
        // advances.
        var sql_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer sql_buf.deinit(a);
        sql_buf.appendSlice(a, "DELETE FROM session_background_process WHERE ") catch continue;

        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        defer params.deinit(a);

        var ok = true;
        for (chunk, 0..) |pair, i| {
            if (i > 0) {
                sql_buf.appendSlice(a, " OR ") catch {
                    ok = false;
                    break;
                };
            }
            sql_buf.appendSlice(a, "(session_id = ? AND pid = ?)") catch {
                ok = false;
                break;
            };
            params.append(a, pair.session_id) catch {
                ok = false;
                break;
            };
            params.append(a, pair.pid) catch {
                ok = false;
                break;
            };
        }
        if (!ok) {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] SQL build failed at chunk offset {d}\n",
                    .{chunk_start},
                );
            }
            continue;
        }

        db.exec(a, sql_buf.items, params.items) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] batch DELETE failed at chunk offset {d} (size={d}): {s}\n",
                    .{ chunk_start, chunk.len, @errorName(err) },
                );
            }
            continue;
        };

        result.deleted_count += chunk.len;
        chunk_start = chunk_end;
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

    // Walk every production migration (001 → latest). After this returns,
    // the schema is exactly what a production DB looks like — including
    // the `session_background_process` table created by Migration 014.
    // No hand-rolled CREATE TABLE — that's the project convention
    // (see project-test-use-migrations-module memory; reviewer note on
    // PR #172: "when setup db, use from migrations module, migrations
    // module will load all table").
    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

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

test "cleanupStaleBackgroundProcesses batch-chunks deletes when more than max_pairs_per_stmt dead rows exist" {
    // Verify the chunking logic at the 499-pair boundary. We seed 600
    // dead rows (PID 999_999_990..999_999_999 is more than enough
    // distinct dead PIDs at i64 magnitudes no real system would have).
    // 600 > 499 means the helper MUST issue at least 2 batch DELETEs
    // — the first 499-pair statement + a 101-pair statement. If the
    // chunking regressed to a single unbounded statement, SQLite would
    // either accept it (newer SQLite, variable limit 32766) or reject
    // it (older SQLite, limit 999). Either way, the externally
    // observable contract — "every dead row is gone, every alive row
    // stays, counts are accurate" — must still hold.
    //
    // We also seed 2 live rows (self PID × 2 distinct sessions) and
    // confirm they survive the cleanup.
    var ctx = try setupCtx();
    defer ctx.deinit();

    const self_pid = process_status.getCurrentProcessIdInt();

    // 600 dead rows
    var i: i64 = 0;
    while (i < 600) : (i += 1) {
        // Use i64 PID 999_999_990 + i to stay below max i32 (≈2.1B).
        try seedRow(&ctx.db, testing.allocator, "s_dead", 999_999_990 + i, "running");
    }

    // 2 live rows under different session_ids (composite PK is
    // (session_id, pid); the same PID CAN appear under multiple
    // sessions, so this is a valid setup).
    try seedRow(&ctx.db, testing.allocator, "s_alive_a", @intCast(self_pid), "running");
    try seedRow(&ctx.db, testing.allocator, "s_alive_b", @intCast(self_pid), "running");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .db = &ctx.db,
        .logger = null,
    });

    try testing.expectEqual(@as(usize, 602), result.checked_count);
    try testing.expectEqual(@as(usize, 2), result.kept_count);
    try testing.expectEqual(@as(usize, 600), result.deleted_count);

    // All 600 dead rows gone
    var q = try ctx.db.query(testing.allocator,
        "SELECT COUNT(*) FROM session_background_process WHERE session_id = 's_dead'",
        &.{});
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(testing.allocator);
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{s}", .{row.values[0]});
        try testing.expectEqualStrings("0", count_str);
    } else {
        return error.TestExpectedRow;
    }

    // Both alive rows still present
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_a"));
    try testing.expectEqual(@as(usize, 1), try rowCountForSession(&ctx.db, testing.allocator, "s_alive_b"));
}

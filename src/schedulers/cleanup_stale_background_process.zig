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
//! parse (session_id, pid, command, log_path), call `isProcessRunning`,
//! keep if alive, otherwise queue the completion message via
//! `insertQueueMessage` (notify) and DELETE (only if notified).
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
const event_bus_mod = nalarcore.event_bus;
// Route the bg-completion helpers + queue insert through `nalarcore`
// (the `root` module) instead of @import'ing the agentic_loop files
// directly — same pattern as cleanup_stale_worker.zig's
// `nalarcore.ai_mod.delete_worker`. The exe module compiles `main.zig`
// which reaches this file via the `nalarcore` re-export; a direct
// relative @import here would put those files in TWO modules and fire
// Zig's "file exists in two modules" error. `insertQueueMessage` is
// re-exported by workflow.zig so no mod.zig change is needed for it;
// `background_process` has its own `pub const` in ai_workflow/tui/mod.zig.
const bg_proc = nalarcore.ai_mod.background_process;
const ai_workflow = nalarcore.ai_mod.ai_workflow;
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
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    event_bus: ?*event_bus_mod.EventBus,
};

pub const CleanupResult = struct {
    checked_count: usize = 0,
    kept_count: usize = 0,
    notified_count: usize = 0,
    deleted_count: usize = 0,
};

// ─── Production helper ────────────────────────────────────────────────────
//
// Three-phase notify-then-delete. Pass 1: SELECT every
// (session_id, pid, command, log_path) row and check the actual OS
// process via `helpers.process_status.isProcessRunning`. Dead processes
// are collected. Pass 1.5 (notify): for each dead pair, read the log
// (capped at `bg_proc.completion_log_cap_bytes`), build the completion
// envelope via `bg_proc.buildCompletionMessage`, and queue it with
// `insertQueueMessage` (SSE `queue_queued`, same as any queued user
// message — no new event name). Pass 2: batch DELETE only the pairs
// that were successfully notified. A pair whose notify fails (log
// unreadable for a reason OTHER than FileNotFound, or queue INSERT
// error) is left in the table for the next tick to retry. A missing
// log file is NOT a failure — the queue message carries a
// `(log file not found: {path})` marker and the row is still deleted.
//
// The `status` column is deliberately IGNORED — it can drift from
// reality (a `kill -9` leaves it at `'running'` because the defer that
// updates it never ran; or a process can be alive while the row says
// otherwise).
//
// Batching is chunked at `max_pairs_per_stmt` pairs per DELETE
// statement because SQLite's default `SQLITE_MAX_VARIABLE_NUMBER` is
// 999 and each pair binds 2 params — 499 pairs max per statement.
// Anything more becomes a second DELETE.
//
// Per-row isolation: if one row's log read / queue insert fails, log
// via `logger.?errFmt` and continue to the next row — the cron tick
// must NOT abort the whole cleanup on a single bad row. Per-chunk
// isolation for the DELETEs likewise: one bad batch logs and the tick
// continues to the next chunk.

/// Max (session_id, pid) pairs per single DELETE statement.
/// `SQLITE_MAX_VARIABLE_NUMBER` defaults to 999; each pair = 2 params.
const max_pairs_per_stmt: usize = 499;

pub fn cleanupStaleBackgroundProcesses(input: CleanupStaleBackgroundProcessInput) anyerror!CleanupResult {
    const allocator = input.allocator;
    const io = input.io;
    const db = input.db;
    const logger = input.logger;
    const event_bus = input.event_bus;

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

    // Pass 1: SELECT every (session_id, pid, command, log_path) row.
    // For each row, ask the OS whether the process is alive. Dead rows
    // get collected for the notify + batch DELETE in passes 1.5 / 2.
    const DeadPair = struct {
        session_id: []const u8,
        pid: []const u8,
        pid_num: u32,
        command: []const u8,
        log_path: []const u8,
        notified: bool = false,
    };
    var dead: std.ArrayListUnmanaged(DeadPair) = .empty;
    defer dead.deinit(a);

    const select_sql =
        \\SELECT session_id, pid, command, log_path
        \\FROM session_background_process
    ;

    var rows = try db.query(a, select_sql, &.{});
    defer rows.deinit();

    while (try rows.next()) |row| {
        defer row.deinit(a);

        if (row.values.len < 4) continue;
        const session_id = row.values[0];
        const pid_str = row.values[1];
        const command = row.values[2];
        const log_path = row.values[3];

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

        // Process is dead — collect the row for the notify (pass 1.5)
        // + batch DELETE (pass 2).
        //
        // CRITICAL: row.values[i] is freed by `row.deinit(a)` (which
        // fires at the end of this iteration block). Without duping,
        // the slices stored in `dead` would dangle by the time passes
        // 1.5 / 2 run. Duping into the arena gives us stable copies
        // that outlive every row.deinit() and live until arena.deinit()
        // at the end of this function.
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
        const cmd_copy = a.dupe(u8, command) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(command) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        const log_copy = a.dupe(u8, log_path) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] arena dupe(log_path) failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
        dead.append(a, .{
            .session_id = sid_copy,
            .pid = pid_copy,
            .pid_num = @intCast(pid),
            .command = cmd_copy,
            .log_path = log_copy,
        }) catch |err| {
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

    // Pass 1.5 (notify): for each dead pair, read the log + queue the
    // completion message. Per-row isolation — one bad log or failed
    // INSERT logs and leaves that pair un-notified (it stays in the
    // table for the next tick); the loop always continues.
    //
    // All message buffers are arena-allocated (`a`): `insertQueueMessage`
    // binds/copies them into SQLite synchronously, so they only need to
    // live for the duration of the call. No defer-free of arena memory
    // here per the per-request arena rule.
    for (dead.items) |*pair| {
        // Read the log head. FileNotFound → not-found marker (still
        // notify + delete). Any OTHER read error → skip notify for
        // this pair; it stays for the next tick to retry.
        var log_content: []const u8 = "";
        var was_truncated: bool = false;
        var total_bytes: usize = 0;
        if (bg_proc.readLogTruncated(a, io, pair.log_path, bg_proc.completion_log_cap_bytes)) |tlog| {
            // `tlog.content` is arena-owned — no free (arena rule).
            log_content = tlog.content;
            was_truncated = tlog.truncated;
            total_bytes = tlog.total_bytes;
        } else |err| {
            if (err == error.FileNotFound) {
                log_content = std.fmt.allocPrint(
                    a,
                    "(log file not found: {s})",
                    .{pair.log_path},
                ) catch {
                    if (logger) |log| {
                        log.errFmt(
                            "[cleanup_stale_background_process] not-found marker alloc failed for session {s} pid {s}\n",
                            .{ pair.session_id, pair.pid },
                        );
                    }
                    continue;
                };
                was_truncated = false;
                total_bytes = 0;
            } else {
                if (logger) |log| {
                    log.errFmt(
                        "[cleanup_stale_background_process] log read failed for session {s} pid {s} ({s}): {s} — retry next tick\n",
                        .{ pair.session_id, pair.pid, pair.log_path, @errorName(err) },
                    );
                }
                continue;
            }
        }

        const message = bg_proc.buildCompletionMessage(
            a,
            pair.command,
            pair.pid_num,
            log_content,
            was_truncated,
            total_bytes,
            pair.log_path,
        ) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] completion message build failed for session {s} pid {s}: {s} — retry next tick\n",
                    .{ pair.session_id, pair.pid, @errorName(err) },
                );
            }
            continue;
        };

        ai_workflow.insertQueueMessage(.{
            .allocator = a,
            .db = db,
            .logger = logger,
            .session_id = pair.session_id,
            .message = message,
            .image_url = "",
            .event_bus = event_bus,
            .is_emit_sse = true,
        }) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] queue insert failed for session {s} pid {s}: {s} — retry next tick\n",
                    .{ pair.session_id, pair.pid, @errorName(err) },
                );
            }
            continue;
        };

        pair.notified = true;
        result.notified_count += 1;
    }

    // Collect only the notified pairs for the DELETE. Failed-notify
    // pairs stay in the table for the next tick to retry.
    var doomed: std.ArrayListUnmanaged(DeadPair) = .empty;
    defer doomed.deinit(a);
    for (dead.items) |pair| {
        if (!pair.notified) continue;
        doomed.append(a, pair) catch |err| {
            if (logger) |log| {
                log.errFmt(
                    "[cleanup_stale_background_process] delete-list append failed: {s}\n",
                    .{@errorName(err)},
                );
            }
            return result;
        };
    }

    if (doomed.items.len == 0) return result;

    // Pass 2: batch DELETE all successfully-notified rows in chunks.
    // Each chunk builds ONE statement of the form
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
    while (chunk_start < doomed.items.len) {
        const chunk_end = @min(chunk_start + max_pairs_per_stmt, doomed.items.len);
        const chunk = doomed.items[chunk_start..chunk_end];

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
        .io = di.io,
        .db = di.db,
        .logger = logger,
        .event_bus = di.event_bus,
    }) catch |err| {
        logger.errFmt("[cleanup_stale_background_process] tick failed: {s}\n", .{@errorName(err)});
        return;
    };

    logger.infoFmt(
        "[cleanup_stale_background_process] tick summary: checked={d} kept={d} notified={d} deleted={d}",
        .{ result.checked_count, result.kept_count, result.notified_count, result.deleted_count },
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

/// Insert a background-process row with an explicit command + log_path
/// (for the notify-then-delete tests, which need a real temp log file
/// or a deliberately missing path). `seedRow` delegates with the
/// historical `'echo hi'` / `'/tmp/log'` defaults.
fn seedRowFull(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
    pid: i64,
    command: []const u8,
    log_path: []const u8,
    status: []const u8,
) !void {
    const sql =
        \\INSERT INTO session_background_process
        \\    (session_id, pid, command, log_path, started_at, status)
        \\VALUES (?, ?, ?, ?, 1, ?)
    ;
    var pid_buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    try db.exec(alloc, sql, &.{ session_id, pid_str, command, log_path, status });
}

/// Fetch the single queue message for a session. Errors with
/// `error.RowMissing` when the notify step never queued one.
fn queueMessageForSession(
    db: *sqlite.SqliteBackend,
    alloc: std.mem.Allocator,
    session_id: []const u8,
) ![]u8 {
    var q = try db.query(alloc, "SELECT message FROM session_queue_messages WHERE session_id = ?", &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
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
        .io = testing.io,
        .event_bus = null,
    });

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.notified_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_dead"));
}

test "cleanupStaleBackgroundProcesses notifies with log content then deletes the dead row" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bg.log", .data = "build finished ok" });

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const log_path = try std.fs.path.join(testing.allocator, &.{ dir_buf[0..dir_len], "bg.log" });
    defer testing.allocator.free(log_path);

    // 999_999_999 is virtually guaranteed to NOT exist on any sane system.
    try seedRowFull(&ctx.db, testing.allocator, "s_done", 999_999_999, "make all", log_path, "running");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
    });

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.notified_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_done"));

    const msg = try queueMessageForSession(&ctx.db, testing.allocator, "s_done");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "\"\"\"\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "999999999") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "make all") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "build finished ok") != null);
}

test "cleanupStaleBackgroundProcesses notifies with a not-found marker and still deletes when the log is missing" {
    var ctx = try setupCtx();
    defer ctx.deinit();

    const missing = "/tmp/nalar-bg-test-never-exists-xyz.log";
    try seedRowFull(&ctx.db, testing.allocator, "s_gone", 999_999_998, "sleep 30", missing, "running");

    const result = try cleanupStaleBackgroundProcesses(.{
        .allocator = testing.allocator,
        .io = testing.io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
    });

    try testing.expectEqual(@as(usize, 1), result.checked_count);
    try testing.expectEqual(@as(usize, 1), result.notified_count);
    try testing.expectEqual(@as(usize, 1), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowCountForSession(&ctx.db, testing.allocator, "s_gone"));

    const msg = try queueMessageForSession(&ctx.db, testing.allocator, "s_gone");
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "log file not found") != null);
    try testing.expect(std.mem.indexOf(u8, msg, missing) != null);
    try testing.expect(std.mem.indexOf(u8, msg, "999999998") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "sleep 30") != null);
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
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
        .io = testing.io,
        .event_bus = null,
    });

    try testing.expectEqual(@as(usize, 602), result.checked_count);
    try testing.expectEqual(@as(usize, 2), result.kept_count);
    try testing.expectEqual(@as(usize, 600), result.notified_count);
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

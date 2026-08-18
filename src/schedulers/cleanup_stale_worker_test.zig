//! Tests for `src/schedulers/cleanup_stale_worker.zig`.
//!
//! Plan: docs/superpowers/plans/2026-08-19-cleanup-stale-worker-cron.md.
//!
//! The test fixtures follow the project's standard in-memory sqlite
//! pattern (see `delete_worker.zig:53-65`, `is_worker_running.zig:25-37`,
//! `update_worker.zig:144-178`). `ActiveLoops` is constructed in-memory
//! per test so we can assert on `.contains(io, session_id)` directly.

const std = @import("std");
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const testing = std.testing;

const cleanup = @import("cleanup_stale_worker.zig");
const ActiveLoops = @import("../ai_workflow/tui/agentic_loop/ActiveLoops.zig").ActiveLoops;

// ─── Test helpers ─────────────────────────────────────────────────────────

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
    active_loops: ActiveLoops,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestCtx) void {
        self.active_loops.deinit(testing.allocator);
        self.db.deinit();
        self.threaded.deinit();
        self.arena.deinit();
    }
};

fn setupCtx() !TestCtx {
    const alloc = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    // Minimal schema matching the production worker table (after
    // migration 075). We use the column types from
    // src/migrations/migration.zig:294-330 + 3198-3218.
    try db.exec(arena_alloc,
        \\CREATE TABLE worker (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    working_directory TEXT,
        \\    last_activity_nano INTEGER,
        \\    last_activity_description TEXT,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // ActiveLoops uses testing.allocator directly (NOT the arena) — the
    // hash map stores the allocator pointer for the lifetime of the
    // structure, and our arena outlives the test body via `defer
    // ctx.deinit()`, so the arena path *should* work, but Zig 0.16's
    // StringHashMap managed-allocator path appears to mis-handle the
    // arena's vtable in this configuration. Using testing.allocator
    // is simpler and matches the per-test lifetime.
    const active_loops = ActiveLoops.init(alloc);

    return .{
        .db = db,
        .threaded = threaded,
        .active_loops = active_loops,
        .arena = arena,
    };
}

/// Insert a worker row with an explicit `last_activity_nano` value
/// (passed as a string — SQLite type-coerces into INTEGER). Returns
/// the row's id for convenience.
fn seedWorker(
    db: *sqlite.SqliteBackend,
    arena_alloc: std.mem.Allocator,
    id: []const u8,
    session_id: []const u8,
    last_activity_nano: []const u8,
) !void {
    const sql =
        \\INSERT INTO worker (id, session_id, working_directory, last_activity_nano)
        \\VALUES (?, ?, '/tmp', ?)
    ;
    try db.exec(arena_alloc, sql, &.{ id, session_id, last_activity_nano });
}

/// Convenience: returns the row count for the given id (0 or 1).
fn rowExists(
    db: *sqlite.SqliteBackend,
    arena_alloc: std.mem.Allocator,
    id: []const u8,
) !usize {
    var rows = try db.query(arena_alloc, "SELECT 1 FROM worker WHERE id = ?", &.{id});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        defer row.deinit(arena_alloc);
        count += 1;
    }
    return count;
}

// ─── Tests ───────────────────────────────────────────────────────────────

const CleanupStaleWorkerInput = cleanup.CleanupStaleWorkerInput;

test "cleanupStaleWorkers deletes a worker whose last_activity_nano is older than the threshold" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    try seedWorker(&ctx.db, a, "w_old", "s_old", "100"); // 990_000 seconds before now
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_500"); // 500 seconds before now

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_old"));
    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

test "cleanupStaleWorkers keeps a worker whose last_activity_nano is fresher than the threshold" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    // 599 seconds before now — strictly FRESHER than the 600-second
    // threshold (uses `<`, not `<=`).
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_401");

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

test "cleanupStaleWorkers treats NULL last_activity_nano as stale (pre-migration-075 rows)" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    // NULL last_activity_nano (pre-migration-075 rows may look like this)
    try ctx.db.exec(a,
        "INSERT INTO worker (id, session_id, last_activity_nano) VALUES ('w_null', 's_null', NULL)",
        &.{},
    );

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_null"));
}

test "cleanupStaleWorkers removes the matching ActiveLoops entry when present" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const io = ctx.threaded.io();
    const now: i64 = 1_000_000;

    try seedWorker(&ctx.db, a, "w_old", "s_old", "100");
    try testing.expect(ctx.active_loops.tryInsert(io, "s_old"));

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expect(!ctx.active_loops.contains(io, "s_old"));
}

test "cleanupStaleWorkers is a no-op when the worker table is empty" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();

    const result = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = 1_000_000,
    });

    try testing.expectEqual(@as(usize, 0), result.stale_count);
    try testing.expectEqual(@as(usize, 0), result.deleted_count);
}

test "cleanupStaleWorkers clears ActiveLoops for a session whose worker is stale (idempotent remove)" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const io = ctx.threaded.io();
    const now: i64 = 1_000_000;

    // Pre-populate ActiveLoops with an entry whose worker row is
    // ALREADY stale. After cleanup, the entry should be gone (the
    // helper iterates stale workers from the SQL and removes their
    // matching active_loops entries).
    try seedWorker(&ctx.db, a, "w_stale", "s_stale", "100");
    try testing.expect(ctx.active_loops.tryInsert(io, "s_stale"));

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = io,
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expect(!ctx.active_loops.contains(io, "s_stale"));
}

test "cleanupStaleWorkers processes multiple stale workers in one call" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    try seedWorker(&ctx.db, a, "w_a", "s_a", "100");
    try seedWorker(&ctx.db, a, "w_b", "s_b", "200");
    try seedWorker(&ctx.db, a, "w_c", "s_c", "300");
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_500");

    const result = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 3), result.stale_count);
    try testing.expectEqual(@as(usize, 3), result.deleted_count);
    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_a"));
    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_b"));
    try testing.expectEqual(@as(usize, 0), try rowExists(&ctx.db, a, "w_c"));
    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

// ─── Boundary tests (Task 3 in the plan) ────────────────────────────────

test "cleanupStaleWorkers does NOT delete a worker whose last_activity_nano is exactly at the threshold" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    // now_unix - threshold_seconds = 1000 - 600 = 400 (boundary)
    // `<` means 400 is NOT considered stale.
    const now: i64 = 1000;
    try seedWorker(&ctx.db, a, "w_boundary", "s_boundary", "400");

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_boundary"));
}

test "cleanupStaleWorkers uses SQL as the gating check (ActiveLoops state is irrelevant for keep/delete)" {
    var ctx = try setupCtx();
    defer ctx.deinit();
    const a = ctx.arena.allocator();
    const now: i64 = 1_000_000;

    // Fresh row (last_activity close to now). ActiveLoops does NOT
    // contain it. The helper should still keep it.
    try seedWorker(&ctx.db, a, "w_fresh", "s_fresh", "999_500");

    _ = try cleanup.cleanupStaleWorkers(.{
        .allocator = a,
        .io = ctx.threaded.io(),
        .db = &ctx.db,
        .logger = null,
        .event_bus = null,
        .active_loops = &ctx.active_loops,
        .now_unix = now,
    });

    try testing.expectEqual(@as(usize, 1), try rowExists(&ctx.db, a, "w_fresh"));
}

// ─── Failure-tolerance test (Task 4 in the plan) ────────────────────────

test "cleanupStaleWorkers returns the DB error when the worker table itself is missing" {
    // Simulate the "table does not exist" failure path by creating
    // a DB with NO worker table and confirming the helper propagates
    // the error rather than panicking. The cron wrapper (handle)
    // is responsible for catching + logging — the helper just
    // surfaces the error.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: sqlite.SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, ":memory:");
    // NO CREATE TABLE — the query will fail with "no such table".

    // Failure-tolerance test doesn't mutate the loops map (it never
    // calls tryInsert / remove), so technically `const` would be
    // correct — but the helper takes `*ActiveLoops` and `deinit`
    // also takes `*ActiveLoops`. Wrap in a holder struct so the
    // `loops` field has a mutable lvalue.
    const LoopsHolder = struct { loops: ActiveLoops };
    var holder = LoopsHolder{ .loops = ActiveLoops.init(alloc) };
    defer holder.loops.deinit(alloc);

    const result = cleanup.cleanupStaleWorkers(.{
        .allocator = alloc,
        .io = io,
        .db = &db,
        .logger = null,
        .event_bus = null,
        .active_loops = &holder.loops,
        .now_unix = 1_000_000,
    });

    // We don't pin the specific SqliteBackend Error variant here —
    // the SqliteBackend maps missing-table to PrepareFailed
    // (Sqlite.zig:568) which the helper propagates verbatim. The
    // cron wrapper (handle) is responsible for catching + logging.
    try testing.expectError(error.PrepareFailed, result);
}
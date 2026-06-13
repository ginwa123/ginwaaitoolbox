//! Behavioral tests for `Scheduler.zig` (Task 3.1 of the Add Task
//! Routines plan).
//!
//! `Scheduler` is the polling loop that drives routines to fire. It
//! has three public helpers (tested here) and one public `start`
//! function (the infinite polling loop, exercised by the integration
//! test in Task 3.3 at the bottom of this file):
//!
//!   - `resetStuckRunning`     — flip every `last_status='running'` row
//!                               to `'failed'` with a "process killed"
//!                               error. Called once at startup to
//!                               recover from a previous process crash.
//!   - `recomputeDueNextRunAt` — recompute `next_run_at` for every
//!                               enabled routine. Called once at
//!                               startup so routines that were due
//!                               during downtime fire within 5s of boot.
//!   - `start`                 — the polling loop. Tested by the
//!                               integration test below (Task 3.3).
//!
//! Both unit tests use the in-memory sqlite pattern from
//! `migration_routines_test.zig` / `model_test.zig` / `fire_test.zig`.
//! The actual SqliteBackend API is `db.query(alloc, sql, args) → Rows →
//! next() → ?Row{ values: [][]u8 }`. Column reads go through
//! `row.values[i]` (a `[]u8` text slice, empty string for NULLs); there
//! is no `.scalar` accessor in this codebase.
//!
//! The integration test at the bottom of this file (Task 3.3) is a
//! real end-to-end test: it spawns the `Scheduler.start` polling loop
//! in a background thread, which in turn `std.process.spawn`s the
//! `nalar-routine-fire` sub-process. The sub-process reads the same
//! DB file (WAL mode allows concurrent connections), marks the
//! routine `success` (via the `ROUTINE_FIRE_TEST_SKIP_LLM=1`
//! short-circuit in `fire.zig`), and the test polls the DB until the
//! status changes. Wall clock: 0-70s (next minute boundary + one
//! scheduler tick + sub-process startup).
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = @import("../migration.zig");
const Migration044AddRoutines = migration.Migration044AddRoutines;

const model = @import("model.zig");
const Scheduler = @import("Scheduler.zig");

// ─── libc getenv for the integration test ─────────────────────────────────
//
// The integration test (Task 3.3) verifies the prereq env vars are set
// at the shell level (before `zig build test` is invoked). Zig 0.16
// removed `std.process.getEnvVar`, so we declare libc getenv directly.
// The declaration is only referenced from the Task 3.3 test, but it's
// at module scope because Zig 0.16 file-scope `extern "c"` declarations
// are NOT implicitly `pub` and they MUST be at module scope to be
// callable from the test (any in-function declaration would be local
// to that function).
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the pre-Migration-044 state
/// (`workspace_item_tasks` from Migration 034) and run Migration 044
/// to bring it to the post-migration state. Mirrors the helper in
/// `model_test.zig`.
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

    // Minimal schema — the model tests use a slightly richer one with
    // `session_id`/`created_at`/`updated_at`, but `Scheduler` never
    // reads those, so a 3-column parent table is enough.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL
        \\)
    , &.{});

    try Migration044AddRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Run a single-column SELECT and return a duplicated copy of the
/// first row's first column. Returns null when the query produces no
/// rows. Mirrors the helper in `model_test.zig`.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

// ─── Test 1: resetStuckRunning ────────────────────────────────────────────

test "Scheduler.resetStuckRunning marks running rows as failed" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')",
        &.{});
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "*/5 * * * *",
        .initial_prompt = "x",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Simulate a crashed previous process: routine is stuck in 'running'.
    try ctx.db.exec(alloc,
        "UPDATE routines SET last_status = 'running' WHERE id = 'r1'",
        &.{});

    try Scheduler.resetStuckRunning(alloc, &ctx.db);

    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM routines WHERE id = 'r1'", &.{});
    defer if (status) |s| alloc.free(s);
    const err_msg = try scalarText(alloc, &ctx.db,
        "SELECT last_error FROM routines WHERE id = 'r1'", &.{});
    defer if (err_msg) |s| alloc.free(s);

    try testing.expect(status != null);
    try testing.expectEqualStrings("failed", status.?);
    try testing.expect(err_msg != null);
    try testing.expectEqualStrings("process killed (restart detected)", err_msg.?);
}

// ─── Test 2: recomputeDueNextRunAt ────────────────────────────────────────

test "Scheduler.recomputeDueNextRunAt advances rows in the past" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')",
        &.{});
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "0 9 * * *",
        .initial_prompt = "x",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    try Scheduler.recomputeDueNextRunAt(alloc, &ctx.db, ctx.threaded.io());

    const next = try scalarText(alloc, &ctx.db,
        "SELECT next_run_at FROM routines WHERE id = 'r1'", &.{});
    defer if (next) |s| alloc.free(s);

    try testing.expect(next != null);
    // next_run_at should be in the 21st century, at 09:00:00 (cron
    // nextFireTime from now), not stuck at the year 2000.
    try testing.expect(std.mem.indexOf(u8, next.?, " 09:00:00") != null);
    try testing.expect(std.mem.indexOf(u8, next.?, "2000-") == null);
}

// ─── Test 3: integration — Scheduler.start spawns nalar-routine-fire ──────
//
// Prereq: the `nalar-routine-fire` binary must be built first. Run
// `zig build install:routine-fire` (it's also a transitive dep of
// `install:linux`) before invoking `zig build test`.
//
// SECOND prereq: this test spawns the `nalar-routine-fire` sub-process
// via the real `Scheduler.start` polling loop. The sub-process inherits
// the TEST PROCESS's env (via the Io runtime's cached env block, which
// is captured at test-binary startup). Three env vars are critical:
//
//   PATH: must include `zig-out/bin` (so the kernel can find the
//         binary). Add with `export PATH="$PATH:zig-out/bin"`.
//   HOME: must point to a directory where the sub-process can create
//         `~/.config/nalar/agent.db` WITHOUT overwriting your real
//         production DB. E.g. `export HOME=$(mktemp -d)`.
//   ROUTINE_FIRE_TEST_SKIP_LLM=1: tells fire.zig to short-circuit the
//         LLM emit (the nalar singleton is not initialized in tests).
//
// If any of these are missing, the sub-process will fail to spawn or
// the test will hang. The Zig 0.16 `std.Io.Threaded` env cache is
// process-wide, so my test's `setenv` calls would NOT propagate to
// the sub-process — that's why we need the env set at the shell
// level, before `zig build test` starts the test binary.
//
// This test polls for up to ~70s (350 × 200ms). The wait comes from
// the fact that `recomputeDueNextRunAt` (called once by
// `Scheduler.start` at startup) advances `next_run_at` to the next
// minute boundary (cron has minute granularity). The test sets the
// routine's `next_run_at` to that same boundary; the scheduler will
// fire the routine on the first tick after the boundary. Total wait:
// 0-60s (next minute) + 5s (one scheduler tick) + 100ms (sub-process
// startup).
test "Scheduler: routine with next_run_at in the past fires via real sub-process" {
    const alloc = testing.allocator;
    const io = testing.io;

    // Verify prereqs at runtime. The Io's env cache is invisible to
    // us (it's a private struct field), so we check the libc env
    // instead — the kernel uses libc env to resolve `argv[0]`.
    const path = getenv("PATH") orelse return error.TestPrereqMissingPath;
    const home = getenv("HOME") orelse return error.TestPrereqMissingHome;
    if (getenv("ROUTINE_FIRE_TEST_SKIP_LLM") == null) return error.TestPrereqMissingSkipLlm;
    if (std.mem.indexOf(u8, path[0..std.mem.len(path)], "zig-out/bin") == null) {
        std.debug.print("PATH must include zig-out/bin (got: {s})\n", .{path[0..std.mem.len(path)]});
        return error.TestPrereqMissingZigOutBin;
    }

    // ── 1. Use the test process's HOME for the DB location. The
    //       sub-process (inherited from the Io's env cache) will
    //       open `$HOME/.config/nalar/agent.db`. We create the
    //       `.config/nalar/` subdir to ensure getDbPath()'s
    //       `createDirAbsolute` call succeeds (the sub-process also
    //       creates the dir, but only if HOME is writable; we
    //       guarantee that by creating it here first).

    // Build the DB path. The sub-process will open this exact path.
    const db_path = try std.fs.path.joinZ(alloc, &.{
        home[0..std.mem.len(home)], ".config", "nalar", "agent.db",
    });
    defer alloc.free(db_path);

    // Create the parent dir so the sub-process doesn't fail with
    // `error.FileNotFound` from `getDbPath`'s `createDirAbsolute`.
    // (The sub-process tries to create the dir, but createDirAbsolute
    // does not create parent dirs — it returns FileNotFound if
    // `.config` doesn't exist. We pre-create both to be safe.)
    {
        // Open HOME directly (it's an absolute path). This works
        // because the user-set HOME is a real, writable directory.
        const home_dir = try std.Io.Dir.openDirAbsolute(io, home[0..std.mem.len(home)], .{});
        defer home_dir.close(io);
        try home_dir.createDirPath(io, ".config/nalar");
    }

    // ── 2. Phase A: open the DB, create schemas, insert parent task
    //       and a routine whose `next_run_at` is the *next minute
    //       boundary*. `recomputeDueNextRunAt` (called once by
    //       `Scheduler.start` at startup) will recompute the same
    //       boundary from the cron expression, so the routine will be
    //       due as soon as the wall clock crosses that boundary.
    {
        var db: sqlite.SqliteBackend = .{};
        defer db.deinit();
        try db.init(io, db_path);

        // Mirror the pre-Migration-044 state (Migration 034 +
        // `llm_history` + `sessions` schemas that `fire.zig` touches).
        try db.exec(alloc,
            \\CREATE TABLE workspace_item_tasks (
            \\    id TEXT PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    workspace_item_id TEXT NOT NULL,
            \\    session_id TEXT,
            \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
            \\)
        , &.{});
        try db.exec(alloc,
            \\CREATE TABLE llm_history (
            \\    id TEXT PRIMARY KEY,
            \\    session_id TEXT NOT NULL,
            \\    model TEXT,
            \\    response_content TEXT,
            \\    finish_reason TEXT,
            \\    role TEXT,
            \\    tool_calls_json TEXT,
            \\    tool_call_id TEXT,
            \\    reasoning_content TEXT,
            \\    is_feed_to_llm INTEGER DEFAULT 1,
            \\    agent TEXT,
            \\    loop_index INTEGER DEFAULT 0,
            \\    temperature REAL DEFAULT 0.0,
            \\    is_thinking INTEGER DEFAULT 0,
            \\    created_at TEXT,
            \\    parent_session_id TEXT,
            \\    parent_id TEXT,
            \\    prompt_tokens INTEGER DEFAULT 0,
            \\    completion_tokens INTEGER DEFAULT 0,
            \\    total_tokens INTEGER DEFAULT 0,
            \\    is_input INTEGER DEFAULT 0,
            \\    is_output INTEGER DEFAULT 0,
            \\    tool_name TEXT,
            \\    diffview_before TEXT,
            \\    diffview_after TEXT,
            \\    image_url TEXT
            \\)
        , &.{});
        try db.exec(alloc,
            "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, cwd TEXT, selected_profile_model TEXT, created_at TEXT, updated_at TEXT)",
            &.{});
        try Migration044AddRoutines.up(&db, alloc);

        // Compute the next minute boundary and use it as next_run_at.
        // The cron `* * * * *` matches every minute, so the recomputed
        // value will be the same boundary.
        const now_ns: i128 = @intCast(std.Io.Timestamp.now(io, .real).nanoseconds);
        const min_ns: i128 = 60 * std.time.ns_per_s;
        const next_minute_ns = (@divTrunc(now_ns, min_ns) + 1) * min_ns;
        const secs: i64 = @intCast(@divTrunc(next_minute_ns, std.time.ns_per_s));
        const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @as(u64, @intCast(secs)) };
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const next_run_at = try std.fmt.allocPrint(alloc,
            "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                @as(u32, @intCast(day_seconds.getHoursIntoDay())),
                @as(u32, @intCast(day_seconds.getMinutesIntoHour())),
                @as(u32, @intCast(day_seconds.getSecondsIntoMinute())),
            });
        defer alloc.free(next_run_at);

        try db.exec(alloc,
            "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')",
            &.{});
        try model.insertRoutine(alloc, &db, .{
            .id = "r1",
            .task_id = "t1",
            .schedule = "* * * * *",
            .initial_prompt = "ping",
            .enabled = true,
            .next_run_at = next_run_at,
        });
    }

    // ── 3. Open a new connection (the scheduler thread uses this
    //       one). SQLite WAL mode allows multiple processes (test +
    //       sub-process) and multiple connections within a process
    //       to share the same DB.
    var db_thread: sqlite.SqliteBackend = .{};
    defer db_thread.deinit();
    try db_thread.init(io, db_path);

    // ── 4. Spawn the scheduler thread. `Scheduler.start` runs
    //       `resetStuckRunning` + `recomputeDueNextRunAt` (which
    //       rewrites `next_run_at` to the same minute boundary) and
    //       then enters its 5-second polling loop. The thread is
    //       detached because `start` never returns; the test process
    //       exit reaps it.
    const thread = try std.Thread.spawn(.{}, Scheduler.start, .{ alloc, &db_thread, io });
    thread.detach();

    // ── 5. Poll for up to ~70s (350 × 200ms) for the routine's
    //       `last_status` to leave NULL and become `success` (or
    //       `failed`). The skip-LLM path in fire.zig calls
    //       `markSuccessWithNextRun` so we expect `success`.
    var found_status: ?[]u8 = null;
    var iter: u32 = 0;
    const max_iters: u32 = 350;
    while (iter < max_iters) : (iter += 1) {
        try std.Io.sleep(io, .{ .nanoseconds = 200 * std.time.ns_per_ms }, .real);

        var db_check: sqlite.SqliteBackend = .{};
        defer db_check.deinit();
        try db_check.init(io, db_path);

        var q = try db_check.query(alloc,
            "SELECT last_status FROM routines WHERE id = 'r1'",
            &.{});
        defer q.deinit();

        if (try q.next()) |row| {
            defer row.deinit(alloc);
            // Read the status directly from the row's owned buffer
            // (the row's `defer` above will free it). Compare against
            // the success/failed literals; if matched, dupe the slice
            // so the test can use it after the loop ends.
            const status = row.values[0];
            if (std.mem.eql(u8, status, "success") or
                std.mem.eql(u8, status, "failed"))
            {
                found_status = try alloc.dupe(u8, status);
                break;
            }
        }
    }

    if (found_status) |s| {
        defer alloc.free(s);
        try testing.expectEqualStrings("success", s);
    } else {
        std.debug.print(
            "Scheduler never fired the routine after {d} iterations (~{d}s). Possible causes:\n",
            .{ max_iters, max_iters * 200 / 1000 },
        );
        std.debug.print("  - sub-process couldn't find nalar-routine-fire on PATH\n", .{});
        std.debug.print("  - sub-process couldn't open the test DB at {s}\n", .{db_path});
        std.debug.print("  - cron minute boundary hasn't been crossed yet\n", .{});
        return error.SchedulerNeverFired;
    }
}

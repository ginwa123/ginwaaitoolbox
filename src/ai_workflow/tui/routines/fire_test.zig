//! Behavioral tests for `fire.zig` (Task 2.1 of the Add Task Routines
//! plan).
//!
//! `fireRoutine(allocator, db, io, task_id)` is the per-fire work done
//! by the `nalar-routine-fire` sub-process (Task 2.2). The four
//! behaviors under test:
//!
//!   1. **Happy path** — push a 🔁 user-style message into the session,
//!      claim the row, and (with the test-only env var set) return
//!      `FakeLLMSuccess` without invoking the LLM.
//!   2. **Atomic claim** — a second concurrent fire attempt against a
//!      row already in `running` state must return `AlreadyRunning`
//!      and must NOT insert the 🔁 message.
//!   3. **Not a routine** — a task with no `routines` row returns
//!      `NotARoutine` (no claim, no message).
//!   4. **Disabled routine** — a routine with `enabled = false` returns
//!      `Disabled` (no claim, no message).
//!
//! The test env var `ROUTINE_FIRE_TEST_SKIP_LLM=1` short-circuits the
//! LLM emit so the test can run without the `nalar` singleton being
//! initialized. The production code path (the `event_bus.emit` to
//! `ai_worker_flow`) is verified in the integration test in Task 3.3.
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
const fire = @import("fire.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the pre-Migration-044 state
/// (`workspace_item_tasks` from Migration 034 + a minimal `llm_history`
/// schema covering the columns `fire.zig` writes + a `sessions` table
/// for the FK + Migration 044). Mirrors the helper in `model_test.zig`
/// but extended with the schemas that `fire.zig` touches.
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

    // Mirror the state left by Migration 034 (workspace_item_tasks).
    // The `session_id` column is nullable and Migration 044 doesn't
    // add it — but the fire pipeline sets it, so include it.
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

    // The `saveMessage` function (called by `fire.zig`) inserts into
    // `llm_history` with the full column list. Provide the minimum
    // set the test queries (`id`, `session_id`, `role`,
    // `response_content`, `created_at`) and the rest as nullable
    // columns. `saveMessage` will write to ALL of them, so every
    // column the production code touches must exist.
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

    // `saveMessage` also UPDATEs `sessions.cwd` for the session —
    // a minimal schema with the columns it touches.
    try db.exec(alloc,
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, cwd TEXT, selected_profile_model TEXT, created_at TEXT, updated_at TEXT)",
        &.{});

    try Migration044AddRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Build a `std.process.Environ.Map` containing
/// `ROUTINE_FIRE_TEST_SKIP_LLM=1` and pass it to the body. The fire
/// pipeline short-circuits to `FakeLLMSuccess` when this env var is
/// set, so the test can exercise the message-insert + state-mutation
/// paths without initializing the LLM singleton. The env is
/// thread-local (per `Environ.Map`), so there's no process-wide
/// state to restore.
fn withSkipLlmEnv(body: *const fn (env: *const std.process.Environ.Map) anyerror!void) !void {
    const alloc = testing.allocator;
    var map = std.process.Environ.Map.init(alloc);
    defer map.deinit();
    try map.put("ROUTINE_FIRE_TEST_SKIP_LLM", "1");
    try body(&map);
}

/// Run a single-column SELECT and parse the first row's first column
/// as an i64. Returns 0 when the query produces no rows.
fn scalarI64(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) !i64 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    const row = (try q.next()) orelse return 0;
    defer row.deinit(alloc);
    return try std.fmt.parseInt(i64, row.values[0], 10);
}

// ─── Test 1: happy path (inserts 🔁 user-style message) ──────────────────

test "fireRoutine inserts a user-style 🔁 message into the session" {
    try withSkipLlmEnv(struct {
        fn run(env: *const std.process.Environ.Map) !void {
            const alloc = testing.allocator;
            var ctx = try setupDb();
            defer ctx.db.deinit();
            defer ctx.threaded.deinit();

            // Parent task + routine row, with a next_run_at well in the
            // past so `listDueRoutineIds` would consider it due. (The
            // claim path doesn't read next_run_at, but a realistic
            // starting state makes the test self-documenting.)
            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'Daily', 'wi1', 't1')",
                &.{});
            try model.insertRoutine(alloc, &ctx.db, .{
                .id = "r1",
                .task_id = "t1",
                .schedule = "0 9 * * *",
                .initial_prompt = "summarize commits",
                .enabled = true,
                .next_run_at = "2000-01-01 00:00:00",
            });

            // With the env var set, the function should return
            // FakeLLMSuccess (a test-only sentinel) without invoking
            // the LLM worker pipeline.
            const err = fire.fireRoutine(alloc, &ctx.db, ctx.threaded.io(), env, "t1") catch |e| e;
            try testing.expectEqual(fire.FireError.FakeLLMSuccess, err);

            // The 🔁 user-style message must have been inserted into
            // the session BEFORE the (skipped) LLM emit. Read it back
            // via the Row API (NOT the invented `db.prepare`/etc.).
            var q = try ctx.db.query(alloc,
                "SELECT response_content, role FROM llm_history WHERE session_id = 't1' ORDER BY created_at DESC LIMIT 1",
                &.{});
            defer q.deinit();
            const row = (try q.next()) orelse return error.TestFailed;
            defer row.deinit(alloc);
            try testing.expect(std.mem.indexOf(u8, row.values[0], "🔁") != null);
            try testing.expect(std.mem.indexOf(u8, row.values[0], "summarize commits") != null);
            try testing.expectEqualStrings("user", row.values[1]);
        }
    }.run);
}

// ─── Test 2: atomic claim (second fire returns AlreadyRunning) ────────────

test "fireRoutine rejects a second concurrent fire (atomic claim)" {
    try withSkipLlmEnv(struct {
        fn run(env: *const std.process.Environ.Map) !void {
            const alloc = testing.allocator;
            var ctx = try setupDb();
            defer ctx.db.deinit();
            defer ctx.threaded.deinit();

            try ctx.db.exec(alloc,
                "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')",
                &.{});
            try model.insertRoutine(alloc, &ctx.db, .{
                .id = "r1",
                .task_id = "t1",
                .schedule = "*/5 * * * *",
                .initial_prompt = "x",
                .enabled = true,
                .next_run_at = "2000-01-01 00:00:00",
            });
            // Pre-claim the row by setting last_status to 'running'.
            // `claimForRun` (called inside `fireRoutine`) is an
            // atomic UPDATE that excludes already-running rows, so
            // it will return false and `fireRoutine` will return
            // `AlreadyRunning` without doing any other work.
            try ctx.db.exec(alloc, "UPDATE routines SET last_status = 'running' WHERE id = 'r1'", &.{});

            const err = fire.fireRoutine(alloc, &ctx.db, ctx.threaded.io(), env, "t1") catch |e| e;
            try testing.expectEqual(fire.FireError.AlreadyRunning, err);

            // The 🔁 message must NOT have been inserted (the claim
            // failed before the insert).
            const count = try scalarI64(alloc, &ctx.db,
                "SELECT COUNT(*) FROM llm_history WHERE session_id = 't1'", &.{});
            try testing.expectEqual(@as(i64, 0), count);
        }
    }.run);
}

// ─── Test 3: task with no routine row returns NotARoutine ────────────────

test "fireRoutine on a non-routine task returns NotARoutine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Parent task exists, but no `routines` row references it.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')",
        &.{});

    // No env-var short-circuit (null is fine — the load fails
    // before the env-var check).
    const err = fire.fireRoutine(alloc, &ctx.db, ctx.threaded.io(), null, "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.NotARoutine, err);
}

// ─── Test 4: disabled routine returns Disabled ───────────────────────────

test "fireRoutine on a disabled routine returns Disabled" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id, session_id) VALUES ('t1', 'A', 'wi1', 't1')",
        &.{});
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "*/5 * * * *",
        .initial_prompt = "x",
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });

    // No env-var short-circuit (null is fine — the disabled check
    // runs before the env-var check).
    const err = fire.fireRoutine(alloc, &ctx.db, ctx.threaded.io(), null, "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.Disabled, err);

    // The 🔁 message must NOT have been inserted (the disabled
    // short-circuit returns before the claim).
    const count = try scalarI64(alloc, &ctx.db,
        "SELECT COUNT(*) FROM llm_history WHERE session_id = 't1'", &.{});
    try testing.expectEqual(@as(i64, 0), count);
}

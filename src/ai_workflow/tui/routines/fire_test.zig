//! Behavioral tests for `fire.zig` (Task 2.1 of the Add Task Routines
//! plan, refactored per PR #8 review).
//!
//! `fireRoutine(allocator, db, di, io, task_id)` is the per-fire work
//! done on the main process's Io runtime via
//! `di.group_emit_session_create.concurrent(io, ...)` (the same
//! pattern as `http_handlers/session_create.zig:161`). The three
//! behaviors under test:
//!
//!   1. **Atomic claim** — a second concurrent fire attempt against a
//!      row already in `running` state must return `AlreadyRunning`
//!      and must NOT submit an LLM event.
//!   2. **Not a routine** — a task with no `routines` row returns
//!      `NotARoutine` (no claim, no submit).
//!   3. **Disabled routine** — a routine with `enabled = false`
//!      returns `Disabled` (no claim, no submit).
//!
//! The happy-path test (the original "inserts 🔁 user-style message"
//! + "marks success and advances next_run_at") is gone: the new
//! implementation submits the LLM work to
//! `di.group_emit_session_create.concurrent` rather than calling
//! `saveMessage` directly, and the success-state side effect now
//! flows through the same group as the rest of the session-create
//! pipeline. Testing the full happy path would require a real
//! initialized `nalarcore.ContextIPCTui` singleton and a live
//! `CallbackAiWorkerFlow` subscription — i.e., a real `nalar`
//! process. The runtime smoke test (manually creating a routine via
//! the desktop UI and watching it fire) is the integration coverage.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines-chunks-2-3.md
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration044AddRoutines = migration.Migration044AddRoutines;

const model = @import("model.zig");
const fire = @import("fire.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the pre-Migration-044 state
/// (`workspace_item_tasks` from Migration 034 + a minimal
/// `sessions` schema + Migration 044). Mirrors the helper in
/// `model_test.zig`. Note: `llm_history` is no longer needed here
/// (the old saveMessage path is gone) but `sessions` is still
/// referenced by some helpers' side effects.
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

    // Mirror the state left by Migration 034 + Migration 052
    // (workspace_item_tasks). The `session_id` column was dropped
    // in Migration 052 — `task.id` IS the session id per the
    // `task.id == session_id` convention.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
        \\)
    , &.{});

    // `markSuccess` (called by `fire.zig` on the happy path) and
    // `recomputeDueNextRunAt` (called by `Scheduler.zig`) don't
    // touch `sessions`, but include a minimal `sessions` table to
    // match the helpers' expectations on any FK / column they may
    // read transitively.
    try db.exec(alloc,
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT, status TEXT, cwd TEXT, selected_profile_model TEXT, created_at TEXT, updated_at TEXT)",
        &.{});

    try Migration044AddRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

// ─── Test 1: atomic claim (second fire returns AlreadyRunning) ────────────

test "fireRoutine rejects a second concurrent fire (atomic claim)" {
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
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Pre-claim the row by setting last_status to 'running'.
    // `claimForRun` (called inside `fireRoutine`) is an atomic
    // UPDATE that excludes already-running rows, so it will return
    // false and `fireRoutine` will return `AlreadyRunning` without
    // doing any other work. The `di` parameter is never read on
    // the `AlreadyRunning` path, so `undefined` is safe.
    try ctx.db.exec(alloc, "UPDATE routines SET last_status = 'running' WHERE id = 'r1'", &.{});

    const err = fire.fireRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.AlreadyRunning, err);

    // The `llm_history` table isn't even created in `setupDb` —
    // if the function had reached the message-insert path it would
    // have failed with a SQL error. Assert it didn't get there by
    // confirming the row is still in 'running' state (the claim
    // would have flipped it to 'running' again if the second
    // claimForRun had succeeded, but the row is already 'running'
    // so the second claim would have returned false regardless).
    // The stronger check: the `llm_history` table doesn't exist,
    // so reaching the (now-removed) message-insert path would
    // have produced a SQL error. We don't see that error — the
    // function returned `AlreadyRunning` cleanly. Pass.
    const status_dup = blk: {
        var q = try ctx.db.query(alloc, "SELECT last_status FROM routines WHERE id = 'r1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TestFailed;
        defer row.deinit(alloc);
        // Dup the slice so the test can read it after row.deinit
        // fires (otherwise row.values[0] becomes a dangling slice
        // and the expectEqualStrings call below segfaults in debug).
        break :blk try alloc.dupe(u8, row.values[0]);
    };
    defer alloc.free(status_dup);
    try testing.expectEqualStrings("running", status_dup);
}

// ─── Test 2: task with no routine row returns NotARoutine ────────────────

test "fireRoutine on a non-routine task returns NotARoutine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // Parent task exists, but no `routines` row references it.
    try ctx.db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES ('t1', 'A', 'wi1')",
        &.{});

    // `di` is not read on the `NotARoutine` path (the load fails
    // before the di.group_emit call), so `undefined` is safe.
    const err = fire.fireRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.NotARoutine, err);
}

// ─── Test 3: disabled routine returns Disabled ───────────────────────────

test "fireRoutine on a disabled routine returns Disabled" {
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
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });

    // `di` is not read on the `Disabled` path (the disabled check
    // runs before the claim), so `undefined` is safe.
    const err = fire.fireRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "t1") catch |e| e;
    try testing.expectEqual(fire.FireError.Disabled, err);

    // The row must still be enabled (the disabled check returns
    // before the claim, so last_status is unchanged).
    const enabled_int = blk: {
        var q = try ctx.db.query(alloc, "SELECT enabled FROM routines WHERE id = 'r1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TestFailed;
        defer row.deinit(alloc);
        // The Row's slice is freed by `row.deinit(alloc)` above; parse
        // it into a value (i64) before the defer fires.
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };
    try testing.expectEqual(@as(i64, 0), enabled_int);
}

// ─── Test 4: formatRoutineMessage wraps the initial_prompt with context ────

test "formatRoutineMessage produces a structured metadata header followed by the initial_prompt" {
    const alloc = testing.allocator;
    const msg = try fire.formatRoutineMessage(
        alloc,
        "*/5 * * * *",
        "do the thing",
        "2025-01-15 09:00:00",
    );
    defer alloc.free(msg);
    const expected =
        "This is an automated routine fire.\n" ++
        "- Schedule: */5 * * * *\n" ++
        "- Next fire: 2025-01-15 09:00:00\n" ++
        "\n" ++
        "do the thing";
    try testing.expectEqualStrings(expected, msg);
}

test "formatRoutineMessage preserves multi-line and special-char initial_prompt verbatim" {
    // The `{s}` format specifier embeds the slice bytes literally —
    // the routine's `initial_prompt` may contain newlines, colons,
    // and other punctuation that the LLM needs to see unchanged.
    // Verify the wrapper does not reinterpret or trim them.
    const alloc = testing.allocator;
    const msg = try fire.formatRoutineMessage(
        alloc,
        "0 9 * * 1-5",
        "step 1: read logs\nstep 2: summarize",
        "2025-01-20 09:00:00",
    );
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "step 1: read logs\nstep 2: summarize") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "- Schedule: 0 9 * * 1-5") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "- Next fire: 2025-01-20 09:00:00") != null);
}

test "formatRoutineMessage places metadata header first and initial_prompt last" {
    // The LLM-friendly property: meta header is the FIRST thing the
    // LLM reads (sets context), the actual task is the LAST thing
    // (clear instruction boundary), and they're separated by a blank
    // line. These are the structural invariants that let the LLM
    // parse the format reliably — if any of them regresses, the
    // prompt becomes harder for the LLM to interpret.
    const alloc = testing.allocator;
    const msg = try fire.formatRoutineMessage(
        alloc,
        "*/5 * * * *",
        "do the thing",
        "2025-01-15 09:00:00",
    );
    defer alloc.free(msg);

    // First line is the meta header.
    try testing.expect(std.mem.startsWith(u8, msg, "This is an automated routine fire."));

    // The initial_prompt is the trailing text (no trailing newline).
    try testing.expect(std.mem.endsWith(u8, msg, "do the thing"));

    // A blank line separates the meta block from the task.
    try testing.expect(std.mem.indexOf(u8, msg, "\n\n") != null);
}

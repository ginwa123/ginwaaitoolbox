//! Behavioral tests for the `routines` model (Task 1.2 of the Add Task
//! Routines plan).
//!
//! The model exposes a `Routine` struct (the in-memory representation of
//! a row in the `routines` table) and five DB helpers:
//!
//!   - `insertRoutine`     — INSERT a new row
//!   - `loadRoutineByTaskId` — SELECT one row by `task_id`
//!   - `listDueRoutineIds` — SELECT ids of due + enabled + not-already-
//!                           running routines (the Scheduler hot read path)
//!   - `claimForRun`       — atomic transition last_status=NULL|success|failed
//!                           → 'running' (returns true iff the claim won)
//!   - `markSuccess`       — set last_status='success' and bump next_run_at
//!
//! These tests use the in-process `:memory:` sqlite pattern from
//! `migration_routines_test.zig`. The actual SqliteBackend API is
//! `db.query(alloc, sql, args) → Rows → next() → ?Row{ values: [][]u8 }`.
//! Column reads go through `row.values[i]` directly (a `[]u8` text slice,
//! the empty string for NULLs); there is no `.scalar` accessor in this
//! codebase.
//!
//! Plan: docs/superpowers/plans/2026-06-13-add-task-routines.md (Task 1.2)
//! Design: docs/plans/2026-06-13-add-task-routines-design.md

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration044AddRoutines = migration.Migration044AddRoutines;

const model = @import("model.zig");
const Routine = model.Routine;
const RoutineRunStatus = model.RoutineRunStatus;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the pre-Migration-044 state
/// (`workspace_item_tasks` table from Migration 034), then run Migration
/// 044 to bring it to the post-migration state. Mirrors the helper in
/// `migration_routines_test.zig` exactly.
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

    // Mirror the state left by Migration 034 EXACTLY (no task_type
    // column — that's what Migration 044 adds via ALTER TABLE). This
    // is the schema the model expects after the migration runs.
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

    try Migration044AddRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Run a single-column SELECT and return a duplicated copy of the
/// first row's first column. Returns null when the query produces no
/// rows. Mirrors the helper in `migration_routines_test.zig`.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

/// Insert a workspace_item_tasks row with the given id. The `routines`
/// table has a FOREIGN KEY (task_id) REFERENCES workspace_item_tasks(id),
/// so parent rows must exist before child rows can be inserted.
fn insertParentTask(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_item_tasks (id, name, workspace_item_id) VALUES (?, 'parent', 'wi1')",
        &.{id});
}

// ─── Test 1: insert + load round-trip ─────────────────────────────────────

test "Routine: insert + load round-trip" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentTask(&ctx.db, alloc, "t1");

    const inserted = Routine{
        .id = "r1",
        .task_id = "t1",
        .schedule = "*/5 * * * *",
        .initial_prompt = "do the thing",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    };
    try model.insertRoutine(alloc, &ctx.db, inserted);

    var loaded = try model.loadRoutineByTaskId(alloc, &ctx.db, "t1");
    defer loaded.deinit(alloc);

    try testing.expectEqualStrings("r1", loaded.id);
    try testing.expectEqualStrings("t1", loaded.task_id);
    try testing.expectEqualStrings("*/5 * * * *", loaded.schedule);
    try testing.expectEqualStrings("do the thing", loaded.initial_prompt);
    try testing.expect(loaded.enabled);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at);
    // Nullable fields on a freshly-inserted row are NULL.
    try testing.expect(loaded.last_run_at == null);
    try testing.expectEqual(RoutineRunStatus.idle, loaded.last_status);
    try testing.expect(loaded.last_error == null);
    // created_at + updated_at are auto-populated by CURRENT_TIMESTAMP
    // defaults, so they should be non-null.
    try testing.expect(loaded.created_at != null);
    try testing.expect(loaded.updated_at != null);
}

// ─── Test 2: listDueRoutineIds filters correctly ──────────────────────────

test "Routine: listDueRoutineIds returns only enabled with next_run_at <= now" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentTask(&ctx.db, alloc, "t1");
    try insertParentTask(&ctx.db, alloc, "t2");
    try insertParentTask(&ctx.db, alloc, "t3");

    // Routine A: enabled=1, next_run_at past → DUE
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r_due",
        .task_id = "t1",
        .schedule = "* * * * *",
        .initial_prompt = "a",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Routine B: enabled=1, next_run_at in the future → NOT DUE
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r_future",
        .task_id = "t2",
        .schedule = "* * * * *",
        .initial_prompt = "b",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Routine C: enabled=0 (disabled), next_run_at past → NOT DUE
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r_disabled",
        .task_id = "t3",
        .schedule = "* * * * *",
        .initial_prompt = "c",
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });

    const due = try model.listDueRoutineIds(alloc, &ctx.db, "2025-01-01 00:00:00");
    defer {
        for (due) |id| alloc.free(id);
        alloc.free(due);
    }

    try testing.expectEqual(@as(usize, 1), due.len);
    // Returns task_id (matches fire.fireRoutine's parameter) — the
    // routine id would make loadRoutineByTaskId silently miss every row.
    try testing.expectEqualStrings("t1", due[0]);
}

// ─── Test 3: claimForRun is atomic (first wins, second loses) ─────────────

test "Routine: claimForRun atomically transitions to running" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentTask(&ctx.db, alloc, "t1");
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "* * * * *",
        .initial_prompt = "a",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    const first = try model.claimForRun(alloc, &ctx.db, "r1");
    try testing.expect(first);

    // A second claim on the same id must fail because last_status is
    // now 'running' (the WHERE clause excludes already-running rows).
    const second = try model.claimForRun(alloc, &ctx.db, "r1");
    try testing.expect(!second);

    // Sanity-check the row was actually updated.
    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM routines WHERE id = 'r1'", &.{});
    defer if (status) |s| alloc.free(s);
    try testing.expect(status != null);
    try testing.expectEqualStrings("running", status.?);
}

// ─── Test 4: markSuccess updates last_status and next_run_at ─────────────

test "Routine: markSuccess updates last_status and next_run_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentTask(&ctx.db, alloc, "t1");
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "* * * * *",
        .initial_prompt = "a",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Claim it first (markSuccess is normally called after a successful run).
    _ = try model.claimForRun(alloc, &ctx.db, "r1");

    try model.markSuccess(alloc, &ctx.db, "r1", "2099-01-01 00:00:00");

    var loaded = try model.loadRoutineByTaskId(alloc, &ctx.db, "t1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(RoutineRunStatus.success, loaded.last_status);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at);
    // last_run_at is set to datetime('now') — just assert non-null.
    try testing.expect(loaded.last_run_at != null);
    // last_error is cleared on success.
    try testing.expect(loaded.last_error == null);
}

// ─── Test 5: RoutineRunStatus enum mapping (pure unit test, no DB) ───────

test "RoutineRunStatus enum mapping" {
    // .dbValue() — the canonical strings written to the DB column.
    try testing.expectEqualStrings("success", RoutineRunStatus.success.dbValue().?);
    try testing.expectEqualStrings("failed", RoutineRunStatus.failed.dbValue().?);
    try testing.expectEqualStrings("running", RoutineRunStatus.running.dbValue().?);
    // .idle maps to NULL — .dbValue() returns null, not a string.
    try testing.expect(RoutineRunStatus.idle.dbValue() == null);

    // .fromDb() — round-trip every value.
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb(null));
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb(""));
    try testing.expectEqual(RoutineRunStatus.success, RoutineRunStatus.fromDb("success"));
    try testing.expectEqual(RoutineRunStatus.failed, RoutineRunStatus.fromDb("failed"));
    try testing.expectEqual(RoutineRunStatus.running, RoutineRunStatus.fromDb("running"));
    // Unknown string → .idle (defensive default).
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb("bogus"));
}

// ─── Test 6: markFailed sets last_status=failed, last_error, and advances next_run_at ───

test "Routine: markFailed sets last_status=failed and last_error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentTask(&ctx.db, alloc, "t1");
    try model.insertRoutine(alloc, &ctx.db, .{
        .id = "r1",
        .task_id = "t1",
        .schedule = "*/5 * * * *",
        .initial_prompt = "x",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    try model.markFailed(alloc, &ctx.db, "r1", "LLM rate limit", "2099-01-01 00:00:00");

    var loaded = try model.loadRoutineByTaskId(alloc, &ctx.db, "t1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(RoutineRunStatus.failed, loaded.last_status);
    try testing.expectEqualStrings("LLM rate limit", loaded.last_error.?);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at);
    // Routine should STAY enabled (a transient failure must not silently
    // disable a recurring job — the user disables it explicitly).
    try testing.expect(loaded.enabled);
}

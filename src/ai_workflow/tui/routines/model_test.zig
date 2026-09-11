//! Behavioral tests for the `workspace_routines` model (Task 3 of
//! the workspace-items-routines plan).
//!
//! The model exposes a `Routine` struct (the in-memory representation of
//! a row in the `workspace_routines` table) and five DB helpers:
//!
//!   - `insertWorkspaceRoutine` — INSERT a new row
//!   - `loadWorkspaceRoutineById` — SELECT one row by `id`
//!   - `listDueWorkspaceRoutineIds` — SELECT ids of due + enabled +
//!     not-already-running routines (the Scheduler hot read path)
//!   - `claimForRun` — atomic transition last_status → 'running'
//!     (returns true iff the claim won)
//!   - `markSuccess` — set last_status='success' and bump next_run_at
//!
//! These tests use the in-process `:memory:` sqlite pattern. The actual
//! SqliteBackend API is `db.query(alloc, sql, args) → Rows → next() →
//! ?Row{ values: [][]u8 }`. Column reads go through `row.values[i]`
//! directly (a `[]u8` text slice, the empty string for NULLs); there
//! is no `.scalar` accessor in this codebase.
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;

const model = @import("model.zig");
const Routine = model.Routine;
const RoutineRunStatus = model.RoutineRunStatus;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables,
/// then run Migration 084 to bring it to the post-migration state.
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

    // Migration 084's UPDATE touches workspace_item_tasks, and the
    // FK references workspace_items — both must exist.
    try db.exec(alloc,
        \\CREATE TABLE workspace_item_tasks (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    workspace_item_id TEXT NOT NULL,
        \\    task_type TEXT NOT NULL DEFAULT 'standard'
        \\)
    , &.{});
    try db.exec(alloc,
        \\CREATE TABLE workspace_items (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT,
        \\    item_type TEXT NOT NULL
        \\)
    , &.{});

    try Migration084ReplaceRoutinesWithWorkspaceRoutines.up(&db, alloc);

    return .{ .db = db, .threaded = threaded };
}

/// Run a single-column SELECT and return a duplicated copy of the
/// first row's first column. Returns null when the query produces no
/// rows.
fn scalarText(alloc: std.mem.Allocator, db: *sqlite.SqliteBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

/// Insert a parent workspace_item row. The `workspace_routines` table
/// has a FOREIGN KEY (workspace_item_id) REFERENCES
/// workspace_items(id), so parent rows must exist before child rows
/// can be inserted (when FK enforcement is on).
fn insertParentItem(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')",
        &.{id});
}

// ─── Test 1: insert + load round-trip ─────────────────────────────────────

test "Routine: insert + load round-trip" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");

    const inserted = Routine{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "do the thing",
        .schedule = "*/5 * * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    };
    try model.insertWorkspaceRoutine(alloc, &ctx.db, inserted);

    var loaded = try model.loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqualStrings("item_1", loaded.id);
    try testing.expectEqualStrings("item_1", loaded.workspace_item_id);
    try testing.expectEqualStrings("*/5 * * * *", loaded.schedule);
    try testing.expectEqualStrings("do the thing", loaded.instruction);
    try testing.expect(loaded.enabled);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at.?);
    // Nullable fields on a freshly-inserted row are NULL.
    try testing.expect(loaded.last_run_at == null);
    try testing.expectEqual(RoutineRunStatus.idle, loaded.last_status);
    try testing.expect(loaded.last_error == null);
    // created_at + updated_at are auto-populated by CURRENT_TIMESTAMP
    // defaults, so they should be non-null.
    try testing.expect(loaded.created_at != null);
    try testing.expect(loaded.updated_at != null);
}

// ─── Test 2: listDueWorkspaceRoutineIds filters correctly ────────────────

test "Routine: listDueWorkspaceRoutineIds returns only enabled with next_run_at <= now" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try insertParentItem(&ctx.db, alloc, "item_2");
    try insertParentItem(&ctx.db, alloc, "item_3");
    try insertParentItem(&ctx.db, alloc, "item_4");

    // Routine A: enabled=1, next_run_at past → DUE
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "a",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Routine B: enabled=1, next_run_at in the future → NOT DUE
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_2",
        .workspace_item_id = "item_2",
        .instruction = "b",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2099-01-01 00:00:00",
    });
    // Routine C: enabled=0 (disabled), next_run_at past → NOT DUE
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_3",
        .workspace_item_id = "item_3",
        .instruction = "c",
        .schedule = "* * * * *",
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Routine D: manual-only (NULL next_run_at) → NOT DUE
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_4",
        .workspace_item_id = "item_4",
        .instruction = "d",
        .schedule = "",
        .enabled = true,
        .next_run_at = null,
    });

    const due = try model.listDueWorkspaceRoutineIds(alloc, &ctx.db, "2025-01-01 00:00:00");
    defer {
        for (due) |id| alloc.free(id);
        alloc.free(due);
    }

    try testing.expectEqual(@as(usize, 1), due.len);
    try testing.expectEqualStrings("item_1", due[0]);
}

// ─── Test 3: claimForRun is atomic (first wins, second loses) ─────────────

test "Routine: claimForRun atomically transitions to running" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "a",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    const first = try model.claimForRun(alloc, &ctx.db, "item_1");
    try testing.expect(first);

    // A second claim on the same id must fail because last_status is
    // now 'running' (the WHERE clause excludes already-running rows).
    const second = try model.claimForRun(alloc, &ctx.db, "item_1");
    try testing.expect(!second);

    // Sanity-check the row was actually updated.
    const status = try scalarText(alloc, &ctx.db,
        "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
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

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "a",
        .schedule = "* * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });
    // Claim it first (markSuccess is normally called after a successful run).
    _ = try model.claimForRun(alloc, &ctx.db, "item_1");

    try model.markSuccess(alloc, &ctx.db, "item_1", "2099-01-01 00:00:00");

    var loaded = try model.loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(RoutineRunStatus.success, loaded.last_status);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at.?);
    // last_run_at is set to datetime('now') — just assert non-null.
    try testing.expect(loaded.last_run_at != null);
    // last_error is cleared on success.
    try testing.expect(loaded.last_error == null);
}

// ─── Test 5: RoutineRunStatus enum mapping (pure unit test, no DB) ───────

test "RoutineRunStatus enum mapping" {
    // .dbValue() — the canonical strings written to the DB column.
    try testing.expectEqualStrings("idle", RoutineRunStatus.idle.dbValue());
    try testing.expectEqualStrings("success", RoutineRunStatus.success.dbValue());
    try testing.expectEqualStrings("failed", RoutineRunStatus.failed.dbValue());
    try testing.expectEqualStrings("running", RoutineRunStatus.running.dbValue());

    // .fromDb() — round-trip every value.
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb(null));
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb(""));
    try testing.expectEqual(RoutineRunStatus.idle, RoutineRunStatus.fromDb("idle"));
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

    try insertParentItem(&ctx.db, alloc, "item_1");
    try model.insertWorkspaceRoutine(alloc, &ctx.db, .{
        .id = "item_1",
        .workspace_item_id = "item_1",
        .instruction = "x",
        .schedule = "*/5 * * * *",
        .enabled = true,
        .next_run_at = "2000-01-01 00:00:00",
    });

    try model.markFailed(alloc, &ctx.db, "item_1", "LLM rate limit", "2099-01-01 00:00:00");

    var loaded = try model.loadWorkspaceRoutineById(alloc, &ctx.db, "item_1");
    defer loaded.deinit(alloc);

    try testing.expectEqual(RoutineRunStatus.failed, loaded.last_status);
    try testing.expectEqualStrings("LLM rate limit", loaded.last_error.?);
    try testing.expectEqualStrings("2099-01-01 00:00:00", loaded.next_run_at.?);
    // Routine should STAY enabled (a transient failure must not silently
    // disable a recurring job — the user disables it explicitly).
    try testing.expect(loaded.enabled);
}

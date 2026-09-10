//! Behavioral tests for `fire.zig` (Task 3 of the
//! workspace-items-routines plan).
//!
//! `fireWorkspaceRoutine(allocator, db, di, io, routine_id)` is the
//! per-fire work done on the main process's Io runtime via
//! `di.group_emit_session_create.concurrent(io, ...)` (the same
//! pattern as `http_handlers/session_create.zig:161`). The three
//! behaviors under test:
//!
//!   1. **Atomic claim** — a second concurrent fire attempt against a
//!      row already in `running` state must return `AlreadyRunning`
//!      and must NOT submit an LLM event.
//!   2. **Not a routine** — an id with no `workspace_routines` row
//!      returns `NotARoutine` (no claim, no submit).
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
//! process. The runtime smoke test (manually firing a routine via
//! the desktop UI and watching it run) is the integration coverage.
//!
//! Plan: docs/superpowers/plans/2026-09-10-workspace-items-routines.md (Task 3)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;

const migration = nalarcore.migrations_mod.migration;
const Migration084ReplaceRoutinesWithWorkspaceRoutines = migration.Migration084ReplaceRoutinesWithWorkspaceRoutines;

const model = @import("model.zig");
const fire = @import("fire.zig");

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Open a fresh in-memory sqlite DB with the minimal parent tables,
/// then run Migration 084. Mirrors the helper in `model_test.zig`.
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

fn insertParentItem(db: *sqlite.SqliteBackend, alloc: std.mem.Allocator, id: []const u8) !void {
    try db.exec(alloc,
        "INSERT INTO workspace_items (id, workspace_id, item_type) VALUES (?, 'ws1', 'routine')",
        &.{id});
}

// ─── Test 1: atomic claim (second fire returns AlreadyRunning) ────────────

test "fireWorkspaceRoutine rejects a second concurrent fire (atomic claim)" {
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
    // Pre-claim the row by setting last_status to 'running'.
    // `claimForRun` (called inside `fireWorkspaceRoutine`) is an atomic
    // UPDATE that excludes already-running rows, so it will return
    // false and `fireWorkspaceRoutine` will return `AlreadyRunning`
    // without doing any other work. The `di` parameter is never read
    // on the `AlreadyRunning` path, so `undefined` is safe.
    try ctx.db.exec(alloc, "UPDATE workspace_routines SET last_status = 'running' WHERE id = 'item_1'", &.{});

    const err = fire.fireWorkspaceRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "item_1") catch |e| e;
    try testing.expectEqual(fire.FireError.AlreadyRunning, err);

    const status_dup = blk: {
        var q = try ctx.db.query(alloc, "SELECT last_status FROM workspace_routines WHERE id = 'item_1'", &.{});
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

// ─── Test 2: id with no routine row returns NotARoutine ───────────────────

test "fireWorkspaceRoutine on a non-routine id returns NotARoutine" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.db.deinit();
    defer ctx.threaded.deinit();

    // `di` is not read on the `NotARoutine` path (the load fails
    // before the di.group_emit call), so `undefined` is safe.
    const err = fire.fireWorkspaceRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "nope") catch |e| e;
    try testing.expectEqual(fire.FireError.NotARoutine, err);
}

// ─── Test 3: disabled routine returns Disabled ───────────────────────────

test "fireWorkspaceRoutine on a disabled routine returns Disabled" {
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
        .enabled = false,
        .next_run_at = "2000-01-01 00:00:00",
    });

    // `di` is not read on the `Disabled` path (the disabled check
    // runs before the claim), so `undefined` is safe.
    const err = fire.fireWorkspaceRoutine(alloc, &ctx.db, undefined, ctx.threaded.io(), "item_1") catch |e| e;
    try testing.expectEqual(fire.FireError.Disabled, err);

    // The row must still be disabled (the disabled check returns
    // before the claim, so last_status is unchanged).
    const enabled_int = blk: {
        var q = try ctx.db.query(alloc, "SELECT enabled FROM workspace_routines WHERE id = 'item_1'", &.{});
        defer q.deinit();
        const row = (try q.next()) orelse return error.TestFailed;
        defer row.deinit(alloc);
        // The Row's slice is freed by `row.deinit(alloc)` above; parse
        // it into a value (i64) before the defer fires.
        break :blk try std.fmt.parseInt(i64, row.values[0], 10);
    };
    try testing.expectEqual(@as(i64, 0), enabled_int);
}

// ─── Test 4: formatRoutineMessage wraps the instruction with context ──────

test "formatRoutineMessage produces a structured metadata header followed by the instruction" {
    const alloc = testing.allocator;
    const msg = try fire.formatRoutineMessage(
        alloc,
        "*/5 * * * *",
        "do the thing",
        "2025-01-15 09:00:00",
    );
    defer alloc.free(msg);
    const expected =
        "This is an automated workspace-routine fire.\n" ++
        "- Schedule: */5 * * * *\n" ++
        "- Next fire: 2025-01-15 09:00:00\n" ++
        "\n" ++
        "do the thing";
    try testing.expectEqualStrings(expected, msg);
}

test "formatRoutineMessage preserves multi-line and special-char instruction verbatim" {
    // The `{s}` format specifier embeds the slice bytes literally —
    // the routine's `instruction` may contain newlines, colons,
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

test "formatRoutineMessage places metadata header first and instruction last" {
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
    try testing.expect(std.mem.startsWith(u8, msg, "This is an automated workspace-routine fire."));

    // The instruction is the trailing text (no trailing newline).
    try testing.expect(std.mem.endsWith(u8, msg, "do the thing"));

    // A blank line separates the meta block from the task.
    try testing.expect(std.mem.indexOf(u8, msg, "\n\n") != null);
}

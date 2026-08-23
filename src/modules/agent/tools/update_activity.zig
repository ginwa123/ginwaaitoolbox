const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// update_activity tool - Updates the agent's current thinking/thought activity
/// This is used to share internal reasoning with other agents without generating a response
pub const UpdateActivityInput = struct {
    /// The current thought or thinking process to record as activity
    thought: []const u8,
};

pub const update_activity_tool = AgentTool{
    .type = "function",
    .function = AgentToolFunction{
        .name = "update_activity",
        .description = "MANDATORY after every LLM response. Update the agent's current thinking, reasoning, or what the agent is currently working on. Always include: timestamp, session_id, current working directory (cwd). If reading files, include the file paths. If writing files, include the file paths. Include reasoning: analyzing, planning, researching, debugging, implementing, testing, reviewing, searching, or coordinating with other agents.",
        .parameters = ToolParameters{
            .type = "object",
            .properties = &.{
                ToolProperty{
                    .name = "thought",
                    .type = "string",
                    .description = "Current thought/reasoning. Always: timestamp, session_id, cwd. If reading/writing files, include paths. Example: \"[2025-01-15 10:30] session_123 @ /project | Reading main.zig | Planning refactor\"",
                },
            },
            .required = &.{"thought"},
        },
    },
};

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<update_activity>
        \\  <updated>false</updated>
        \\  <error>{s}</error>
        \\</update_activity>
    , .{error_msg}) catch "<update_activity><updated>false</updated><error>UnknownError</error></update_activity>";
}

/// Generate success XML response
pub fn xmlSuccess(allocator: std.mem.Allocator, thought: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<update_activity>
        \\  <updated>true</updated>
        \\  <thought>{s}</thought>
        \\</update_activity>
    , .{thought}) catch "<update_activity><updated>true</updated></update_activity>";
}

const nalarcore = @import("nalarcore");
const sqlite = nalarcore.sqlite;
const llm_history = nalarcore.llm_history;
const migration = @import("../../../migrations/migration.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Spin up a fresh in-memory DB, walk ALL migrations from 001 → 073
/// so every table the production server has is present (sessions,
/// worker, llm_history, kanban, session_activity, etc.).
fn setupDb() !TestCtx {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");

    var manager = migration.MigrationManager.init(alloc, &db);
    defer manager.deinit();
    try migration.registerAllMigrations(&manager);
    try manager.runMigrations();

    return .{ .db = db, .threaded = threaded };
}

// ============================================================================
// Migration 073 — recordSessionActivity regression tests
// ============================================================================

test "recordSessionActivity inserts a row into session_activity for the given session_id" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = std.testing.allocator;

    const session_id = "test_session_abc";
    const description = "[2026-08-13 10:00] test @ /test | Thinking | Working on it";

    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, description);

    // Exactly 1 row, with the exact session_id + description.
    var q = try ctx.db.query(alloc,
        "SELECT session_id, description FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings(session_id, row.values[0]);
    try std.testing.expectEqualStrings(description, row.values[1]);

    // No further rows.
    try std.testing.expect((try q.next()) == null);
}

test "recordSessionActivity appends a new row each call (same description -> two rows)" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = std.testing.allocator;

    const session_id = "test_session_xyz";
    const description = "[2026-08-13 10:00] test @ /test | Repeated thought";

    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, description);
    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, description);

    // Exactly 2 rows for this session_id.
    var q = try ctx.db.query(alloc,
        "SELECT COUNT(*) FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings("2", row.values[0]);
}

// ============================================================================
// Task 6 — wiring test: execUpdateActivity must do TWO things on success
// ============================================================================
//
// After Migration 073 lands, `execUpdateActivity` must:
//   (a) UPDATE worker.last_activity_description (existing live-UI behaviour).
//   (b) INSERT into session_activity (new historical log).
//
// This test exercises both helpers in sequence against an in-memory
// DB with both tables present, simulating the two side effects of
// the real tool call.

test "wiring: updateWorkerActivityWithDescription + recordSessionActivity both land on success" {
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();
    const alloc = std.testing.allocator;

    const session_id = "test_session_wiring";
    // Pre-register the worker so updateWorkerActivityWithDescription
    // finds a matching row. Production registers workers with
    // `id = session_id` (see workflow.zig's upsert path).
    try ctx.db.exec(alloc,
        "INSERT INTO worker (id, session_id, working_directory) VALUES (?, ?, ?)",
        &.{ session_id, session_id, "/test/cwd" });

    const thought = "[2026-08-13 10:30] test @ /test | Wiring | Both tables updated";
    try llm_history.updateWorkerActivityWithDescription(alloc, &ctx.db, session_id, thought);
    try llm_history.recordSessionActivity(alloc, ctx.threaded.io(), &ctx.db, session_id, thought);

    // Assert: worker table got the UPDATE (existing behaviour preserved).
    {
        var q = try ctx.db.query(alloc,
            "SELECT last_activity_description FROM worker WHERE id = ?",
            &.{session_id});
        defer q.deinit();
        const row = (try q.next()) orelse return error.WorkerRowMissing;
        defer row.deinit(alloc);
        try std.testing.expectEqualStrings(thought, row.values[0]);
    }

    // Assert: session_activity got the INSERT (new behaviour).
    var q = try ctx.db.query(alloc,
        "SELECT session_id, description FROM session_activity WHERE session_id = ?",
        &.{session_id});
    defer q.deinit();
    const row = (try q.next()) orelse return error.SessionActivityRowMissing;
    defer row.deinit(alloc);
    try std.testing.expectEqualStrings(session_id, row.values[0]);
    try std.testing.expectEqualStrings(thought, row.values[1]);
}

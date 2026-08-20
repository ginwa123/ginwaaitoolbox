//! Live-DB tests for the `session_plan` storage layer
//! (`savePlan`, `getPlan`, `getPlanOpt`, `MAX_PLAN_BYTES`).
//!
//! Mirrors the `agent_memories_test.zig` (now inlined in
//! `agent_memories.zig`) pattern: an in-memory SQLite + full
//! migrations walk so the schema under test is GUARANTEED to match
//! production (no hand-rolled `CREATE TABLE`).
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const session_plan = @import("session_plan.zig");

const TestCtx = struct {
    db: sqlite.SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !TestCtx {
    const alloc = testing.allocator;
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

// ─── Test 1: round-trip save + getPlan returns the same content ──────────

test "savePlan + getPlan round-trip preserves content" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_1";
    {
        const ts = try session_plan.savePlan(allocator, &ctx.db, .{
            .session_id = session_id,
            .content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n",
        });
        defer allocator.free(ts);
    }

    const got = try session_plan.getPlan(allocator, &ctx.db, session_id);
    defer allocator.free(got);
    try testing.expectEqualStrings("# My Plan\n\n- [ ] step 1\n- [x] step 2\n", got);
}

// ─── Test 2: getPlan on missing session returns empty string ─────────────

test "getPlan on missing session returns empty string" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const got = try session_plan.getPlan(allocator, &ctx.db, "nonexistent");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

// ─── Test 3: UPSERT semantics — second save replaces the first ────────────

test "savePlan overwrites existing row (UPSERT semantics)" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const sid = "upsert_test";

    {
        const ts1 = try session_plan.savePlan(allocator, &ctx.db, .{ .session_id = sid, .content = "v1" });
        defer allocator.free(ts1);
        const ts2 = try session_plan.savePlan(allocator, &ctx.db, .{ .session_id = sid, .content = "v2 longer" });
        defer allocator.free(ts2);
    }

    const got = try session_plan.getPlan(allocator, &ctx.db, sid);
    defer allocator.free(got);
    try testing.expectEqualStrings("v2 longer", got);

    // Confirm there is still exactly ONE row in the DB (UPSERT, not
    // INSERT-OR-APPEND).
    var q = try ctx.db.query(allocator,
        "SELECT COUNT(*) FROM session_plan WHERE session_id = ?",
        &.{sid});
    defer q.deinit();
    const row = (try q.next()) orelse return error.RowMissing;
    defer row.deinit(allocator);
    try testing.expectEqualStrings("1", row.values[0]);
}

// ─── Test 4: content > MAX_PLAN_BYTES returns ContentTooLarge ─────────────

test "savePlan rejects content > 256 KiB with ContentTooLarge" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const big = try allocator.alloc(u8, session_plan.MAX_PLAN_BYTES + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    const result = session_plan.savePlan(allocator, &ctx.db, .{
        .session_id = "big", .content = big,
    });
    try testing.expectError(error.ContentTooLarge, result);
}

// ─── Test 5: empty content returns InvalidContent ─────────────────────────

test "savePlan rejects empty content with InvalidContent" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = session_plan.savePlan(allocator, &ctx.db, .{
        .session_id = "empty", .content = "",
    });
    try testing.expectError(error.InvalidContent, result);
}

// ─── Test 6: getPlanOpt — null when absent, populated PlanRow when present

test "getPlanOpt returns null when no row, populated struct when present" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // absent
    const absent = try session_plan.getPlanOpt(allocator, &ctx.db, "nope");
    try testing.expect(absent == null);

    // present
    {
        const ts = try session_plan.savePlan(allocator, &ctx.db, .{ .session_id = "s", .content = "hello" });
        defer allocator.free(ts);
    }
    const present = try session_plan.getPlanOpt(allocator, &ctx.db, "s");
    try testing.expect(present != null);
    if (present) |row| {
        defer row.deinit(allocator);
        try testing.expectEqualStrings("hello", row.plan_md);
        try testing.expect(row.updated_at.len > 0);
    }
}
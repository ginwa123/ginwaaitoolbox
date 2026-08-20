//! Behavioural tests for `update_plan.zig` — the agent-callable tool
//! that UPSERTs the session's markdown plan via `session_plan.savePlan`.
//!
//! Pattern mirrors `save_memory_test.zig` — in-memory DB + full migrations
//! walk + assert on the wire XML envelope (success / error).
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 2 of 9)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");

const update_plan_mod = @import("update_plan.zig");
const session_plan = @import("../../../ai_workflow/tui/agentic_loop/session_plan.zig");

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

// ─── Test 1: success path returns the successXml envelope ──────────────────

test "executeUpdatePlan: success returns successXml with session_id + updated_at" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const session_id = "test_session_success";
    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, session_id, .{
        .content = "# My Plan\n\n- [ ] step 1\n- [x] step 2\n",
    });
    defer alloc.free(result);

    // Envelope shape: <update_plan><session_id>...</session_id><updated_at>...</updated_at></update_plan>
    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<updated_at>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</updated_at>") != null);
    // No <error> tag on success.
    try testing.expect(std.mem.indexOf(u8, result, "<error>") == null);
    // session_id MUST be echoed (escaped form, but plain alphanumeric here).
    try testing.expect(std.mem.indexOf(u8, result, session_id) != null);

    // DB read-back — verify the row actually landed with the right content.
    const stored = try session_plan.getPlan(alloc, &ctx.db, session_id);
    defer alloc.free(stored);
    try testing.expectEqualStrings("# My Plan\n\n- [ ] step 1\n- [x] step 2\n", stored);
}

// ─── Test 2: empty content is rejected with a "non-empty" error ────────────

test "executeUpdatePlan: empty content returns errorXml mentioning 'non-empty'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "any_session", .{
        .content = "",
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "non-empty") != null);
    // No <session_id> or <updated_at> on error.
    try testing.expect(std.mem.indexOf(u8, result, "<updated_at>") == null);

    // DB has no row for "any_session".
    const stored = try session_plan.getPlan(alloc, &ctx.db, "any_session");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// ─── Test 3: oversized content is rejected with a "256 KiB" error ──────────

test "executeUpdatePlan: oversized content (> MAX_PLAN_BYTES) returns errorXml mentioning '256 KiB'" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Allocate MAX_PLAN_BYTES + 1 byte of garbage.
    const big = try alloc.alloc(u8, update_plan_mod.MAX_PLAN_BYTES + 1);
    defer alloc.free(big);
    @memset(big, 'x');

    const result = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "big_session", .{
        .content = big,
    });
    defer alloc.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "<update_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result, "</error>") != null);
    // Exact phrasing is '256 KiB' (per the plan's error mapping).
    try testing.expect(std.mem.indexOf(u8, result, "256 KiB") != null);
}

// ─── Test 4: JSON schema shape (name / required / properties) ──────────────

test "update_plan_tool JSON schema: name='update_plan', required=['content'], properties=[content]" {
    const tool = update_plan_mod.update_plan_tool;

    // Top-level type must be 'function' (OpenAI conventions).
    try testing.expectEqualStrings("function", tool.type);

    // Function name.
    try testing.expectEqualStrings("update_plan", tool.function.name);

    // Description must mention both the tool name and the checklist pattern
    // — the description is the agent's primary "when to call this" signal.
    const description = tool.function.description;
    try testing.expect(std.mem.indexOf(u8, description, "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, description, "checklist") != null);

    // Required: exactly ["content"] — session_id is implicit (D3).
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.required.len);
    try testing.expectEqualStrings("content", tool.function.parameters.required[0]);

    // Properties: exactly one (content) — no session_id parameter.
    try testing.expectEqual(@as(usize, 1), tool.function.parameters.properties.len);
    try testing.expectEqualStrings("content", tool.function.parameters.properties[0].name);
    try testing.expectEqualStrings("string", tool.function.parameters.properties[0].type);
}

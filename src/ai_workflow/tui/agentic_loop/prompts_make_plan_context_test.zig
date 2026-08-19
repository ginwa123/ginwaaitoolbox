//! Live-DB tests for `prompts_make_plan_context.zig` — the helper that
//! renders a `## Current Plan` block into the system prompt.
//
// Mirrors `session_plan_test.zig`'s setup pattern: an in-memory
// SQLite + full migrations walk so `session_plan` is GUARANTEED to
// match production. Each test writes a plan via `executeUpdatePlan`
// (the same fn used by the LLM tool) so we exercise the real
// UPSERT path and not a hand-rolled bypass.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8 (Task 5 of 9)

const std = @import("std");
const testing = std.testing;
const sqlite = @import("nalarcore").sqlite;
const migration = @import("../../../migrations/migration.zig");
const update_plan_mod = @import("../../../modules/agent/tools/update_plan.zig");
const plan_ctx = @import("prompts_make_plan_context.zig");

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

// ─── Test 1: empty plan returns "" (silently omitted from system prompt) ──

test "makePlanContext: empty plan returns empty string (silently omitted)" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // No plan row exists for "no_plan_session" — the helper must
    // gracefully return a 0-byte slice so the caller omits the
    // section from the final system prompt.
    const got = try plan_ctx.makePlanContext(allocator, &ctx.db, "no_plan_session");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}

// ─── Test 2: present plan renders a ## Current Plan markdown block ─────────

test "makePlanContext: present plan renders ## Current Plan markdown block" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed a plan via the same fn the LLM tool calls. We discard
    // the returned XML envelope — we just need the row to exist.
    {
        const xml = try update_plan_mod.executeUpdatePlan(allocator, &ctx.db, "s_present", .{
            .content = "# Goal\n\n- [x] first done\n- [ ] second pending\n- [ ] third pending\n",
        });
        defer allocator.free(xml);
    }

    const got = try plan_ctx.makePlanContext(allocator, &ctx.db, "s_present");
    defer allocator.free(got);

    // Block header
    try testing.expect(std.mem.indexOf(u8, got, "## Current Plan") != null);

    // The LLM-facing hint that names the tool (`update_plan`) and the
    // "every checklist item" call-to-action.
    try testing.expect(std.mem.indexOf(u8, got, "update_plan") != null);
    try testing.expect(std.mem.indexOf(u8, got, "checklist item") != null);

    // The plan content is wrapped in a ```markdown fence so the
    // agent's parser sees it as code, not as instructions
    try testing.expect(std.mem.indexOf(u8, got, "```markdown\n# Goal") != null);
    try testing.expect(std.mem.indexOf(u8, got, "- [x] first done") != null);
    try testing.expect(std.mem.indexOf(u8, got, "- [ ] second pending") != null);

    // Timestamp footer line (Migration 076 populates CURRENT_TIMESTAMP
    // on every UPSERT).
    try testing.expect(std.mem.indexOf(u8, got, "Last updated:") != null);
}

// ─── Test 3: UPSERT consistency — every read sees the latest version ──────

test "makePlanContext: plan survives DB read across calls (UPSERT consistency)" {
    const allocator = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Write v1, read
    {
        const xml1 = try update_plan_mod.executeUpdatePlan(allocator, &ctx.db, "s_upsert", .{
            .content = "v1 content",
        });
        defer allocator.free(xml1);
    }
    const got1 = try plan_ctx.makePlanContext(allocator, &ctx.db, "s_upsert");
    defer allocator.free(got1);
    try testing.expect(std.mem.indexOf(u8, got1, "v1 content") != null);
    try testing.expect(std.mem.indexOf(u8, got1, "v2 content") == null);

    // Overwrite with v2 (UPSERT — must NOT leave v1 + v2 lying around).
    // Pin a later `updated_at` so the timestamp differs from v1
    // (SQLite CURRENT_TIMESTAMP has 1-sec resolution; sleep one
    // second so the floor advances).
    // std.c.nanosleep — std.Thread.sleep doesn't exist in Zig 0.16.
    var ts = std.c.timespec{ .sec = 1, .nsec = 0 };
    _ = std.c.nanosleep(&ts, null);
    {
        const xml2 = try update_plan_mod.executeUpdatePlan(allocator, &ctx.db, "s_upsert", .{
            .content = "v2 content longer and distinct",
        });
        defer allocator.free(xml2);
    }

    // Read again — must see v2, NOT v1.
    const got2 = try plan_ctx.makePlanContext(allocator, &ctx.db, "s_upsert");
    defer allocator.free(got2);
    try testing.expect(std.mem.indexOf(u8, got2, "v2 content longer") != null);
    try testing.expect(std.mem.indexOf(u8, got2, "v1 content") == null);
}

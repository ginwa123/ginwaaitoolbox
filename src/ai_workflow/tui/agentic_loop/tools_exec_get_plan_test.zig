//! Behavioural tests for `tools_exec_get_plan.zig` — the exec
//! wrapper that reads the current session's task plan and wraps the
//! result in the standard `<tool>...</tool>` envelope.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 4 of 9)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const migration = @import("../../../migrations/migration.zig");

const sqlite = nalarcore.sqlite;
const update_plan_mod = nalarcore.update_plan;
const execGetPlan = @import("tools_exec_get_plan.zig").execGetPlan;
const agent = nalarcore.agent;

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

/// Build a `ToolExecContext` that the exec wrapper can use. The exec
/// wrapper only reads `allocator`, `db`, and `session_id`; the other
/// fields (`logger`, `config`, `active_loops`, etc.) are left
/// `undefined` because the wrapper never dereferences them.
fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, session_id: []const u8) tools.ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = session_id,
        .model = "test-model",
        .cwd = "/tmp",
        .api_key = "test-key",
        .base_url = "http://test",
        .config = undefined,
        .agent_temperature = &dummy_f32,
        .is_thinking = &dummy_bool,
        .environment = null,
        .active_loops = undefined,
    };
}

fn fakeToolCall(name: []const u8) agent.ToolCall {
    // get_plan takes no params — `{}` is the canonical empty-args input.
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = "{}" },
    };
}

// ─── Test 1: absent plan returns wrapped `<empty/>` (D6) ───────────────────

test "execGetPlan: absent plan returns wrapped envelope with <empty/>" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_no_plan");
    const tc = fakeToolCall("get_plan");

    const result = try execGetPlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<name>get_plan</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<data>") != null);

    // The inner envelope is the `<empty/>` absent signal — no <plan> tag.
    try testing.expect(std.mem.indexOf(u8, result.output, "<get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<empty/>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<plan>") == null);

    // No <error> on the happy absent path.
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") == null);
}

// ─── Test 2: present plan returns wrapped `<plan><![CDATA[...]]></plan>` ────

test "execGetPlan: present plan returns wrapped envelope with CDATA-wrapped <plan>" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    // Seed the plan via the pure-fn layer (mirrors production wiring:
    // an earlier update_plan call already populated the row). The
    // pure-fn returns an allocated XML envelope we don't need —
    // discard with `_` and free explicitly to satisfy Zig 0.16's
    // "non-void values must be used" rule.
    {
        const seed_envelope = try update_plan_mod.executeUpdatePlan(alloc, &ctx.db, "sess_with_plan", .{
            .content = "# Goal\n\n- [x] done\n- [ ] pending\n",
        });
        defer alloc.free(seed_envelope);
    }

    const tcx = makeTestCtx(alloc, &ctx.db, "sess_with_plan");
    const tc = fakeToolCall("get_plan");

    const result = try execGetPlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<name>get_plan</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<data>") != null);

    // The inner envelope wraps the plan body in CDATA inside <plan>.
    try testing.expect(std.mem.indexOf(u8, result.output, "<get_plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "]]>") != null);
    // The raw markdown body should survive verbatim inside the CDATA.
    try testing.expect(std.mem.indexOf(u8, result.output, "# Goal") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "[x] done") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "[ ] pending") != null);

    // No <empty/> or <error> on the present branch.
    try testing.expect(std.mem.indexOf(u8, result.output, "<empty/>") == null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") == null);
}
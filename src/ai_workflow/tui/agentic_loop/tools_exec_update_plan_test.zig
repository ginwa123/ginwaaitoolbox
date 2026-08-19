//! Behavioural tests for `tools_exec_update_plan.zig` — the exec
//! wrapper that parses the LLM's JSON arguments, threads
//! `ctx.session_id` into the pure-fn layer (D3), and wraps the result
//! in the standard `<tool>...</tool>` envelope via `wrapToolOutput`.
//!
//! Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
//! Task: task_1787073929852_8 (Task 4 of 9)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const migration = @import("../../../migrations/migration.zig");

const sqlite = nalarcore.sqlite;
const session_plan = @import("../../../ai_workflow/tui/agentic_loop/session_plan.zig");
const execUpdatePlan = @import("tools_exec_update_plan.zig").execUpdatePlan;
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
fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) tools.ToolExecContext {
    var dummy_f32: f32 = 0.0;
    var dummy_bool: bool = false;
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .db = db,
        .logger = undefined,
        .session_id = "sess_exec",
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

fn fakeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = name, .arguments = args },
    };
}

// ─── Test 1: success path ──────────────────────────────────────────────────

test "execUpdatePlan: writes to session_plan and returns wrapped success" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    // The wrapped envelope contains a <success>true</success> tag and
    // an inner <update_plan>...</update_plan> body in <data>.
    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<tool>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<name>update_plan</name>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<data>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<session_id>sess_exec</session_id>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<updated_at>") != null);

    // The inner envelope's success path must NOT carry an <error> tag.
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") == null);

    // Verify the row landed in session_plan.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("# Plan\n- [ ] step", stored);
}

// ─── Test 2: empty content returns wrapped error with success=false ────────

test "execUpdatePlan: empty content returns wrapped error envelope" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    // Error path: <success>false</success>, <error>...</error>, no <data> block.
    // (wrapToolOutput deliberately drops <data> on the error branch —
    // the inner pure-fn XML is intentionally not surfaced. The LLM only
    // sees the human-readable error message.)
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "non-empty") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<data>") == null);

    // DB has no row for "sess_exec" — empty content is rejected.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}

// ─── Test 3: malformed JSON returns wrapped parse error ─────────────────────

test "execUpdatePlan: malformed JSON returns wrapped parse error" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    // Garbage JSON — not parseable as UpdatePlanInput.
    const tc = fakeToolCall("update_plan", "{not json at all");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>false</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<error>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "failed to parse input") != null);

    // No DB write happened.
    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("", stored);
}
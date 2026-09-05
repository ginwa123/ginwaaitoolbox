// Exec wrapper for the `update_plan` agent tool.
//
// The wrapper parses the JSON arguments emitted by the LLM, threads
// `ctx.session_id` into the pure-fn layer (D3 — session_id is implicit
// in the tool's input schema, never accepted as an argument), and wraps
// the result in the standard `<tool>...</tool>` envelope via
// `wrapToolOutput`.
//
// The inner success XML (in `<data>`) carries the just-written plan
// body as `<plan><![CDATA[...]]></plan>` so the LLM AND the frontend
// UI see the canonical plan back without depending on `parameters`
// (the agent's input args). Mirrors `executeGetPlan`'s shape.
//
// Plan: docs/superpowers/plans/2026-08-19-session-plan-agent-tool.md
// Task: task_1787073929852_8 (Task 4 of 9)

const std = @import("std");
const testing = std.testing;
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const migration = @import("../../../migrations/migration.zig");

const sqlite = nalarcore.sqlite;
const session_plan = @import("session_plan.zig");
const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const update_plan_mod = nalarcore.update_plan;
const wrapToolOutput = tools.wrapToolOutput;

pub fn execUpdatePlan(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        update_plan_mod.UpdatePlanInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "update_plan failed to parse input: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer parsed.deinit();

    const inner = update_plan_mod.executeUpdatePlan(
        ctx.allocator,
        ctx.db,
        ctx.session_id,
        parsed.value,
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(ctx.allocator, "update_plan failed: {s}", .{@errorName(err)});
        defer ctx.allocator.free(err_msg);
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, "");
        return ToolExecResult{ .output = output, .output_allocated = true };
    };
    defer ctx.allocator.free(inner);

    // Detect the <update_plan><error>...</error></update_plan> shape and
    // surface it as a tool failure (so the LLM sees success=false rather
    // than a successful wrapper around an error body). The inner XML
    // is still surfaced in <data> so the LLM can see the per-tool
    // detail (e.g. "content must be non-empty (1 byte minimum)").
    //
    // NOTE: match the full "<update_plan><error>" envelope marker, NOT bare
    // "<error>" — the success shape echoes user plan markdown inside
    // <plan><![CDATA[...]]></plan>, so a plan containing the literal text
    // "<error>" (e.g. "handle <error> case") must NOT false-trigger the
    // error branch. The old bare search + `orelse inner.len` fallback OOB'd
    // at inner[err_start..err_start+inner.len] (SIGABRT in sub-agent thread)
    // whenever the plan mentioned <error> without a closing </error>.
    if (std.mem.indexOf(u8, inner, "<update_plan><error>") != null) {
        const err_start = (std.mem.indexOf(u8, inner, "<error>") orelse 0) + "<error>".len;
        const err_end_rel = std.mem.indexOf(u8, inner[err_start..], "</error>") orelse (inner.len - err_start);
        const err_msg = inner[err_start .. err_start + err_end_rel];
        const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, false, err_msg, inner);
        return ToolExecResult{ .output = output, .output_allocated = true };
    }

    const output = try wrapToolOutput(ctx.allocator, "update_plan", tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

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
fn makeTestCtx(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ToolExecContext {
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

    // The inner envelope MUST echo the just-written plan body via
    // <plan><![CDATA[...]]></plan> — the frontend renders the
    // checklist from this CDATA block, NOT from the tool's input
    // arguments.
    try testing.expect(std.mem.indexOf(u8, result.output, "<plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "<![CDATA[") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "]]></plan>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "# Plan\n- [ ] step") != null);

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

// ─── Test 4 (regression): plan mentioning <error> without </error> ─────────
// Crash repro: success XML echoes plan markdown inside <plan><![CDATA[..]]></plan>.
// Old code searched bare "<error>" -> false-positive on plan text like
// "handle <error> case", then `orelse inner.len` OOB'd at
// inner[err_start..err_start+inner.len] (SIGABRT, tools_exec_update_plan.zig:66).
// Must return success=true, not crash.
test "execUpdatePlan: plan containing <error> without closing tag does not crash" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\nHandle <error> case\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
    try testing.expect(std.mem.indexOf(u8, result.output, "Handle <error> case") != null);

    const stored = try session_plan.getPlan(alloc, &ctx.db, "sess_exec");
    defer alloc.free(stored);
    try testing.expectEqualStrings("# Plan\nHandle <error> case\n- [ ] step", stored);
}

// ─── Test 5 (regression): plan with both <error> and </error> still success ─
// Even when the plan text contains a balanced pair, the envelope marker is
// "<update_plan><error>" (no such prefix in success XML), so this must NOT
// be misclassified as a tool failure.
test "execUpdatePlan: plan containing balanced error tags still succeeds" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer ctx.threaded.deinit();
    defer ctx.db.deinit();

    const tcx = makeTestCtx(alloc, &ctx.db);
    const tc = fakeToolCall("update_plan", "{\"content\":\"# Plan\\n<error>oops</error>\\n- [ ] step\"}");

    const result = try execUpdatePlan(tcx, tc);
    defer if (result.output_allocated) alloc.free(result.output);

    try testing.expect(result.output_allocated);
    try testing.expect(std.mem.indexOf(u8, result.output, "<success>true</success>") != null);
}
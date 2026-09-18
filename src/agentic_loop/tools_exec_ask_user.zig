//! `ask_user` exec adapter.
//!
//! Parses the arguments, applies the no-human gate, writes the pending row
//! and returns the `"status":"pending"` payload **immediately**. It
//! never blocks, never sleeps, and never touches `llm_history` — Phase 3 of
//! `handle_tool` writes this result into the tool row, and the workflow then
//! breaks the turn (see `workflow.zig`).
//!
//! The human's answer arrives much later and rewrites that same row via
//! `POST /api/llm/session/:id/answer` → `ask_user_pending.rewriteToolResultRow`.

const std = @import("std");
const nalarcore = @import("nalarcore");
const tools = @import("tools.zig");
const pending = @import("ask_user_pending.zig");

const ToolExecContext = tools.ToolExecContext;
const ToolExecResult = tools.ToolExecResult;
const agent = nalarcore.agent;
const ask_user_mod = nalarcore.ask_user;
const wrapToolOutput = tools.wrapToolOutput;

const TOOL_NAME = ask_user_mod.ASK_USER_TOOL_NAME;

/// Parse → validate → gate → insert → return.
///
/// Every failure path is a `success=false` envelope the model can read and
/// act on; a Zig error escaping here would be turned into a generic
/// "ask_user failed: …" by `handle_tool`, losing the actionable reason.
pub fn execAskUser(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const parsed = std.json.parseFromSlice(
        ask_user_mod.AskUserInput,
        ctx.allocator,
        tc.function.arguments,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch |err| {
        // Formatted into a temp so the message can be freed after the
        // envelope has copied it — an inline `try allocPrint` here leaks.
        const message = try std.fmt.allocPrint(
            ctx.allocator,
            "ask_user failed to parse input: {s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(message);
        return errorResult(ctx, tc, message);
    };
    defer parsed.deinit();

    const input = parsed.value;

    ask_user_mod.validateAskUserInput(input) catch |err| {
        return errorResult(ctx, tc, ask_user_mod.validationErrorMessage(err));
    };

    // ─── Gate: nobody can answer ─────────────────────────────────────────
    //
    // Both cases return `unavailable` WITHOUT writing a row, so the model
    // decides in the same run and the run completes. A dangling question
    // would be worse than a stated assumption.
    if (ctx.is_sub_agent) {
        // Unreachable in practice — `spawn_sub_agent` rejects `ask_user` at
        // parse time and `tool_eligibility` strips it for sub-agent sessions.
        // Kept as defence-in-depth: a sub-agent run has no answer surface, so
        // the question would sit unanswered forever.
        ctx.logger.warnFmt(
            "[ASK_USER] sub-agent session {s} called ask_user — returning unavailable (should have been stripped)",
            .{ctx.session_id},
        );
        return unavailableResult(ctx, tc);
    }
    if (pending.isUnattended(ctx.allocator, ctx.db, ctx.session_id)) {
        return unavailableResult(ctx, tc);
    }

    // ─── Record the question ─────────────────────────────────────────────
    const question_id = pending.insertPendingQuestion(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .db = ctx.db,
        .session_id = ctx.session_id,
        .tool_call_id = tc.id,
        .llm_history_id = ctx.llm_history_id,
        .question = input.question,
        .multi_select = input.multi_select orelse false,
    }) catch |err| {
        const message = try std.fmt.allocPrint(
            ctx.allocator,
            "ask_user could not record the question: {s}",
            .{@errorName(err)},
        );
        defer ctx.allocator.free(message);
        return errorResult(ctx, tc, message);
    };
    defer ctx.allocator.free(question_id);

    // The payload carries the whole question, not just the id: the card
    // renders from it (live AND after a reload), because the tool row
    // carries only the arguments, not the resolved status.
    const inner = try ask_user_mod.buildAskUserJson(ctx.allocator, .{
        .status = .pending,
        .question_id = question_id,
        .question = input.question,
        .header = input.header,
        .options = input.options,
        .allow_free_text = input.allow_free_text,
        .multi_select = input.multi_select,
        .recommended = input.recommended,
    });
    defer ctx.allocator.free(inner);

    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

/// The `success=false` envelope. `wrapToolOutput` already emits the canonical
/// error element, so there is no separate inner error envelope to build.
fn errorResult(ctx: ToolExecContext, tc: agent.ToolCall, message: []const u8) !ToolExecResult {
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, false, message, "");
    return ToolExecResult{ .output = output, .output_allocated = true };
}

fn unavailableResult(ctx: ToolExecContext, tc: agent.ToolCall) !ToolExecResult {
    const inner = try ask_user_mod.buildAskUserJson(ctx.allocator, .{ .status = .unavailable });
    defer ctx.allocator.free(inner);

    // success=true: this is a successful call with a degraded outcome, not a
    // malformed request. Only bad arguments produce `<error>`.
    const output = try wrapToolOutput(ctx.allocator, TOOL_NAME, tc.function.arguments, true, null, inner);
    return ToolExecResult{ .output = output, .output_allocated = true };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const tools_mod = @import("tools.zig");

fn setupDb() !struct { db: nalarcore.sqlite.SqliteBackend, threaded: std.Io.Threaded } {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: nalarcore.sqlite.SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    try db.exec(alloc,
        \\CREATE TABLE session_pending_question (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    tool_call_id TEXT NOT NULL,
        \\    llm_history_id TEXT NOT NULL,
        \\    question TEXT NOT NULL,
        \\    multi_select INTEGER NOT NULL DEFAULT 0,
        \\    status TEXT NOT NULL DEFAULT 'pending',
        \\    answer TEXT,
        \\    created_at INTEGER NOT NULL,
        \\    resolved_at INTEGER
        \\)
    , &.{});
    try db.exec(alloc, "CREATE UNIQUE INDEX idx_spq_tool_call ON session_pending_question(tool_call_id)", &.{});
    try db.exec(alloc, "CREATE TABLE sessions (id TEXT PRIMARY KEY, is_auto_retry_until_stop TEXT)", &.{});
    return .{ .db = db, .threaded = threaded };
}

/// Stand-in for the pointer-typed context fields `execAskUser` never reads.
/// Keeping them in a caller-owned holder makes the addresses stable (a
/// struct returned by value would leave `&field` pointing at a dead frame).
const CtxHolder = struct {
    temp: f32 = 0.2,
    thinking: bool = false,
    /// `ActiveLoops` owns a hash map, so it needs an allocator — built in
    /// `build` rather than defaulted.
    loops: @import("ActiveLoops.zig").ActiveLoops = undefined,
    /// A real (silent) logger: the sub-agent path logs a warning, and the
    /// config is what keeps it out of the test output.
    logger: nalarcore.loggermod.Logger = undefined,

    fn build(
        self: *CtxHolder,
        allocator: std.mem.Allocator,
        io: std.Io,
        db: *nalarcore.sqlite.SqliteBackend,
        is_sub_agent: bool,
    ) ToolExecContext {
        self.loops = @import("ActiveLoops.zig").ActiveLoops.init(allocator);
        self.logger = nalarcore.loggermod.Logger.init(allocator, io, .{
            .min_level = .err,
            .include_timestamp = false,
            .include_request_id = false,
            .include_location = false,
        });
        return .{
            .allocator = allocator,
            .io = io,
            .db = db,
            .logger = &self.logger,
            .session_id = "sess_1",
            .model = "test-model",
            .cwd = "/tmp",
            .api_key = "",
            .base_url = "",
            // Unread by execAskUser — present only to satisfy the struct.
            .config = undefined,
            .agent_temperature = &self.temp,
            .is_thinking = &self.thinking,
            .environment = null,
            .active_loops = &self.loops,
            .tool_call_id = "call_1",
            .llm_history_id = "row_1",
            .is_sub_agent = is_sub_agent,
        };
    }
};

fn callArgs(json: []const u8) agent.ToolCall {
    return .{
        .id = "call_1",
        .type = "function",
        .function = .{ .name = "ask_user", .arguments = json },
    };
}

test "execAskUser: valid input writes a pending row and returns the pending envelope" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var holder: CtxHolder = .{};
    const c = holder.build(a, s.threaded.io(), &s.db, false);
    const tc = callArgs("{\"question\":\"Which environment?\",\"options\":[\"staging\",\"production\"]}");

    const res = try execAskUser(c, tc);
    defer res.deinit(a);

    try testing.expect(res.output_allocated);
    // Wrapped success=true with the pending inner envelope.
    try testing.expect(std.mem.indexOf(u8, res.output, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "\"status\":\"pending\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "\"question_id\":\"q_") != null);

    // The row exists and is pending.
    try testing.expect(pending.hasPendingQuestion(a, &s.db, "sess_1"));
}

test "execAskUser: malformed arguments produce a success=false envelope" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var holder: CtxHolder = .{};
    const c = holder.build(a, s.threaded.io(), &s.db, false);
    // `recommended` is not one of the options — the most likely model mistake.
    const tc = callArgs("{\"question\":\"q\",\"options\":[\"a\",\"b\"],\"recommended\":\"c\"}");
    const res = try execAskUser(c, tc);
    defer res.deinit(a);

    try testing.expect(std.mem.indexOf(u8, res.output, "\"success\":false") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "must exactly match one of the strings in options") != null);
    // Nothing was recorded for a bad call.
    try testing.expect(!pending.hasPendingQuestion(a, &s.db, "sess_1"));
}

test "execAskUser: unparseable arguments produce a success=false envelope" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var holder: CtxHolder = .{};
    const c = holder.build(a, s.threaded.io(), &s.db, false);
    const tc = callArgs("not json at all");
    const res = try execAskUser(c, tc);
    defer res.deinit(a);

    try testing.expect(std.mem.indexOf(u8, res.output, "\"success\":false") != null);
    try testing.expect(!pending.hasPendingQuestion(a, &s.db, "sess_1"));
}

test "execAskUser: unattended session returns unavailable and writes NO row" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    try s.db.exec(a, "INSERT INTO sessions (id, is_auto_retry_until_stop) VALUES ('sess_1', '1')", &.{});

    var holder: CtxHolder = .{};
    const c = holder.build(a, s.threaded.io(), &s.db, false);
    const tc = callArgs("{\"question\":\"Which environment?\"}");
    const res = try execAskUser(c, tc);
    defer res.deinit(a);

    try testing.expect(std.mem.indexOf(u8, res.output, "\"status\":\"unavailable\"") != null);
    // Successful call, degraded outcome — never `<error>`.
    try testing.expect(std.mem.indexOf(u8, res.output, "\"success\":true") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "No human is available") != null);
    // The crucial part: a scheduled run leaves nothing dangling.
    try testing.expect(!pending.hasPendingQuestion(a, &s.db, "sess_1"));
}

test "execAskUser: sub-agent returns unavailable and writes NO row" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var holder: CtxHolder = .{};
    const c = holder.build(a, s.threaded.io(), &s.db, true);
    const tc = callArgs("{\"question\":\"Which environment?\"}");
    const res = try execAskUser(c, tc);
    defer res.deinit(a);

    try testing.expect(std.mem.indexOf(u8, res.output, "\"status\":\"unavailable\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.output, "No human is available") != null);
    try testing.expect(!pending.hasPendingQuestion(a, &s.db, "sess_1"));
}

test "execAskUser: a re-exec of the same tool call does not insert a second row" {
    const a = testing.allocator;
    var s = try setupDb();
    defer s.db.deinit();
    defer s.threaded.deinit();

    var holder: CtxHolder = .{};
    const c = holder.build(a, s.threaded.io(), &s.db, false);
    const tc = callArgs("{\"question\":\"Which environment?\"}");

    const r1 = try execAskUser(c, tc);
    defer r1.deinit(a);
    const r2 = try execAskUser(c, tc);
    defer r2.deinit(a);

    var rows = try s.db.query(a, "SELECT COUNT(*) FROM session_pending_question", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    defer row.deinit(a);
    try testing.expectEqualStrings("1", row.values[0]);
}

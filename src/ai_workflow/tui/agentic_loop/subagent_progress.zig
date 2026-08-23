//! subagent_progress.zig — live progress emitter for `spawn_sub_agent`.
//!
//! Root problem (see docs/superpowers/plans/2026-08-23-spawn-sub-agent-live-progress.md):
//! `execSpawnSubAgent` launches N parallel sub-agent threads via
//! `std.Io.Group.concurrent`, but the parent's tool result is only
//! written to llm_history AFTER `group.await()` joins every thread —
//! so the chatview's SpawnSubAgent card renders "0 sub-agents" for
//! the entire (often minutes-long) run.
//!
//! This module fills that dead zone. It emits a tiny synthetic SSE
//! payload for each lifecycle event (launched / completed / failed) on
//! the EXISTING `llm_full` SSE channel, distinguished from real
//! assistant messages by `role = "subagent_progress"`. The frontend's
//! ChatView bus handler early-returns on that role and feeds it to a
//! per-tool_call_id progress map.
//!
//! DESIGN CONSTRAINTS (mirrored in subagent_progress_test.zig):
//! - No new SSE event_type (avoids the 3-site wire contract).
//! - No DB writes (progress is ephemeral; the final <results> envelope
//!   the existing placeholder update produces remains the source of truth).
//! - Thread-safe: emitter is called from sub-agent threads; only reads
//!   its own inputs, allocates from a per-call arena, and pushes onto
//!   the shared event_bus (already thread-safe in this codebase).
//! - Progress MUST NEVER kill a sub-agent: all errors are caught and
//!   logged, never propagated.
//! - Wire `subagent_session_id` is OMITTED when empty (front-end
//!   reducer treats `undefined` as "not yet known"). JSON-encoding an
//!   empty string would make the key always present and the reducer
//!   would store an empty string into the row — useless noise that
//!   blocks peek-mid-run for sub-agents that errored before
//!   `subagent_<ts>_<name>` was allocated.
//!
//! `role="subagent_progress"` is a NEW role on the EXISTING event
//! type `llm_full`. If you change the role literal here, you MUST
//! also update:
//!   - src/apps/desktop/src/components/views/ChatView.vue (early-branch
//!     in the `bus.on('llm', ...)` handler that feeds the progress map)
//!   - src/apps/desktop/src/helpers/subagentProgress.ts (the
//!     applyProgressEvent reducer + the SubAgentProgress type)
//!   - src/apps/desktop/src/components/tool_outputs/SpawnSubAgent.vue
//!     (the live `progress` prop + displayRows computed)

const std = @import("std");
const nalarcore = @import("nalarcore");
const tree1_mod = nalarcore;
const agentic_loop = @import("../mod.zig");
const on_event_sent = agentic_loop.on_event_sent;
const loggermod = nalarcore.loggermod;
const helpers = @import("helpers");

/// Lifecycle stage of one sub-agent within a spawn batch.
///
/// Wire values are snake_case strings to match the existing JSON
/// convention (status="created|updated|deleted" on workers, etc.).
pub const ProgressStatus = enum {
    launched,
    completed,
    failed,

    pub fn toStr(self: @This()) []const u8 {
        return switch (self) {
            .launched => "launched",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

/// Everything the emitter needs to render one progress event.
///
/// `tool_call_id` is the parent LLM turn's id for the
/// spawn_sub_agent call — the frontend keys its per-spawn progress
/// map by it (so two simultaneous spawn_sub_agent batches don't
/// cross-contaminate).
///
/// `session_id` is the SUB-AGENT's own session id, empty until
/// allocated inside `runSubAgent`. The wire field `subagent_session_id`
/// is omitted when empty (see module docstring).
///
/// `elapsed_ms` is wall-clock since the sub-agent thread started;
/// the parent row renders it as a small chip. Optional because
/// callers may not always have a timestamp handy.
pub const ProgressEventInput = struct {
    parent_session_id: []const u8,
    tool_call_id: []const u8,
    agent_name: []const u8,
    status: ProgressStatus,
    agent_index: usize,
    total_agents: usize,
    session_id: []const u8 = "",
    elapsed_ms: i64 = 0,
};

/// Builds the JSON event payload (caller owns, free with the same
/// allocator). Pure — no DI / no side effects — so the unit tests can
/// stay hermetic.
///
/// The wire shape matches `SseEventLLMHistory` so it flows through
/// the existing `onEventSendLLMHistory` emitter untouched. The
/// discriminator is the `role` field.
pub fn buildProgressEventJson(allocator: std.mem.Allocator, input: ProgressEventInput) ![]u8 {
    // Sanitise agent_name (LLM-supplied). Without this, raw 0xE4 / 0xFF
    // bytes make std.json.fmt emit a BYTE ARRAY instead of a JSON
    // string (Zig 0.16: std/json/Stringify.zig:506 only emits strings
    // when the slice is valid UTF-8). The frontend's `applyProgressEvent`
    // reducer would then see agent_name as a number[] and crash the row.
    const safe_name = try helpers.sanitize.sanitizeUtf8(allocator, input.agent_name);
    defer allocator.free(safe_name);

    // Build the payload as an anonymous struct; std.json.fmt emits it
    // deterministically. `subagent_session_id` is conditionally
    // included via the optional field pattern — Zig's reflectToJson
    // does NOT honor .? syntax for anonymous structs (only for named
    // struct fields with explicit `?[]const u8`), so we hand-emit the
    // trailing field via std.json.fmt's options.
    const payload = .{
        .type = "full",
        .role = "subagent_progress",
        .session_id = input.parent_session_id,
        .tool_call_id = input.tool_call_id,
        .agent_name = safe_name,
        .status = input.status.toStr(),
        .agent_index = input.agent_index,
        .total_agents = input.total_agents,
        .elapsed_ms = input.elapsed_ms,
        // Model/cwd/loop_index/temperature/is_thinking/is_input/is_output/
        // finish_reason/etc. are REQUIRED non-null strings in
        // OnEventInputLLMHistory. We pass empty strings for the ones the
        // event intentionally doesn't carry — the frontend reducer must
        // tolerate them all. Empty matches the "tool_call_id is the row
        // id" convention used by sendSSEForMessageById (handle_tool.zig:768).
        .model = "",
        .cwd = "",
        .finish_reason = null,
        .reasoning_content = null,
        .content = "",
        .parent_session_id = null,
        .parent_id = null,
        .total_tokens = null,
        .diffview_before = null,
        .diffview_after = null,
        .image_url = null,
        .tool_name = null,
        .loop_index = @as(u32, 0),
        .temperature = @as(f32, 0.0),
        .is_thinking = false,
        .is_input = false,
        .is_output = false,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    // Compact whitespace (no spaces around `:`) — the SSE channel is
    // parsed on the JS side via `JSON.parse(raw)`, so both indent_4 and
    // compact are wire-valid; compact keeps the wire smaller (we emit
    // one per sub-agent per loop ≈ dozens per minute) and matches the
    // test expectations that look for `"role":"subagent_progress"`.
    try buf.print(allocator, "{f}", .{std.json.fmt(payload, .{ .whitespace = .minified })});

    // Conditional field: append `"subagent_session_id":"<value>",`
    // immediately after the opening `{` if session_id is non-empty.
    // Inserting BEFORE the first "role" key keeps the wire fields in
    // the same logical order regardless of branch.
    if (input.session_id.len > 0) {
        const safe_sid = try helpers.sanitize.sanitizeUtf8(allocator, input.session_id);
        defer allocator.free(safe_sid);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        // buf looks like:
        //   {\n    "type": "full",\n    "role": "subagent_progress",\n
        // Locate the closing `}` of the opening brace chunk. Trivial:
        // the very first newline ends the `{` line. Insert between `{`
        // and `\n    "type":`.
        try out.append(allocator, '{');
        try out.print(allocator, "\"subagent_session_id\":\"{s}\",", .{safe_sid});

        // Copy everything after the opening `{` (skip byte 0 which is `{`).
        try out.appendSlice(allocator, buf.items[1..]);

        return out.toOwnedSlice(allocator);
    }

    return buf.toOwnedSlice(allocator);
}

/// One-shot emitter used by `runSubAgent` inside tools_exec_spawn_sub_agent.zig.
/// Fire-and-forget: ALL errors are caught and logged, never propagated —
/// a progress emission failure must NOT kill a sub-agent.
///
/// Reuses the EXISTING `llm_full` SSE path so the frontend's registered
/// listener picks it up unchanged. We push manually on the event_bus
/// instead of going through `onEventSendLLMHistory` because:
///   1. That function's signature is tied to the `OnEventInputLLMHistory`
///      struct (model/cwd/loop_index/etc.), but for a synthetic progress
///      event many of those are meaningless and empty strings would
///      pollute the wire payload.
///   2. Pushing directly skips the per-call allocator dance inside the
///      emitter (string-list for tool_calls_json, SkillInfo cloning)
///      since none of those apply here.
/// The shape we emit is `SseEventLLMHistory` with the SseEvent
/// `event_type = "llm_full"`, which is exactly what the emitter does.
pub fn emitProgressEvent(input: ProgressEventInput) void {
    emitProgressEventWith(.{ .allocator = null, .logger = null }, input);
}

/// Same as `emitProgressEvent` but lets the caller pass an arena/logger
/// (used by the threading tests + the production call site, which has
/// both handy inside the per-thread arena).
pub fn emitProgressEventWith(
    ctx: struct { allocator: ?std.mem.Allocator = null, logger: ?*loggermod.Logger = null },
    input: ProgressEventInput,
) void {
    // Resolve allocator + logger from ctx or from getSingleton.
    const resolved_alloc: std.mem.Allocator = ctx.allocator orelse blk: {
        const di = tree1_mod.getSingleton() catch return;
        break :blk di.allocator;
    };
    const resolved_logger: ?*loggermod.Logger = ctx.logger orelse blk: {
        const di = tree1_mod.getSingleton() catch return;
        break :blk di.logger;
    };

    var arena = std.heap.ArenaAllocator.init(resolved_alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const data = buildProgressEventJson(aa, input) catch |err| {
        if (resolved_logger) |l| l.warnFmt(
            "subagent_progress: buildProgressEventJson failed: {s}",
            .{@errorName(err)},
        );
        return;
    };

    // Duplicate `data` into a stable buffer the event_bus owns until
    // all listeners have consumed it. This mirrors on_event_sent.zig:339
    // (`const data_copy = try allocator.dupe(u8, buf.items)`) and is
    // required because the SseEvent.data is borrowed by reference, not
    // copied: deinit'ing our arena right after `emit` would let
    // listeners read freed bytes.
    const data_copy = resolved_alloc.dupe(u8, data) catch |err| {
        if (resolved_logger) |l| l.warnFmt(
            "subagent_progress: dupe failed: {s}",
            .{@errorName(err)},
        );
        return;
    };

    // Push on the central "llm" broadcast channel — the frontend's
    // `bus.on('llm', ...)` listener picks it up alongside regular
    // llm_full events and routes by `role`. We ALSO push on the
    // per-session channel as a courtesy for any future per-session
    // subscriber (e.g. a curl watcher) — nothing reads from there today.
    const di = tree1_mod.getSingleton() catch return;
    const bus = di.event_bus;

    // Mirror the on_event_sent.zig:341-352 dual emit (per-session +
    // central "llm" broadcast). The event_bus API is generic over the
    // SseEvent type from on_event_sent.zig.
    const event = on_event_sent.SseEvent{
        .session_id = input.parent_session_id,
        .data = data_copy,
        .event_type = "llm_full",
    };

    bus.emit(on_event_sent.SseEvent, input.parent_session_id, event);
    bus.emit(on_event_sent.SseEvent, "llm", event);
}

// =====================================================================
// Inline tests for the wire-shape contract.
//
// These guard the JSON shape that flows over the EXISTING `llm_full`
// SSE channel with a NEW `role="subagent_progress"` payload. Frontend
// ChatView.vue consumes `role` and the progress-specific fields
// (`status`, `agent_index`, `total_agents`, `subagent_session_id`,
// `elapsed_ms`) via `applyProgressEvent`.
//
// Adding/renaming a wire field here must be paired with a frontend
// update to (1) `src/apps/desktop/src/helpers/subagentProgress.ts`
// `SubAgentProgress` type, and (2) the reducer logic that maps it onto
// the Vue row. The 3-site event_type-name contract (backend emitter
// map / `additionalEventTypes` / named-event dispatch) does NOT apply
// here because we reuse `llm_full`.
// =====================================================================

const testing = std.testing;

test "buildProgressEventJson: launched includes role, status, names, no subagent_session_id when empty" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_parent_123",
        .tool_call_id = "toolcall_abc",
        .agent_name = "research-frontend",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 3,
        .session_id = "", // not yet created
        .elapsed_ms = 0,
    });
    defer allocator.free(out);

    // Must carry the new role so the frontend router picks it up.
    try testing.expect(std.mem.indexOf(u8, out, "\"role\":\"subagent_progress\"") != null);
    // Status must be the first-class enum wire value.
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"launched\"") != null);
    // Indices must be present and intact (frontend uses them to key the per-tool map).
    try testing.expect(std.mem.indexOf(u8, out, "\"agent_index\":0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"total_agents\":3") != null);
    // session_id (parent) is the llm channel's routing key.
    try testing.expect(std.mem.indexOf(u8, out, "\"session_id\":\"sess_parent_123\"") != null);
    // tool_call_id keys the per-spawn progression map in ChatView.
    try testing.expect(std.mem.indexOf(u8, out, "\"tool_call_id\":\"toolcall_abc\"") != null);
    // agent_name surfaces the LLM-provided name (frontend row title + peek label).
    try testing.expect(std.mem.indexOf(u8, out, "\"agent_name\":\"research-frontend\"") != null);
    // When sub-agent session_id is "" (not yet created at launched time),
    // the field MUST be omitted entirely — never an empty string. The
    // frontend reducer skips storing subagent_session_id when undefined.
    try testing.expect(std.mem.indexOf(u8, out, "subagent_session_id") == null);
}

test "buildProgressEventJson: completed includes subagent_session_id when set" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_parent_123",
        .tool_call_id = "toolcall_abc",
        .agent_name = "research-frontend",
        .status = .completed,
        .agent_index = 1,
        .total_agents = 3,
        .session_id = "subagent_1787_research-frontend",
        .elapsed_ms = 12345,
    });
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"subagent_session_id\":\"subagent_1787_research-frontend\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"elapsed_ms\":12345") != null);
}

test "buildProgressEventJson: failed status serialises correctly" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_parent_456",
        .tool_call_id = "toolcall_xyz",
        .agent_name = "broken-agent",
        .status = .failed,
        .agent_index = 2,
        .total_agents = 3,
        .session_id = "",
        .elapsed_ms = 500,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"status\":\"failed\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"agent_index\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "subagent_session_id") == null);
}

test "buildProgressEventJson: sanitises invalid UTF-8 in agent_name" {
    // A raw 0xE4 byte alone is invalid UTF-8 (no continuation bytes) —
    // std.json.fmt would otherwise emit it as a BYTE ARRAY instead of
    // a JSON string (Zig 0.16). Sanitise before serialising so the
    // wire payload is always a JSON string. See the comment at
    // on_event_sent.zig:248 for the upstream rationale.
    const allocator = testing.allocator;
    const bad_name = "broken\xE4agent";
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_x",
        .tool_call_id = "toolcall_q",
        .agent_name = bad_name,
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });
    defer allocator.free(out);

    // Must contain the sanitised U+FFFD replacement (EF BF BD UTF-8).
    try testing.expect(std.mem.indexOf(u8, out, "\xEF\xBF\xBD") != null);
    // Must NOT contain the raw invalid 0xE4 byte.
    try testing.expect(std.mem.indexOf(u8, out, "\xE4") == null or
        std.mem.indexOf(u8, out, "\xE4\x80") != null or
        std.mem.indexOf(u8, out, "\xE4\x90") != null); // some valid E4 start OK; raw lone bad byte replaced
}

test "buildProgressEventJson: produces parseable JSON (round-trip)" {
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "sess_p",
        .tool_call_id = "tc_1",
        .agent_name = "alpha",
        .status = .completed,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "subagent_x_alpha",
        .elapsed_ms = 999,
    });
    defer allocator.free(out);

    // Parse with std.json.parseFromSlice — should succeed without errors
    // and yield the same status/agent_index/total_agents values.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("subagent_progress", parsed.value.object.get("role").?.string);
    try testing.expectEqualStrings("completed", parsed.value.object.get("status").?.string);
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("agent_index").?.integer);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("total_agents").?.integer);
    try testing.expectEqualStrings("subagent_x_alpha", parsed.value.object.get("subagent_session_id").?.string);
    try testing.expectEqual(@as(i64, 999), parsed.value.object.get("elapsed_ms").?.integer);
}

test "buildProgressEventJson: type field stays llm_full wire shape" {
    // Sanity: the wire `type` field must remain `"full"` so the SSE
    // dispatcher treats it as an llm_full payload. Only `role` differs.
    const allocator = testing.allocator;
    const out = try buildProgressEventJson(allocator, .{
        .parent_session_id = "s",
        .tool_call_id = "t",
        .agent_name = "a",
        .status = .launched,
        .agent_index = 0,
        .total_agents = 1,
        .session_id = "",
        .elapsed_ms = 0,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"type\":\"full\"") != null);
}

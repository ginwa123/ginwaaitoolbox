// Tests for subagent_progress.zig — pure progress-event builder + emitter
// wire-shape contract.
//
// These tests guard the JSON shape that flows over the EXISTING `llm_full`
// SSE channel with a NEW `role="subagent_progress"` payload. Frontend
// ChatView.vue:2033 consumes `role` and the progress-specific fields
// (`status`, `agent_index`, `total_agents`, `subagent_session_id`,
// `elapsed_ms`) via `applyProgressEvent`.
//
// Adding/renaming a wire field here must be paired with a frontend update
// to (1) `src/apps/desktop/src/helpers/subagentProgress.ts` `SubAgentProgress`
// type, and (2) the reducer logic that maps it onto the Vue row. The 3-site
// event_type-name contract (backend emitter map / `additionalEventTypes` /
// named-event dispatch) does NOT apply here because we reuse `llm_full`.

const std = @import("std");
const testing = std.testing;

const sp = @import("subagent_progress.zig");

test "buildProgressEventJson: launched includes role, status, names, no subagent_session_id when empty" {
    const allocator = testing.allocator;
    const out = try sp.buildProgressEventJson(allocator, .{
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
    const out = try sp.buildProgressEventJson(allocator, .{
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
    const out = try sp.buildProgressEventJson(allocator, .{
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
    // A raw 0x89 byte in agent_name would normally crash std.json.fmt
    // (Zig 0.16 emits invalid UTF-8 as byte arrays instead of strings —
    // see the comment at on_event_sent.zig:248). Sanitise before
    // serialising so the wire payload is always a JSON string.
    const allocator = testing.allocator;
    const bad_name = "broken\xE4agent"; // 0xE4 alone is invalid (no continuation)
    const out = try sp.buildProgressEventJson(allocator, .{
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
    const out = try sp.buildProgressEventJson(allocator, .{
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
    const out = try sp.buildProgressEventJson(allocator, .{
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

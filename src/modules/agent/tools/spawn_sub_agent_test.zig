const std = @import("std");
const spawn = @import("spawn_sub_agent.zig");

test "parse_sub_agents - inherited_context 'last:3' is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x","inherited_context":"last:3"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expect(parsed.sub_agents[0].inherited_context != null);
    try std.testing.expectEqualStrings("last:3", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - omitted inherited_context is null" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents[0].inherited_context == null);
}

test "parse_sub_agents - inherited_context 'none' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"none"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("none", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context 'all' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"all"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("all", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"last:5"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator will assert.
    // No explicit expect — if it leaks, testing.allocator fails the test on deinit.
}

test "parse_sub_agents - invalid inherited_context mode returns InvalidInheritedContextMode" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"a","instruction":"x","inherited_context":"last:5x"}]}
    ;
    try std.testing.expectError(error.InvalidInheritedContextMode, spawn.parse_sub_agents(alloc, input_json, 20));
}

// -------------------------------------------------------------------------
// parse_sub_agents — agent_name (REQUIRED, label + config-driven selection)
// -------------------------------------------------------------------------
//
// Tests the required `agent_name` field. It serves two purposes:
//   1. The label that appears in the result XML's <agent name="..."> tag.
//   2. The name looked up in LlmConfig.sub_agents to apply as an
//      overlay on the orchestrator's defaults.

test "parse_sub_agents - agent_name is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"code-reviewer","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expectEqualStrings("code-reviewer", parsed.sub_agents[0].agent_name);
}

test "parse_sub_agents - missing agent_name returns MissingSubAgentAgentName" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"instruction":"do x"}]}
    ;
    try std.testing.expectError(error.MissingSubAgentAgentName, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - empty string agent_name returns MissingSubAgentAgentName" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"","instruction":"do x"}]}
    ;
    try std.testing.expectError(error.MissingSubAgentAgentName, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name too long (>256 chars) returns AgentNameTooLong" {
    const alloc = std.testing.allocator;
    // 300-char agent_name value
    var long_name_buf: [310]u8 = undefined;
    @memset(&long_name_buf, 'x');
    const long_name = long_name_buf[0..300];

    var input_buf: [512]u8 = undefined;
    const prefix = "{\"sub_agents\":[{\"agent_name\":\"";
    @memcpy(input_buf[0..prefix.len], prefix);
    @memcpy(input_buf[prefix.len..][0..long_name.len], long_name);
    const suffix = "\",\"instruction\":\"do x\"}]}";
    @memcpy(input_buf[prefix.len + long_name.len ..][0..suffix.len], suffix);
    const input_json = input_buf[0 .. prefix.len + long_name.len + suffix.len];

    try std.testing.expectError(error.AgentNameTooLong, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"agent_name":"code-reviewer","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator fails on deinit if it does.
}

test "parse_sub_agents - multiple sub_agents each carry their own agent_name" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[
        \\  {"agent_name":"reviewer","instruction":"x"},
        \\  {"agent_name":"explorer","instruction":"x"},
        \\  {"agent_name":"writer","instruction":"x"}
        \\]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), parsed.sub_agents.len);
    try std.testing.expectEqualStrings("reviewer", parsed.sub_agents[0].agent_name);
    try std.testing.expectEqualStrings("explorer", parsed.sub_agents[1].agent_name);
    try std.testing.expectEqualStrings("writer", parsed.sub_agents[2].agent_name);
}

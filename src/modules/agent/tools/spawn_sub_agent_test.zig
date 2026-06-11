const std = @import("std");
const spawn = @import("spawn_sub_agent.zig");

test "parse_sub_agents - inherited_context 'last:3' is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x","inherited_context":"last:3"}]}
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
        \\{"sub_agents":[{"name":"a","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents[0].inherited_context == null);
}

test "parse_sub_agents - inherited_context 'none' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"none"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("none", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context 'all' is parsed" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"all"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("all", parsed.sub_agents[0].inherited_context.?);
}

test "parse_sub_agents - inherited_context is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"last:5"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator will assert.
    // No explicit expect — if it leaks, testing.allocator fails the test on deinit.
}

test "parse_sub_agents - invalid inherited_context mode returns InvalidInheritedContextMode" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"x","inherited_context":"last:5x"}]}
    ;
    try std.testing.expectError(error.InvalidInheritedContextMode, spawn.parse_sub_agents(alloc, input_json, 20));
}

// -------------------------------------------------------------------------
// parse_sub_agents — agent_name (config-driven sub-agent selection)
// -------------------------------------------------------------------------
//
// Tests the new optional `agent_name` field. When present, the
// sub-agent is resolved against LlmConfig.sub_agents at spawn
// time. When empty or omitted, no resolution is performed.

test "parse_sub_agents - agent_name present is parsed into SubAgentInput" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x","agent_name":"code-reviewer"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents.len == 1);
    try std.testing.expect(parsed.sub_agents[0].agent_name != null);
    try std.testing.expectEqualStrings("code-reviewer", parsed.sub_agents[0].agent_name.?);
}

test "parse_sub_agents - omitted agent_name is null" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expect(parsed.sub_agents[0].agent_name == null);
}

test "parse_sub_agents - empty string agent_name is treated as null" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x","agent_name":""}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    // Empty string at the JSON level is treated as "not specified"
    // (matches the workflow semantics: skip resolveSubAgent entirely).
    try std.testing.expect(parsed.sub_agents[0].agent_name == null);
}

test "parse_sub_agents - agent_name too long (>256 chars) returns AgentNameTooLong" {
    const alloc = std.testing.allocator;
    // 300-char agent_name value
    var long_name_buf: [310]u8 = undefined;
    @memset(&long_name_buf, 'x');
    const long_name = long_name_buf[0..300];

    var input_buf: [512]u8 = undefined;
    const prefix = "{\"sub_agents\":[{\"name\":\"a\",\"instruction\":\"do x\",\"agent_name\":\"";
    @memcpy(input_buf[0..prefix.len], prefix);
    @memcpy(input_buf[prefix.len..][0..long_name.len], long_name);
    const suffix = "\"}]}";
    @memcpy(input_buf[prefix.len + long_name.len ..][0..suffix.len], suffix);
    const input_json = input_buf[0 .. prefix.len + long_name.len + suffix.len];

    try std.testing.expectError(error.AgentNameTooLong, spawn.parse_sub_agents(alloc, input_json, 20));
}

test "parse_sub_agents - agent_name is freed by deinit (ASan-safe)" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[{"name":"a","instruction":"do x","agent_name":"code-reviewer"}]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    parsed.deinit(alloc); // Must not leak; testing.allocator fails on deinit if it does.
}

test "parse_sub_agents - multiple sub_agents each carry their own agent_name" {
    const alloc = std.testing.allocator;
    const input_json =
        \\{"sub_agents":[
        \\  {"name":"a","instruction":"x","agent_name":"reviewer"},
        \\  {"name":"b","instruction":"x","agent_name":"explorer"},
        \\  {"name":"c","instruction":"x"}
        \\]}
    ;
    var parsed = try spawn.parse_sub_agents(alloc, input_json, 20);
    defer parsed.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), parsed.sub_agents.len);
    try std.testing.expectEqualStrings("reviewer", parsed.sub_agents[0].agent_name.?);
    try std.testing.expectEqualStrings("explorer", parsed.sub_agents[1].agent_name.?);
    try std.testing.expect(parsed.sub_agents[2].agent_name == null);
}

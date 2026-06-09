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

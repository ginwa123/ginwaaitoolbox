const std = @import("std");
const change_agent = @import("change_agent.zig");
const ChangeAgentInput = change_agent.ChangeAgentInput;

test "parse_change_agent_input with agent_name" {
    const allocator = std.testing.allocator;
    const json_str = "{\"agent_name\": \"zig-expert\"}";

    const input = try change_agent.parse_change_agent_input(allocator, json_str);
    defer {
        if (input.agent_name) |n| allocator.free(n);
        if (input.path) |p| allocator.free(p);
    }

    try std.testing.expect(input.agent_name != null);
    try std.testing.expectEqualStrings("zig-expert", input.agent_name.?);
}

test "parse_change_agent_input with path" {
    const allocator = std.testing.allocator;
    const json_str = "{\"path\": \"/absolute/path/to/agent.zig\"}";

    const input = try change_agent.parse_change_agent_input(allocator, json_str);
    defer {
        if (input.agent_name) |n| allocator.free(n);
        if (input.path) |p| allocator.free(p);
    }

    try std.testing.expect(input.path != null);
    try std.testing.expectEqualStrings("/absolute/path/to/agent.zig", input.path.?);
}

test "parse_change_agent_input empty input" {
    const allocator = std.testing.allocator;
    const json_str = "{}";

    const input = try change_agent.parse_change_agent_input(allocator, json_str);
    defer {
        if (input.agent_name) |n| allocator.free(n);
        if (input.path) |p| allocator.free(p);
    }

    try std.testing.expect(input.agent_name == null);
    try std.testing.expect(input.path == null);
}

test "parse_change_agent_input invalid json" {
    const allocator = std.testing.allocator;
    const json_str = "not valid json";

    const result = change_agent.parse_change_agent_input(allocator, json_str);
    try std.testing.expectError(error.InvalidJson, result);
}

test "change_agent_tool has correct name" {
    const tool = change_agent.change_agent_tool;
    try std.testing.expectEqualStrings("change_agent", tool.function.name);
}

test "change_agent_tool description mentions switching" {
    const tool = change_agent.change_agent_tool;
    const desc = tool.function.description;
    // Should mention "switch" or "persona" to indicate personality change
    try std.testing.expect(std.mem.indexOf(u8, desc, "switch") != null or
        std.mem.indexOf(u8, desc, "persona") != null or
        std.mem.indexOf(u8, desc, "different") != null);
}

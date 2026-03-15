const std = @import("std");
const get_agent = @import("get_agent.zig");
const GetAgentInput = get_agent.GetAgentInput;

test "GetAgentInput with agent_name" {
    const input = GetAgentInput{
        .agent_name = "test-agent",
    };

    try std.testing.expectEqualStrings("test-agent", input.agent_name.?);
}

test "GetAgentInput default values" {
    const input = GetAgentInput{};

    try std.testing.expect(input.agent_name == null);
    try std.testing.expect(input.path == null);
}

test "parseGetAgentInput parses valid JSON" {
    const allocator = std.testing.allocator;

    const json_str = "{\"agent_name\": \"specialized-coder\"}";
    const input = try get_agent.parseGetAgentInput(allocator, json_str);
    defer if (input.agent_name) |name| allocator.free(name);

    try std.testing.expectEqualStrings("specialized-coder", input.agent_name.?);
}

test "parseGetAgentInput parses JSON with path" {
    const allocator = std.testing.allocator;

    const json_str = "{\"agent_name\": \"code-reviewer\", \"path\": \"/some/path\"}";
    const input = try get_agent.parseGetAgentInput(allocator, json_str);
    defer if (input.agent_name) |name| allocator.free(name);
    defer if (input.path) |path| allocator.free(path);

    try std.testing.expectEqualStrings("code-reviewer", input.agent_name.?);
    try std.testing.expectEqualStrings("/some/path", input.path.?);
}

test "parseGetAgentInput handles empty JSON" {
    const allocator = std.testing.allocator;

    const json_str = "{}";
    const input = try get_agent.parseGetAgentInput(allocator, json_str);
    defer if (input.agent_name) |name| allocator.free(name);

    try std.testing.expect(input.agent_name == null);
}

test "parseGetAgentInput handles invalid JSON" {
    const allocator = std.testing.allocator;

    const json_str = "not valid json";
    const result = get_agent.parseGetAgentInput(allocator, json_str);

    try std.testing.expectError(error.InvalidJson, result);
}

test "executeGetAgentToString returns XML format" {
    const allocator = std.testing.allocator;

    // Create a temporary test agent file
    const test_dir = "/tmp/test_agents/test-agent";
    const test_file = "/tmp/test_agents/test-agent/AGENT.md";
    const test_content = "---\nname: test-agent\ndescription: \"A test agent\"\n---\n\n# Test Agent\n\nThis is test agent content.";

    // Create directory and write test file
    try std.fs.cwd().makePath(test_dir);
    const file = try std.fs.createFileAbsolute(test_file, .{});
    try file.writeAll(test_content);
    file.close();

    // Execute with agent_name
    const input = GetAgentInput{
        .agent_name = "test-agent",
        .path = null,
    };

    const result = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(result);

    // Cleanup
    std.fs.deleteFileAbsolute(test_file) catch {};
    std.fs.deleteDirAbsolute(test_dir) catch {};
    std.fs.deleteDirAbsolute("/tmp/test_agents") catch {};

    // Verify result contains expected XML structure
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent_name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<content>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>") != null);
}

test "executeGetAgentToString with path loads from file" {
    const allocator = std.testing.allocator;

    // Create a temporary test file
    const test_path = "/tmp/test_agent.md";
    const test_content = "---\nname: path-test-agent\ndescription: \"Test agent from path\"\n---\n\n# Path Test Agent";

    // Write test file
    const file = try std.fs.createFileAbsolute(test_path, .{});
    defer std.fs.deleteFileAbsolute(test_path) catch {};
    try file.writeAll(test_content);
    file.close();

    // Execute with path
    const input = GetAgentInput{
        .path = test_path,
        .agent_name = null,
    };

    const result = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(result);

    // Verify result contains expected XML structure
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent_name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "path-test-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<content>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>true</loaded>") != null);
}

test "executeGetAgentToString with invalid path returns error XML" {
    const allocator = std.testing.allocator;

    const input = GetAgentInput{
        .path = "/nonexistent/path/to/agent.md",
        .agent_name = null,
    };

    const result = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(result);

    // Verify result contains error
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>false</loaded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
}

test "executeGetAgentToString with non-existent agent_name returns error XML" {
    const allocator = std.testing.allocator;

    const input = GetAgentInput{
        .agent_name = "non-existent-agent-xyz123",
        .path = null,
    };

    const result = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(result);

    // Verify result contains error
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>false</loaded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<available_agents>") != null);
}

test "executeGetAgentToString with no input returns error" {
    const allocator = std.testing.allocator;

    const input = GetAgentInput{
        .agent_name = null,
        .path = null,
    };

    const result = get_agent.executeGetAgentToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "getAgentTool has correct definition" {
    const tool = get_agent.getAgentTool;

    try std.testing.expectEqualStrings("function", tool.type);
    try std.testing.expectEqualStrings("get_agent", tool.function.name);
    try std.testing.expect(std.mem.indexOf(u8, tool.function.description, "agent") != null);
    try std.testing.expectEqualStrings("object", tool.function.parameters.type);
}

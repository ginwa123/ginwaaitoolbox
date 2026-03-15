const std = @import("std");
const list_agents = @import("list_agents.zig");
const agents = @import("agents.zig");

test "listAgentsTool has correct structure" {
    // Verify tool definition
    try std.testing.expectEqualStrings("function", list_agents.listAgentsTool.type);
    try std.testing.expectEqualStrings("list_agents", list_agents.listAgentsTool.function.name);
    try std.testing.expectEqualStrings("object", list_agents.listAgentsTool.function.parameters.type);
    try std.testing.expectEqual(@as(usize, 0), list_agents.listAgentsTool.function.parameters.properties.len);
    try std.testing.expectEqual(@as(usize, 0), list_agents.listAgentsTool.function.parameters.required.len);
}

test "executeListAgents returns valid JSON" {
    const allocator = std.testing.allocator;

    const result = try list_agents.executeListAgents(allocator);
    defer allocator.free(result);

    // Verify result is valid JSON starting with {"agents":[
    try std.testing.expectStringStartsWith(result, "{\"agents\":[");
    try std.testing.expectStringEndsWith(result, "]}");
}

test "executeListAgents handles empty agents list" {
    const allocator = std.testing.allocator;

    const result = try list_agents.executeListAgents(allocator);
    defer allocator.free(result);

    // Should return {"agents":[]} when no agents exist
    try std.testing.expectEqualStrings("{\"agents\":[]}", result);
}

test "escapeJsonString escapes quotes" {
    const allocator = std.testing.allocator;

    const input = "Hello \"world\"";
    const result = list_agents.escapeJsonString(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello \\\"world\\\"", result);
}

test "escapeJsonString escapes backslashes" {
    const allocator = std.testing.allocator;

    const input = "path\\to\\file";
    const result = list_agents.escapeJsonString(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "escapeJsonString escapes newlines" {
    const allocator = std.testing.allocator;

    const input = "line1\nline2";
    const result = list_agents.escapeJsonString(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("line1\\nline2", result);
}

test "escapeJsonString escapes tabs" {
    const allocator = std.testing.allocator;

    const input = "col1\tcol2";
    const result = list_agents.escapeJsonString(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("col1\\tcol2", result);
}

test "escapeJsonString handles empty string" {
    const allocator = std.testing.allocator;

    const input = "";
    const result = list_agents.escapeJsonString(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "escapeJsonString handles string without special chars" {
    const allocator = std.testing.allocator;

    const input = "Hello World";
    const result = list_agents.escapeJsonString(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello World", result);
}

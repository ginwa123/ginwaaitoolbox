const std = @import("std");
const build_messages = @import("build_messages_for_agent_prompt.zig");
const workflow = @import("workflow.zig");
const tool_models = @import("nalarcore").tool_models;

// Test filterAndMergeTools with "all" - should return all tools
test "filterAndMergeTools - all tools allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try workflow.filterAndMergeTools(alloc, &[_]tool_models.AgentTool{}, "all");
    defer alloc.free(result);

    try std.testing.expect(result.len > 0);
}

// Test filterAndMergeTools with comma-separated list - filters base tools
test "filterAndMergeTools - filters to specific tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try workflow.filterAndMergeTools(alloc, &[_]tool_models.AgentTool{}, "read_file,glob");
    defer alloc.free(result);

    for (result) |tool| {
        const name = tool.function.name;
        try std.testing.expect(
            std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "glob"),
        );
    }
}

// Test filterAndMergeTools merges MCP tools with base tools
test "filterAndMergeTools - mcp tools are merged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const mcp_tool = tool_models.AgentTool{
        .type = "function",
        .function = tool_models.AgentToolFunction{
            .name = "mcp_server_tool",
            .description = "test mcp tool",
            .parameters = .{
                .type = "object",
                .properties = &[_]tool_models.ToolProperty{},
                .required = &[_][]const u8{},
            },
        },
    };

    const result = try workflow.filterAndMergeTools(alloc, &[_]tool_models.AgentTool{mcp_tool}, "all");
    defer alloc.free(result);

    const has_mcp_tool = for (result) |tool| {
        if (std.mem.eql(u8, tool.function.name, "mcp_server_tool")) break true;
    } else false;

    try std.testing.expect(has_mcp_tool);
}

// Test BuildSkillContent handles empty session_id
test "BuildSkillContent - empty session returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try build_messages.BuildSkillContent(alloc, undefined, "");
    defer alloc.free(result);

    try std.testing.expect(result.len == 0);
}

// Test BuildBackgroundProcessPrompt handles empty session_id
test "BuildBackgroundProcessPrompt - empty session returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try build_messages.BuildBackgroundProcessPrompt(alloc, undefined, "");
    defer alloc.free(result);

    try std.testing.expect(result.len == 0);
}

// Test BuildDynamicAgentContent handles empty session_id
test "BuildDynamicAgentContent - empty session returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try build_messages.BuildDynamicAgentContent(alloc, undefined, "");
    defer alloc.free(result);

    try std.testing.expect(result.len == 0);
}

// Test formatRelativeTime helper function
test "formatRelativeTime - various durations" {
    try std.testing.expectEqualStrings("< 1m", build_messages.formatRelativeTime(30));
    try std.testing.expectEqualStrings("1m", build_messages.formatRelativeTime(60));
    try std.testing.expectEqualStrings("5m", build_messages.formatRelativeTime(300));
    try std.testing.expectEqualStrings("1h", build_messages.formatRelativeTime(3600));
    try std.testing.expectEqualStrings("5h", build_messages.formatRelativeTime(7200));
    try std.testing.expectEqualStrings("12h+", build_messages.formatRelativeTime(43200));
    try std.testing.expectEqualStrings("> 24h", build_messages.formatRelativeTime(86400));
}
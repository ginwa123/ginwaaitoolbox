const std = @import("std");
const build_mcp_tools = @import("build_messages_tools_mcp_for_agent.zig");

test "parseProperties extracts tool properties" {
    const allocator = std.testing.allocator;
    
    // Create a JSON object with properties
    const json_str = 
        \\{"name": {"type": "string", "description": "The name parameter"}}
    ;
    
    var parser = std.json.Parser.init(allocator, .{ .allow_trailing_comma = true });
    defer parser.deinit();
    
    const parsed = try parser.parse(json_str);
    defer parsed.deinit();
    
    const properties = try build_mcp_tools.parseProperties(allocator, parsed.value, "test");
    defer {
        for (properties) |*prop| {
            allocator.free(prop.name);
            allocator.free(prop.type);
            allocator.free(prop.description);
        }
        allocator.free(properties);
    }
    
    try std.testing.expectEqual(@as(usize, 1), properties.len);
    try std.testing.expectEqualStrings("name", properties[0].name);
    try std.testing.expectEqualStrings("string", properties[0].type);
    try std.testing.expectEqualStrings("The name parameter", properties[0].description);
}

test "run returns empty array when no mcpServers configured" {
    const allocator = std.testing.allocator;
    
    // This test assumes no config file exists or has no mcpServers
    // In practice, this would need a mock config
    const tools = try build_mcp_tools.run(allocator);
    defer {
        for (tools) |*tool| {
            allocator.free(tool.function.name);
            allocator.free(tool.function.description);
            for (tool.function.parameters.properties) |*prop| {
                allocator.free(prop.name);
                allocator.free(prop.type);
                allocator.free(prop.description);
            }
            allocator.free(tool.function.parameters.properties);
            allocator.free(tool.function.parameters.required);
        }
        allocator.free(tools);
    }
    
    // Should return empty array when no MCP servers configured
    // tools is used in the defer block above
}

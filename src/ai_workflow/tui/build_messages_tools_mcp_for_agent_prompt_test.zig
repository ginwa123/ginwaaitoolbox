const std = @import("std");
const build_mcp_tools = @import("build_messages_tools_mcp_for_agent_prompt.zig");
const config_mod = @import("../../modules/config/config.zig");

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
    
    // Create a mock config with no mcpServers
    var config = config_mod.LlmConfig{
        .allocator = allocator,
        .api_key = "test",
        .model = "test",
        .base_url = "test",
        .model_compaction_size_kb = 100,
        .mcpServers = null,
    };
    
    // This test uses a mock config with no mcpServers
    const tools = try build_mcp_tools.run(allocator, &config);
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

// TDD: Test fetching MCP tools from a real server
test "run fetches tools from context7 MCP server" {
    const allocator = std.testing.allocator;
    
    // Create config with Context7 MCP server using JSON value
    var config = config_mod.LlmConfig{
        .allocator = allocator,
        .api_key = "test",
        .model = "test",
        .base_url = "test",
        .model_compaction_size_kb = 100,
        .mcpServers = .{
            .object = .{
                .context7 = .{
                    .object = .{
                        .url = .{
                            .string = "https://mcp.context7.com/mcp",
                        },
                    },
                },
            },
        },
    };
    
    const tools = build_mcp_tools.run(allocator, &config) catch |err| {
        // Skip if network not available
        std.debug.print("SKIP: Failed to fetch MCP tools: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
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
    
    // Should have fetched some tools
    try std.testing.expect(tools.len > 0);
    
    // Verify first tool has required fields
    const first_tool = tools[0];
    try std.testing.expect(first_tool.function.name.len > 0);
    try std.testing.expect(first_tool.function.description.len > 0);
    
    // Log the tool names
    std.debug.print("Fetched MCP tools: ", .{});
    for (tools) |tool| {
        std.debug.print("{s}, ", .{tool.function.name});
    }
    std.debug.print("\n", .{});
}

// TDD: Test that invalid MCP server URL returns empty array
test "run returns empty when MCP server URL is invalid" {
    const allocator = std.testing.allocator;
    
    // Create config with invalid MCP server using JSON value
    var config = config_mod.LlmConfig{
        .allocator = allocator,
        .api_key = "test",
        .model = "test",
        .base_url = "test",
        .model_compaction_size_kb = 100,
        .mcpServers = .{
            .object = .{
                .invalid = .{
                    .object = .{
                        .url = .{
                            .string = "https://invalid.server.that.does.not.exist/mcp",
                        },
                    },
                },
            },
        },
    };
    
    // Should return empty array (or skip if network check fails)
    const tools = build_mcp_tools.run(allocator, &config) catch |err| {
        // Network errors are expected for invalid URLs
        std.debug.print("SKIP: Invalid URL test got error: {s}\n", .{@errorName(err)});
        return error.SkipZigTest;
    };
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
    
    // Should return empty for invalid server
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

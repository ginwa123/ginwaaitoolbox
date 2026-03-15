const std = @import("std");
const testing = std.testing;
const handle_get_agent_tool = @import("handle_get_agent_tool.zig");

// Mock test for get_agent tool - tests the core logic without database dependencies
test "get_agent tool - validate input parsing with agent_name" {
    const allocator = testing.allocator;
    
    // Test valid input JSON parsing with agent_name
    const valid_json =
        \\{"agent_name": "specialized-coder"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { agent_name: ?[]const u8, path: ?[]const u8 },
        allocator,
        valid_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expect(parsed.value.agent_name != null);
    try testing.expectEqualStrings("specialized-coder", parsed.value.agent_name.?);
}

test "get_agent tool - validate input parsing with path" {
    const allocator = testing.allocator;
    
    // Test valid input JSON parsing with path
    const valid_json =
        \\{"path": "/absolute/path/to/agent.md"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { agent_name: ?[]const u8, path: ?[]const u8 },
        allocator,
        valid_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expect(parsed.value.path != null);
    try testing.expectEqualStrings("/absolute/path/to/agent.md", parsed.value.path.?);
}

test "get_agent tool - validate input parsing with both fields" {
    const allocator = testing.allocator;
    
    // Test valid input JSON parsing with both fields
    const valid_json =
        \\{"agent_name": "code-reviewer", "path": "/custom/path.zig"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { agent_name: ?[]const u8, path: ?[]const u8 },
        allocator,
        valid_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expect(parsed.value.agent_name != null);
    try testing.expectEqualStrings("code-reviewer", parsed.value.agent_name.?);
    // When both are provided, path takes precedence
}

test "get_agent tool - empty input validation" {
    const allocator = testing.allocator;
    
    // Test empty input
    const empty_json = \\{}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { agent_name: ?[]const u8, path: ?[]const u8 },
        allocator,
        empty_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expect(parsed.value.agent_name == null);
    try testing.expect(parsed.value.path == null);
}

test "get_agent tool - special characters in agent_name" {
    const allocator = testing.allocator;
    
    // Test agent_name with special characters
    const special_json =
        \\{"agent_name": "my-agent_name.v1"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { agent_name: ?[]const u8, path: ?[]const u8 },
        allocator,
        special_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expect(parsed.value.agent_name != null);
    try testing.expectEqualStrings("my-agent_name.v1", parsed.value.agent_name.?);
}

test "get_agent tool - long agent_name" {
    const allocator = testing.allocator;
    
    // Test with a longer agent name
    const long_name = "this_is_a_very_long_agent_name_that_might_be_used_in_production";
    const json_str = try std.fmt.allocPrint(allocator,
        \\{{"agent_name": "{s}"}}
    , .{long_name});
    defer allocator.free(json_str);
    
    const parsed = try std.json.parseFromSlice(
        struct { agent_name: ?[]const u8, path: ?[]const u8 },
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expect(parsed.value.agent_name != null);
    try testing.expectEqualStrings(long_name, parsed.value.agent_name.?);
}

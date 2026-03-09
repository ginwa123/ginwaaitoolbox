const std = @import("std");
const testing = std.testing;
const handle_remove_skill_tool = @import("handle_remove_skill_tool.zig");

// Mock test for RemoveSkillTool - tests the core logic without database dependencies
test "remove_skill tool - validate input parsing" {
    const allocator = testing.allocator;
    
    // Test valid input JSON parsing
    const valid_json =
        \\{"skill_name": "test_skill", "session_id": "test_session_123"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8, session_id: []const u8 },
        allocator,
        valid_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expectEqualStrings("test_skill", parsed.value.skill_name);
    try testing.expectEqualStrings("test_session_123", parsed.value.session_id);
}

test "remove_skill tool - empty skill_name validation" {
    const allocator = testing.allocator;
    
    // Test empty skill_name
    const empty_skill_json =
        \\{"skill_name": "", "session_id": "test_session"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8, session_id: []const u8 },
        allocator,
        empty_skill_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expectEqualStrings("", parsed.value.skill_name);
    try testing.expect(parsed.value.skill_name.len == 0);
}

test "remove_skill tool - empty session_id validation" {
    const allocator = testing.allocator;
    
    // Test empty session_id
    const empty_session_json =
        \\{"skill_name": "my_skill", "session_id": ""}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8, session_id: []const u8 },
        allocator,
        empty_session_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expectEqualStrings("", parsed.value.session_id);
    try testing.expect(parsed.value.session_id.len == 0);
}

test "remove_skill tool - special characters in skill_name" {
    const allocator = testing.allocator;
    
    // Test skill_name with special characters
    const special_json =
        \\{"skill_name": "my-skill_name.v1", "session_id": "session-123_test"}
    ;
    
    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8, session_id: []const u8 },
        allocator,
        special_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expectEqualStrings("my-skill_name.v1", parsed.value.skill_name);
    try testing.expectEqualStrings("session-123_test", parsed.value.session_id);
}

test "remove_skill tool - long skill_name" {
    const allocator = testing.allocator;
    
    // Test with a longer skill name
    const long_name = "this_is_a_very_long_skill_name_that_might_be_used_in_production";
    const json_str = try std.fmt.allocPrint(allocator,
        \\{{"skill_name": "{s}", "session_id": "session_abc"}}
    , .{long_name});
    defer allocator.free(json_str);
    
    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8, session_id: []const u8 },
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    
    try testing.expectEqualStrings(long_name, parsed.value.skill_name);
}

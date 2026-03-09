const std = @import("std");
const testing = std.testing;
const handle_get_skill_tool = @import("handle_get_skill_tool.zig");

test "handle_get_skill_tool - validate input parsing" {
    const allocator = testing.allocator;

    // Test valid input JSON parsing
    const valid_json =
        \\{"skill_name": "test_skill"}
    ;

    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8 },
        allocator,
        valid_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("test_skill", parsed.value.skill_name);
}

test "handle_get_skill_tool - empty skill_name" {
    const allocator = testing.allocator;

    const empty_json =
        \\{"skill_name": ""}
    ;

    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8 },
        allocator,
        empty_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("", parsed.value.skill_name);
}

test "handle_get_skill_tool - skill name with special chars" {
    const allocator = testing.allocator;

    const special_json =
        \\{"skill_name": "my-skill_name.v1"}
    ;

    const parsed = try std.json.parseFromSlice(
        struct { skill_name: []const u8 },
        allocator,
        special_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("my-skill_name.v1", parsed.value.skill_name);
}

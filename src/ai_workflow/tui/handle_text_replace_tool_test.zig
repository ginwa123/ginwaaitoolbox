const std = @import("std");
const testing = std.testing;
const handle_text_replace_tool = @import("handle_text_replace_tool.zig");

test "handle_text_replace_tool - validate input parsing" {
    const allocator = testing.allocator;

    // Test valid input JSON parsing
    const valid_json =
        \\{"path": "/test/file.txt", "old_str": "old text", "new_str": "new text"}
    ;

    const parsed = try std.json.parseFromSlice(
        struct { path: []const u8, old_str: []const u8, new_str: []const u8 },
        allocator,
        valid_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("/test/file.txt", parsed.value.path);
    try testing.expectEqualStrings("old text", parsed.value.old_str);
    try testing.expectEqualStrings("new text", parsed.value.new_str);
}

test "handle_text_replace_tool - empty strings" {
    const allocator = testing.allocator;

    const empty_json =
        \\{"path": "", "old_str": "", "new_str": ""}
    ;

    const parsed = try std.json.parseFromSlice(
        struct { path: []const u8, old_str: []const u8, new_str: []const u8 },
        allocator,
        empty_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("", parsed.value.path);
    try testing.expectEqualStrings("", parsed.value.old_str);
    try testing.expectEqualStrings("", parsed.value.new_str);
}

test "handle_text_replace_tool - special characters in content" {
    const allocator = testing.allocator;

    // Note: JSON strings need \" to represent a quote character
    const special_json = "{\"path\": \"/path/to/file.zig\", \"old_str\": \"const x = \\\"hello\\\";\", \"new_str\": \"const y = 'world';\"}";

    const parsed = try std.json.parseFromSlice(
        struct { path: []const u8, old_str: []const u8, new_str: []const u8 },
        allocator,
        special_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expectEqualStrings("/path/to/file.zig", parsed.value.path);
    try testing.expectEqualStrings("const x = \"hello\";", parsed.value.old_str);
    try testing.expectEqualStrings("const y = 'world';", parsed.value.new_str);
}

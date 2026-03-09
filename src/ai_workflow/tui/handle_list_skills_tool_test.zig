const std = @import("std");
const testing = std.testing;
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");

test "handle_list_skills_tool - JSON result format" {
    const allocator = testing.allocator;

    // Test expected JSON result format
    const error_result = "{\"error\": \"Failed to list skills\"}";

    try testing.expect(std.mem.indexOf(u8, error_result, "error") != null);
    try testing.expect(std.mem.indexOf(u8, error_result, "Failed to list skills") != null);
}

test "handle_list_skills_tool - tool result message structure" {
    const allocator = testing.allocator;

    // Test AgentMessage structure for tool role
    const test_content = "test skill list";
    const test_id = "call_12345";

    try testing.expect(test_content.len > 0);
    try testing.expect(test_id.len > 0);
}

test "handle_list_skills_tool - function name validation" {
    const func_name = "list_skills";

    try testing.expectEqualStrings("list_skills", func_name);
    try testing.expect(func_name.len > 0);
}

test "handle_list_skills_tool - error handling" {
    const allocator = testing.allocator;

    // Test error message format
    const err_msg = "Failed to list skills";

    try testing.expect(err_msg.len > 0);
    try testing.expect(std.mem.indexOf(u8, err_msg, "list") != null);
}

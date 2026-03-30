const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const handle_search_tool = @import("handle_search_tool.zig");

test "handle_search_tool_run returns warning for no matches" {
    const allocator = std.testing.allocator;
    
    // Create a temp file with content
    const test_path = "/tmp/search_handler_test_xyz789/test.txt";
    try std.fs.cwd().makePath("/tmp/search_handler_test_xyz789");
    defer _ = std.fs.cwd().deleteTree("/tmp/search_handler_test_xyz789") catch {};
    
    const test_file = try std.fs.cwd().createFile(test_path, .{});
    try test_file.writeAll("hello world\nfoo bar\n");
    test_file.close();
    
    // Create tool call with JSON arguments (manual string since no stringifyAlloc)
    const args = "{\"pattern\":\"definitely_no_match_xyz123456_UNIQUE_PATTERN_999\",\"path\":\"/tmp/search_handler_test_xyz789/test.txt\"}";
    
    const tool_call = agent.ToolCall{
        .id = "test-1",
        .type = "function",
        .function = .{
            .name = "search",
            .arguments = args,
        },
    };
    
    const result = try handle_search_tool.handle_search_tool_run(allocator, tool_call);
    defer allocator.free(result);
    
    // Verify warning XML is returned
    const is_warning = std.mem.indexOf(u8, result, "<warning>") != null;
    try std.testing.expect(is_warning);
    
    // And it contains "not found" text
    const has_not_found = std.mem.indexOf(u8, result, "not found") != null;
    try std.testing.expect(has_not_found);
}

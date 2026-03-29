const std = @import("std");
const testing = std.testing;
const agent = @import("nalarcore").agent;
const handle_write_file_tool_run = @import("handle_write_file_tool.zig").handle_write_file_tool_run;

test "handle_write_file_tool: returns sha256 on success" {
    const allocator = std.testing.allocator;
    const test_path = "test_sha256.txt";
    const test_content = "Hello";
    
    // Clean up
    std.fs.cwd().deleteFile(test_path) catch {};
    
    // Build JSON manually
    const json_args = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ test_path, test_content });
    defer allocator.free(json_args);
    
    const tool_call = agent.ToolCall{
        .id = "test",
        .type = "function",
        .function = .{
            .name = "write_file",
            .arguments = json_args,
        },
    };
    
    const result = try handle_write_file_tool_run(allocator, tool_call);
    defer allocator.free(result);
    
    try testing.expect(std.mem.indexOf(u8, result, "<sha256>") != null);
    
    // Clean up
    try std.fs.cwd().deleteFile(test_path);
}

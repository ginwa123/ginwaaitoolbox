const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const write_file_tool = tree1_mod.write_file;

/// Stateless write_file tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute write_file
/// Returns the write result as string or error.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_write_file_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Parse arguments JSON to WriteFileInput
    const parsed = try std.json.parseFromSlice(
        write_file_tool.WriteFileInput,
        allocator,
        tool_call.function.arguments,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Convert WriteFileInput to WriteFileOptions for the write_file function
    const opts = write_file_tool.WriteFileOptions{
        .content = parsed.value.content,
    };

    const write_result = try write_file_tool.write_file(allocator, parsed.value.path, opts);
    
    // Convert write result to string format
    const res_write = try write_file_tool.writeFileToString(allocator, write_result);
    // Caller is responsible for freeing this returned string
    write_result.deinit(allocator);
    
    return res_write;
}

test {
    _ = @import("handle_write_file_tool_test.zig");
}

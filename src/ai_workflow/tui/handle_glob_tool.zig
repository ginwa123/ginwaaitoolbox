const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const glob_tool = tree1_mod.glob_tool;

/// Stateless glob tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute glob
/// Returns the glob result as string or error.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_glob_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Handle empty arguments - treat as empty JSON object
    const args = tool_call.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    // Parse arguments JSON to GlobInput
    const parsed = try std.json.parseFromSlice(
        glob_tool.GlobInput,
        allocator,
        args_to_parse,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var glob_result = try glob_tool.executeGlob(allocator, parsed.value);
    
    // Convert glob result to string format
    const res_glob = try glob_tool.globResultToString(allocator, glob_result);
    // Caller is responsible for freeing this returned string
    // Also need to free the glob_result
    glob_result.deinit(allocator);
    
    return res_glob;
}

test {
    _ = @import("handle_glob_tool_test.zig");
}

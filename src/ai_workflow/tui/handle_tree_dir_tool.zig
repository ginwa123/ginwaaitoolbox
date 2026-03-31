const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const tree_dir_mod = tree1_mod.tree_dir;

/// Stateless tree_dir tool handler - only handles core logic:
/// 1. Parse arguments from tool_call.function.arguments
/// 2. Execute tree_dir
/// Returns the tree result as string or error.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_tree_dir_tool_run(
    allocator: std.mem.Allocator,
    tool_call: agent.ToolCall,
) ![]const u8 {
    // Handle empty arguments - treat as empty JSON object
    const args = tool_call.function.arguments;
    const args_to_parse: []const u8 = if (args.len == 0) "{}" else args;

    // Parse arguments JSON to TreeDirInput
    const parsed = try std.json.parseFromSlice(
        tree_dir_mod.TreeDirInput,
        allocator,
        args_to_parse,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    var tree_result = try tree_dir_mod.execute_tree_dir(allocator, parsed.value);
    defer tree_result.deinit(allocator);

    // Convert tree result to string format
    const res = try tree_dir_mod.tree_dir_result_to_string(allocator, tree_result);

    return res;
}

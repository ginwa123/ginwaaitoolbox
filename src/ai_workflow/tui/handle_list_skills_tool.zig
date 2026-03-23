const std = @import("std");
const tree1_mod = @import("nalarcore");
const list_skills_tool = tree1_mod.list_skills_tool;

/// Stateless list_skills tool handler - only handles core logic:
/// 1. Execute list_skills
/// Returns the result as string.
/// 
/// All side effects (DB, logging, socket, message list) must be handled by caller.
pub fn handle_list_skills_tool_run(
    allocator: std.mem.Allocator,
) []const u8 {
    const result = list_skills_tool.executeListSkills(allocator) catch blk: {
        break :blk "{\"error\": \"Failed to list skills\"}";
    };
    
    return result;
}

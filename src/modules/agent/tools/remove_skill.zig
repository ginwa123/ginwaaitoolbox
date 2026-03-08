const std = @import("std");
const ToolProperty = @import("models.zig").ToolProperty;
const ToolParameters = @import("models.zig").ToolParameters;
const AgentToolFunction = @import("models.zig").AgentToolFunction;
const AgentTool = @import("models.zig").AgentTool;

/// Input structure for remove_skill tool
pub const RemoveSkillInput = struct {
    skill_name: []const u8,
    session_id: []const u8,
};

/// Result structure for remove_skill tool
pub const RemoveSkillResult = struct {
    skill_name: []const u8,
    removed: bool,
    err_msg: ?[]const u8 = null,
};

/// Tool definition for remove_skill
pub const removeSkillTool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_skill",
        .description = "Remove a loaded skill from the current session. Use this to unload a skill that was previously loaded with get_skill",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to remove from the session",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID to remove the skill from",
                },
            },
            .required = &.{ "skill_name", "session_id" },
        },
    },
};

/// Execute the remove_skill tool - validation only
/// Actual database removal is handled in tui_workflow.zig
/// Returns a JSON string with validation result
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeRemoveSkill(
    allocator: std.mem.Allocator,
    input: RemoveSkillInput,
) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        const result = try std.fmt.allocPrint(allocator,
            \\{{
            \\"skill_name": "",
            \\"removed": false,
            \\"error": "skill_name cannot be empty"
            \\}}
        , .{});
        return result;
    }

    if (input.session_id.len == 0) {
        const result = try std.fmt.allocPrint(allocator,
            \\{{
            \\"skill_name": "{s}",
            \\"removed": false,
            \\"error": "session_id cannot be empty"
            \\}}
        , .{input.skill_name});
        return result;
    }

    // Return success - actual removal done in tui_workflow.zig
    const result = try std.fmt.allocPrint(allocator,
        \\{{
        \\"skill_name": "{s}",
        \\"removed": true
        \\}}
    , .{input.skill_name});

    return result;
}

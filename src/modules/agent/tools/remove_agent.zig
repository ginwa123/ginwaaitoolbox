const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for remove_agent tool
pub const RemoveAgentInput = struct {
    /// Agent name to delete
    name: []const u8,
    /// Session ID (kept for compatibility)
    session_id: []const u8,
};

/// Tool definition for remove_agent
pub const remove_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_agent",
        .description = "Remove and delete an agent from .nalar/agents/. Use this to permanently remove a custom agent persona.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The exact name of the agent to delete from .nalar/agents/",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID (unused, kept for compatibility)",
                },
            },
            .required = &.{ "name", "session_id" },
        },
    },
};

/// Execute the remove_agent tool - deletes agent directory from .nalar/agents/
/// Returns an XML string with result
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeRemoveAgentToString(
    allocator: std.mem.Allocator,
    input: RemoveAgentInput,
) ![]const u8 {
    // Validate input
    if (input.name.len == 0) {
        return error.InvalidInput;
    }

    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<name></name>
            \\<removed>false</removed>
            \\<error>Failed to get current working directory</error>
        , .{});
        return result;
    };

    // Build path to agent directory: .nalar/agents/<name>/
    const agent_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "agents", input.name });
    defer allocator.free(agent_dir_path);

    // Check if the agent directory exists
    const dir_exists = blk: {
        std.fs.cwd().access(agent_dir_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!dir_exists) {
        // Agent directory doesn't exist
        const result = try std.fmt.allocPrint(allocator,
            \\<name>{s}</name>
            \\<removed>false</removed>
            \\<error>Agent directory not found in .nalar/agents/</error>
        , .{input.name});
        return result;
    }

    // Delete the agent directory recursively
    std.fs.deleteTreeAbsolute(agent_dir_path) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<name>{s}</name>
            \\<removed>false</removed>
            \\<error>Failed to delete agent directory</error>
        , .{input.name});
        return result;
    };

    // Return success
    const result = try std.fmt.allocPrint(allocator,
        \\<name>{s}</name>
        \\<removed>true</removed>
        \\<path>{s}</path>
    , .{ input.name, agent_dir_path });

    return result;
}

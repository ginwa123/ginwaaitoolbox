const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for add_agent tool
pub const AddAgentInput = struct {
    /// Agent identifier (required)
    name: []const u8,
    /// Agent description (required)
    description: []const u8,
    /// Agent body content (required)
    content: []const u8,
    /// Auto-create .nalar/agents directory if needed (default: true)
    create_with_dir: bool = true,
};

/// Tool definition for add_agent
pub const add_agent_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_agent",
        .description = "Create a new agent definition file. Use this when the user wants to create a custom agent persona with specialized capabilities.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The unique identifier name for the agent (e.g., 'code-reviewer', 'frontend-engineer')",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "Brief description of what this agent specializes in or when to use it",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The full agent content/markdown body with instructions and capabilities",
                },
            },
            .required = &.{ "name", "description", "content" },
        },
    },
};

/// Execute the add_agent tool
/// Creates a new agent file at .nalar/agents/<name>/AGENT.MD
/// Returns an XML string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_add_agent_to_string(allocator: std.mem.Allocator, input: AddAgentInput) ![]const u8 {
    // Validate input
    if (input.name.len == 0) return error.InvalidInput;
    if (input.description.len == 0) return error.InvalidInput;
    if (input.content.len == 0) return error.InvalidInput;

    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        return try error_to_xml(allocator, input.name, "Failed to get current working directory");
    };

    // Build paths
    const agents_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "agents" });
    defer allocator.free(agents_dir);

    const agent_dir = try std.fs.path.join(allocator, &[_][]const u8{ agents_dir, input.name });
    defer allocator.free(agent_dir);

    const agent_file = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "AGENT.MD" });
    defer allocator.free(agent_file);

    // Create directories if needed
    if (input.create_with_dir) {
        std.fs.cwd().makePath(agent_dir) catch {
            return try error_to_xml(allocator, input.name, "Failed to create agent directory");
        };
    }

    // Build agent content with YAML frontmatter
    const file_content = try build_agent_content(allocator, input);
    defer allocator.free(file_content);

    // Write the file
    const file = std.fs.createFileAbsolute(agent_file, .{}) catch {
        return try error_to_xml(allocator, input.name, "Failed to create agent file");
    };
    defer file.close();

    file.writeAll(file_content) catch {
        return try error_to_xml(allocator, input.name, "Failed to write agent file");
    };

    // Return success XML
    return try success_to_xml(allocator, input.name, agent_file);
}

/// Build agent file content with YAML frontmatter
fn build_agent_content(allocator: std.mem.Allocator, input: AddAgentInput) ![]const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = try escape_yaml_string(allocator, input.description);
    defer allocator.free(escaped_desc);

    // Build the content: frontmatter + separator + content
    const total_len = 15 + input.name.len + 16 + escaped_desc.len + 5 + input.content.len + 1;
    var result = try std.ArrayList(u8).initCapacity(allocator, total_len);
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, "name: ");
    try result.appendSlice(allocator, input.name);
    try result.appendSlice(allocator, "\n");
    try result.appendSlice(allocator, "description: \"");
    try result.appendSlice(allocator, escaped_desc);
    try result.appendSlice(allocator, "\"\n");
    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, input.content);
    try result.append(allocator, '\n');

    return result.toOwnedSlice(allocator);
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn escape_yaml_string(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var needs_escape = false;

    // Check if escaping is needed
    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s);
    }

    // Build escaped string
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            else => try result.append(allocator, c),
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate success XML response
fn success_to_xml(allocator: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<agent>
        \\<name>{s}</name>
        \\<created>true</created>
        \\<path>{s}</path>
        \\</agent>
    , .{ name, path });
}

/// Generate error XML response
fn error_to_xml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<agent>
        \\<name>{s}</name>
        \\<created>false</created>
        \\<error>{s}</error>
        \\</agent>
    , .{ name, error_msg });
}

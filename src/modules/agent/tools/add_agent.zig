const std = @import("std");
const schemas = @import("schemas.zig");
const nalarcore = @import("nalarcore");
const helpers = nalarcore.helpers;
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
pub fn executeAddAgentToString(allocator: std.mem.Allocator, input: AddAgentInput) ![]const u8 {
    // Validate input
    if (input.name.len == 0) return error.InvalidInput;
    if (input.description.len == 0) return error.InvalidInput;
    if (input.content.len == 0) return error.InvalidInput;

    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    // `std.posix.getcwd` was removed in Zig 0.16. Use the cross-platform
    // `helpers.getcwd` wrapper (libc-backed; works on Linux/macOS/Windows
    // without an `io: std.Io` runtime).
    const cwd = helpers.getcwd(&cwd_buf) orelse {
        return errorToXml(allocator, input.name, "Failed to get current working directory");
    };

    // Build paths
    const agents_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "agents" });
    defer allocator.free(agents_dir);

    // Duplicate name to ensure no aliasing with path.join's internal buffer allocation
    const name_copy = try allocator.dupe(u8, input.name);
    defer allocator.free(name_copy);

    const agent_dir = try std.fs.path.join(allocator, &[_][]const u8{ agents_dir, name_copy });
    defer allocator.free(agent_dir);

    const agent_file = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "AGENT.MD" });
    defer allocator.free(agent_file);

    // Create directories if needed
    if (input.create_with_dir) {
        std.fs.cwd().makePath(agent_dir) catch {
            return errorToXml(allocator, input.name, "Failed to create agent directory");
        };
    }

    // Build agent content with YAML frontmatter
    const file_content = try buildAgentContent(allocator, input);
    defer allocator.free(file_content);

    // Write the file
    const file = std.fs.createFileAbsolute(agent_file, .{}) catch {
        return errorToXml(allocator, input.name, "Failed to create agent file");
    };
    defer file.close();

    file.writeAll(file_content) catch {
        return errorToXml(allocator, input.name, "Failed to write agent file");
    };

    // Return success XML
    return try successToXml(allocator, input.name, agent_file);
}

/// Build agent file content with YAML frontmatter
fn buildAgentContent(allocator: std.mem.Allocator, input: AddAgentInput) ![]const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = try escapeYamlString(allocator, input.description);
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
fn escapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
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
fn successToXml(allocator: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "<agent>\n<name>");
    try appendXmlContent(allocator, &result, name);
    try result.appendSlice(allocator, "</name>\n<created>true</created>\n<path>");
    try appendXmlContent(allocator, &result, path);
    try result.appendSlice(allocator, "</path>\n</agent>");

    return try result.toOwnedSlice(allocator);
}

/// Internal error-to-XML helper (doesn't return error)
fn errorToXml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<agent>\n<name>") catch return "";
    appendXmlContent(allocator, &result, name) catch return "";
    result.appendSlice(allocator, "</name>\n<created>false</created>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>\n</agent>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    return errorToXml(allocator, name, error_msg);
}

/// Generate error XML response for parse failures (no name available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    result.appendSlice(allocator, "<agent>\n<name></name>\n<created>false</created>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>\n</agent>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Append XML-safe content to an ArrayList
fn appendXmlContent(allocator: std.mem.Allocator, result: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try result.appendSlice(allocator, "&lt;"),
            '>' => try result.appendSlice(allocator, "&gt;"),
            '&' => try result.appendSlice(allocator, "&amp;"),
            '"' => try result.appendSlice(allocator, "&quot;"),
            '\'' => try result.appendSlice(allocator, "&apos;"),
            else => try result.append(allocator, c),
        }
    }
}

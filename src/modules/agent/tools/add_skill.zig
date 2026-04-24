const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for add_skill tool
pub const AddSkillInput = struct {
    /// Skill identifier (required)
    name: []const u8,
    /// When to trigger this skill (required)
    description: []const u8,
    /// Skill body content (required)
    content: []const u8,
    /// Auto-create .nalar/skills directory if needed (default: true)
    create_with_dir: bool = true,
};

/// Tool definition for add_skill
pub const add_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "add_skill",
        .description = "Create a new skill file in the skills directory. Use this when the user wants to save a workflow, pattern, or reusable instructions as a skill for future use.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "name",
                    .type = "string",
                    .description = "The unique identifier name for the skill (e.g., 'my-workflow', 'code-review-pattern')",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "When to use this skill - describe the trigger conditions and what the skill accomplishes",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "The full skill content/markdown body that will be loaded when the skill is invoked",
                },
            },
            .required = &.{ "name", "description", "content" },
        },
    },
};

/// Execute the add_skill tool
/// Creates a new skill file at .nalar/skills/<name>/SKILL.MD
/// Returns an XML string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeAddSkillToString(allocator: std.mem.Allocator, input: AddSkillInput) ![]const u8 {
    // Validate input
    if (input.name.len == 0) return error.InvalidInput;
    if (input.description.len == 0) return error.InvalidInput;
    if (input.content.len == 0) return error.InvalidInput;

    // Get current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch {
        return errorToXml(allocator, input.name, "Failed to get current working directory");
    };

    // Build paths
    const skills_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" });
    defer allocator.free(skills_dir);

    const skill_dir = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, input.name });
    defer allocator.free(skill_dir);

    const skill_file = try std.fs.path.join(allocator, &[_][]const u8{ skill_dir, "SKILL.MD" });
    defer allocator.free(skill_file);

    // Create directories if needed
    if (input.create_with_dir) {
        std.fs.cwd().makePath(skill_dir) catch {
            return errorToXml(allocator, input.name, "Failed to create skill directory");
        };
    }

    // Build skill content with YAML frontmatter
    const file_content = try buildSkillContent(allocator, input);
    defer allocator.free(file_content);

    // Write the file
    const file = std.fs.createFileAbsolute(skill_file, .{}) catch {
        return errorToXml(allocator, input.name, "Failed to create skill file");
    };
    defer file.close();

    file.writeAll(file_content) catch {
        return errorToXml(allocator, input.name, "Failed to write skill file");
    };

    // Return success XML
    return try successToXml(allocator, input.name, skill_file);
}

/// Build skill file content with YAML frontmatter
fn buildSkillContent(allocator: std.mem.Allocator, input: AddSkillInput) ![]const u8 {
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
    return try std.fmt.allocPrint(allocator,
        \\<skill>
        \\<name>{s}</name>
        \\<created>true</created>
        \\<path>{s}</path>
        \\</skill>
    , .{ name, path });
}

/// Internal error-to-XML helper (doesn't return error)
fn errorToXml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<skill>
        \\<name>{s}</name>
        \\<created>false</created>
        \\<error>{s}</error>
        \\</skill>
    , .{ name, error_msg }) catch "<skill><name></name><created>false</created><error>UnknownError</error></skill>";
}

/// Generate error XML response
pub fn xmlError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    return errorToXml(allocator, name, error_msg);
}

/// Generate error XML response for parse failures (no name available)
pub fn xmlErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<skill>
        \\<name></name>
        \\<created>false</created>
        \\<error>{s}</error>
        \\</skill>
    , .{error_msg}) catch "<skill><name></name><created>false</created><error>UnknownError</error></skill>";
}

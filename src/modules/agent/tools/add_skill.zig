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
pub fn executeAddSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, input: AddSkillInput) []const u8 {
    // Validate input
    if (input.name.len == 0) return errorToXml(allocator, input.name, "Skill name cannot be empty");
    if (input.description.len == 0) return errorToXml(allocator, input.name, "Description cannot be empty");
    if (input.content.len == 0) return errorToXml(allocator, input.name, "Content cannot be empty");

    // Use cwd from context (already absolute path from session)
    const skills_dir = std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" }) catch {
        return xmlError(allocator, input.name, "Failed to build skills directory path");
    };
    defer allocator.free(skills_dir);

    const skill_dir = std.fs.path.join(allocator, &[_][]const u8{ skills_dir, input.name }) catch {
        return xmlError(allocator, input.name, "Failed to build skill directory path");
    };
    defer allocator.free(skill_dir);

    const skill_file = std.fs.path.join(allocator, &[_][]const u8{ skill_dir, "SKILL.MD" }) catch {
        return xmlError(allocator, input.name, "Failed to build skill file path");
    };
    defer allocator.free(skill_file);

    // Create directories if needed using std.io.Dir
    if (input.create_with_dir) {
        const cwd_dir = std.Io.Dir.cwd();
        cwd_dir.createDirPath(io, skill_dir) catch {
            return xmlError(allocator, input.name, "Failed to create skill directory");
        };
    }

    // Build skill content with YAML frontmatter
    const file_content = buildSkillContent(allocator, input);
    defer allocator.free(file_content);
    if (file_content.len == 0) {
        return xmlError(allocator, input.name, "Failed to build skill content");
    }

    // Write the file using absolute path with Io.Dir
    const file = std.Io.Dir.createFileAbsolute(io, skill_file, .{}) catch {
        return xmlError(allocator, input.name, "Failed to create skill file");
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, file_content) catch {
        return xmlError(allocator, input.name, "Failed to write skill file");
    };

    // Return success XML
    return successToXml(allocator, input.name, skill_file);
}

/// Build skill file content with YAML frontmatter
pub fn buildSkillContent(allocator: std.mem.Allocator, input: AddSkillInput) []const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = escapeYamlString(allocator, input.description);
    defer allocator.free(escaped_desc);

    // Build the content: frontmatter + separator + content
    const total_len = 15 + input.name.len + 16 + escaped_desc.len + 5 + input.content.len + 1;
    var result = std.ArrayList(u8).initCapacity(allocator, total_len) catch return "";
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, "name: ") catch return "";
    result.appendSlice(allocator, input.name) catch return "";
    result.appendSlice(allocator, "\n") catch return "";
    result.appendSlice(allocator, "description: \"") catch return "";
    result.appendSlice(allocator, escaped_desc) catch return "";
    result.appendSlice(allocator, "\"\n") catch return "";
    result.appendSlice(allocator, "---\n") catch return "";
    result.appendSlice(allocator, input.content) catch return "";
    result.append(allocator, '\n') catch return "";

    return result.toOwnedSlice(allocator) catch return "";
}

/// Escape special characters in a YAML string value
/// Handles: double quotes, backslashes
fn escapeYamlString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var needs_escape = false;

    // Check if escaping is needed
    for (s) |c| {
        if (c == '"' or c == '\\') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return allocator.dupe(u8, s) catch return s;
    }

    // Build escaped string
    var result = std.ArrayList(u8).initCapacity(allocator, s.len + 16) catch return s;
    errdefer result.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => result.appendSlice(allocator, "\\\"") catch return s,
            '\\' => result.appendSlice(allocator, "\\\\") catch return s,
            else => result.append(allocator, c) catch return s,
        }
    }

    return result.toOwnedSlice(allocator) catch return s;
}

/// Generate success XML response
fn successToXml(allocator: std.mem.Allocator, name: []const u8, path: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<skill>
        \\<name>{s}</name>
        \\<created>true</created>
        \\<path>{s}</path>
        \\</skill>
    , .{ name, path }) catch "<skill><name></name><created>false</created><error>UnknownError</error></skill>";
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

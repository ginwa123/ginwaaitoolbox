const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for add_skill tool
pub const AddSkillInput = struct {
    /// Skill identifier (required)
    name: []const u8,
    /// When to trigger this skill (required)
    description: []const u8,
    /// Skill body content (required)
    content: []const u8,
    /// Auto-create skills directory if needed (default: true)
    create_with_dir: bool = true,
    /// If true, save to global skills directory (~/.config/nalar/skills/)
    /// If false, save to local skills directory (.nalar/skills/)
    is_global: bool = false,
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
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, save to global skills directory (~/.config/nalar/skills/). If false, save to local directory (.nalar/skills/). Default: false",
                },
            },
            .required = &.{ "name", "description", "content" },
        },
    },
};

/// Execute the add_skill tool
/// Creates a new skill file at .nalar/skills/<name>/SKILL.MD or global ~/.config/nalar/skills/<name>/SKILL.MD
/// Returns an XML string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeAddSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, environment: ?*const std.process.Environ.Map, input: AddSkillInput) []const u8 {
    // Validate input
    if (input.name.len == 0) return errorToXml(allocator, input.name, "Skill name cannot be empty");
    if (input.description.len == 0) return errorToXml(allocator, input.name, "Description cannot be empty");
    if (input.content.len == 0) return errorToXml(allocator, input.name, "Content cannot be empty");

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global)
        blk: {
            if (environment) |env| {
                const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                    return xmlError(allocator, input.name, "Failed to get global skills path");
                };
                break :blk path;
            } else {
                return xmlError(allocator, input.name, "Environment not available for global skills");
            }
        }
    else
        std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" }) catch {
            return xmlError(allocator, input.name, "Failed to build skills directory path");
        };
    // skills_dir is heap-allocated in both branches (global via get_global_skills_path_from_env,
    // local via path.join). Free it once at the end of the function via a single defer.
    defer allocator.free(skills_dir);

    // Duplicate input.name to ensure no aliasing with path.join's internal buffer allocation
    const name_copy = allocator.dupe(u8, input.name) catch {
        return xmlError(allocator, input.name, "Failed to allocate memory for skill name");
    };
    defer allocator.free(name_copy);

    const skill_dir = std.fs.path.join(allocator, &[_][]const u8{ skills_dir, name_copy }) catch {
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
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<skill>\n<name>") catch return "";
    appendXmlContent(allocator, &result, name) catch return "";
    result.appendSlice(allocator, "</name>\n<created>true</created>\n<path>") catch return "";
    appendXmlContent(allocator, &result, path) catch return "";
    result.appendSlice(allocator, "</path>\n</skill>") catch return "";

    return result.toOwnedSlice(allocator) catch "";
}

/// Internal error-to-XML helper (doesn't return error)
fn errorToXml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<skill>\n<name>") catch return "";
    appendXmlContent(allocator, &result, name) catch return "";
    result.appendSlice(allocator, "</name>\n<created>false</created>\n<error>") catch return "";
    appendXmlContent(allocator, &result, error_msg) catch return "";
    result.appendSlice(allocator, "</error>\n</skill>") catch return "";

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

const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;

/// Input structure for edit_skill tool
pub const EditSkillInput = struct {
    /// Skill identifier (required)
    skill_name: []const u8,
    /// New description (optional - omit to keep existing)
    description: ?[]const u8 = null,
    /// New skill content (optional - omit to keep existing)
    content: ?[]const u8 = null,
};

/// Tool definition for edit_skill
pub const edit_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "edit_skill",
        .description = "Edit an existing skill file. Updates the description and/or content of a skill. At least one of description or content must be provided.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to edit (e.g., 'my-workflow')",
                },
                .{
                    .name = "description",
                    .type = "string",
                    .description = "New description for the skill - when to use this skill and what it accomplishes",
                },
                .{
                    .name = "content",
                    .type = "string",
                    .description = "New skill content/markdown body that will be loaded when the skill is invoked",
                },
            },
            .required = &.{ "skill_name" },
        },
    },
};

/// Execute the edit_skill tool
/// Updates an existing skill file at .nalar/skills/<skill_name>/SKILL.MD
/// Returns an XML string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeEditSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, input: EditSkillInput) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        return errorToXml(allocator, input.skill_name, "Skill name cannot be empty");
    }

    // At least one of description or content must be provided
    if (input.description == null and input.content == null) {
        return errorToXml(allocator, input.skill_name, "At least one of description or content must be provided");
    }

    // Use cwd from context (already absolute path from session)
    // Build path to skill file
    const skill_file = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills", input.skill_name, "SKILL.MD" });
    defer allocator.free(skill_file);

    // Check if the skill file exists
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_file, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!file_exists) {
        return errorToXml(allocator, input.skill_name, "Skill file not found in .nalar/skills/");
    }

    // Read existing skill content
    const existing_content = std.Io.Dir.cwd().readFileAlloc(io, skill_file, allocator, std.Io.Limit.limited(1024 * 1024)) catch {
        return errorToXml(allocator, input.skill_name, "Failed to read existing skill file");
    };
    defer allocator.free(existing_content);

    // Parse existing skill and extract current values
    const parsed = try parseSkillFile(allocator, existing_content);
    defer {
        allocator.free(parsed.description);
        allocator.free(parsed.content);
    }

    // Use new values or existing ones
    const new_description = input.description orelse parsed.description;
    const new_content = input.content orelse parsed.content;

    // Build updated skill content with YAML frontmatter
    const updated_content = try buildSkillContent(allocator, input.skill_name, new_description, new_content);
    errdefer allocator.free(updated_content);

    // Write the updated file
    const file = std.Io.Dir.createFileAbsolute(io, skill_file, .{}) catch {
        return errorToXml(allocator, input.skill_name, "Failed to create skill file for writing");
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, updated_content) catch {
        return errorToXml(allocator, input.skill_name, "Failed to write skill file");
    };

    // Return success XML
    return try successToXml(allocator, input.skill_name, skill_file);
}

/// Parsed skill file structure
const ParsedSkill = struct {
    description: []const u8,
    content: []const u8,
};

fn parseSkillFile(allocator: std.mem.Allocator, file_content: []const u8) !ParsedSkill {
    var result = ParsedSkill{
        .description = try allocator.dupe(u8, ""),
        .content = try allocator.dupe(u8, ""),
    };
    errdefer {
        allocator.free(result.description);
        allocator.free(result.content);
    }

    // Find frontmatter boundaries
    const frontmatter_start = std.mem.indexOf(u8, file_content, "---\n") orelse {
        // No frontmatter - treat entire content as content
        result.content = try allocator.dupe(u8, file_content);
        return result;
    };

    const frontmatter_end = std.mem.indexOf(u8, file_content[frontmatter_start + 4..], "---\n") orelse {
        // Malformed frontmatter
        result.content = try allocator.dupe(u8, file_content);
        return result;
    };

    const frontmatter = file_content[frontmatter_start + 4 .. frontmatter_start + 4 + frontmatter_end];

    // Parse frontmatter
    var current_key: ?[]const u8 = null;
    var in_string = false;
    var string_start: usize = 0;

    var i: usize = 0;
    while (i < frontmatter.len) : (i += 1) {
        const c = frontmatter[i];

        if (in_string) {
            if (c == '"') {
                // End of string
                in_string = false;
                const value = frontmatter[string_start..i];

                if (current_key) |key| {
                    if (std.mem.eql(u8, key, "description")) {
                        allocator.free(result.description);
                        result.description = try unescapeYamlString(allocator, value);
                    }
                }

                current_key = null;
            }
        } else {
            if (c == ':') {
                // End of key
                const key_start = if (i > 0 and frontmatter[i - 1] == ' ') i - 2 else i;
                current_key = std.mem.trim(u8, frontmatter[key_start..i], ": ");
                // Skip whitespace and opening quote
                var j = i + 1;
                while (j < frontmatter.len and (frontmatter[j] == ' ' or frontmatter[j] == '\t')) j += 1;
                if (j < frontmatter.len and frontmatter[j] == '"') {
                    in_string = true;
                    string_start = j + 1;
                    i = j;
                }
            } else if (c == '\n') {
                current_key = null;
            }
        }
    }

    // Get content after frontmatter
    const after_frontmatter = frontmatter_start + 4 + frontmatter_end + 4;
    if (after_frontmatter < file_content.len) {
        allocator.free(result.content);
        result.content = try allocator.dupe(u8, std.mem.trim(u8, file_content[after_frontmatter..], "\n"));
    }

    return result;
}

/// Build skill file content with YAML frontmatter
fn buildSkillContent(allocator: std.mem.Allocator, name: []const u8, description: []const u8, content: []const u8) ![]const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = try escapeYamlString(allocator, description);
    defer allocator.free(escaped_desc);

    // Build the content: frontmatter + separator + content
    const total_len = 15 + name.len + 16 + escaped_desc.len + 5 + content.len + 1;
    var result = try std.ArrayList(u8).initCapacity(allocator, total_len);
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, "name: ");
    try result.appendSlice(allocator, name);
    try result.appendSlice(allocator, "\n");
    try result.appendSlice(allocator, "description: \"");
    try result.appendSlice(allocator, escaped_desc);
    try result.appendSlice(allocator, "\"\n");
    try result.appendSlice(allocator, "---\n");
    try result.appendSlice(allocator, content);
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

/// Unescape YAML string (reverse of escapeYamlString)
fn unescapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const needs_unescape = std.mem.indexOf(u8, s, "\\") != null;

    if (!needs_unescape) {
        return allocator.dupe(u8, s);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, s[i]);
                    continue;
                },
            }
        } else {
            try result.append(allocator, s[i]);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Generate success XML response
fn successToXml(allocator: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\<skill>
        \\<name>{s}</name>
        \\<edited>true</edited>
        \\<path>{s}</path>
        \\</skill>
    , .{ name, path });
}

/// Internal error-to-XML helper (doesn't return error)
fn errorToXml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator,
        \\<skill>
        \\<name>{s}</name>
        \\<edited>false</edited>
        \\<error>{s}</error>
        \\</skill>
    , .{ name, error_msg }) catch "<skill><name></name><edited>false</edited><error>UnknownError</error></skill>";
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
        \\<edited>false</edited>
        \\<error>{s}</error>
        \\</skill>
    , .{error_msg}) catch "<skill><name></name><edited>false</edited><error>UnknownError</error></skill>";
}

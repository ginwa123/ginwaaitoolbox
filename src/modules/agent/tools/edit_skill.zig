const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for edit_skill tool
pub const EditSkillInput = struct {
    /// Skill identifier (required)
    skill_name: []const u8,
    /// New description (optional - omit to keep existing)
    description: ?[]const u8 = null,
    /// New skill content (optional - omit to keep existing)
    content: ?[]const u8 = null,
    /// If true, edit in global skills directory (~/.config/nalar/skills/)
    /// If false, edit in local skills directory (.nalar/skills/)
    is_global: bool = false,
};

/// Tool definition for edit_skill
pub const edit_skill_tool_system_prompt =
    \\## Edit Skill Tool — Behavior
    \\Use `edit_skill` to update an existing skill's description or body.
    \\- Provide `skill_name` and new `description`/`content`. Use to fix or improve a skill after learning a better approach.
    \\
;

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
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, edit in global skills directory (~/.config/nalar/skills/). If false, edit in local directory (.nalar/skills/). Default: false",
                },
            },
            .required = &.{ "skill_name" },
        },
        .system_prompt = edit_skill_tool_system_prompt,
    },
};

/// Execute the edit_skill tool
/// Updates an existing skill file at .nalar/skills/<skill_name>/SKILL.MD or global ~/.config/nalar/skills/<skill_name>/SKILL.MD
/// Returns an XML string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeEditSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, environment: ?*const std.process.Environ.Map, input: EditSkillInput) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        return errorToXml(allocator, input.skill_name, "Skill name cannot be empty");
    }

    // At least one of description or content must be provided
    if (input.description == null and input.content == null) {
        return errorToXml(allocator, input.skill_name, "At least one of description or content must be provided");
    }

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global)
        blk: {
            if (environment) |env| {
                const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                    return errorToXml(allocator, input.skill_name, "Failed to get global skills path");
                };
                break :blk path;
            } else {
                return errorToXml(allocator, input.skill_name, "Environment not available for global skills");
            }
        }
    else
        try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" });
    // skills_dir is heap-allocated in both branches (global via get_global_skills_path_from_env,
    // local via path.join). Free it once at the end of the function via a single defer.
    defer allocator.free(skills_dir);

    // Build path to skill file
    // Duplicate skill_name to ensure no aliasing with path.join's internal buffer allocation
    const skill_name_copy = try allocator.dupe(u8, input.skill_name);
    defer allocator.free(skill_name_copy);

    const skill_file = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, skill_name_copy, "SKILL.MD" });
    defer allocator.free(skill_file);

    // Check if the skill file exists
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_file, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!file_exists) {
        return errorToXml(allocator, input.skill_name, "Skill file not found");
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
    defer allocator.free(updated_content);

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
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "<skill>\n<name>");
    try appendXmlContent(allocator, &result, name);
    try result.appendSlice(allocator, "</name>\n<edited>true</edited>\n<path>");
    try appendXmlContent(allocator, &result, path);
    try result.appendSlice(allocator, "</path>\n</skill>");

    return try result.toOwnedSlice(allocator);
}

/// Internal error-to-XML helper (doesn't return error)
fn errorToXml(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    // Build XML using ArrayList to avoid issues with null-terminated strings
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    result.appendSlice(allocator, "<skill>\n<name>") catch return "";
    appendXmlContent(allocator, &result, name) catch return "";
    result.appendSlice(allocator, "</name>\n<edited>false</edited>\n<error>") catch return "";
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
        \\<edited>false</edited>
        \\<error>{s}</error>
        \\</skill>
    , .{error_msg}) catch "<skill><name></name><edited>false</edited><error>UnknownError</error></skill>";
}

const edit_skill_mod = @import("edit_skill.zig");

test "edit_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = edit_skill_mod.EditSkillInput{
        .skill_name = "",
        .description = try alloc.dupe(u8, "New description"),
        .content = null,
        .is_global = false,
    };
    defer alloc.free(input.description.?);

    const io = std.testing.io;
    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>false</edited>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Skill name cannot be empty") != null);
}

test "edit_skill - neither description nor content provided returns error" {
    const alloc = std.testing.allocator;

    const input = edit_skill_mod.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>false</edited>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "At least one of description or content must be provided") != null);
}

test "edit_skill - tool definition includes is_global parameter" {
    const tool_def = edit_skill_mod.edit_skill_tool;

    // Find is_global in the properties
    var found_is_global = false;
    inline for (tool_def.function.parameters.properties) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expect(std.mem.eql(u8, prop.type, "boolean"));
        }
    }
    try std.testing.expect(found_is_global);
}

test "edit_skill - tool definition has skill_name as required" {
    const tool_def = edit_skill_mod.edit_skill_tool;

    // Should have skill_name as required (not description or content)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 1);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
}

test "edit_skill - is_global defaults to false" {
    const input = edit_skill_mod.EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
    };
    try std.testing.expect(input.is_global == false);
}

test "edit_skill - local edit (is_global=false) updates .nalar/skills/<name>/SKILL.MD" {
    // Regression test for use-after-free bug: when is_global=false, skills_dir
    // was being freed too early (defer was scoped to the else block), causing
    // path.join to use a dangling pointer. The file would either not be
    // updated or be updated in the wrong place.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-local-edit-skill";
    const tmp_path = "/tmp/nalar-edit-skill-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    // Pre-create a local skill file in the expected format
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const original_content =
        \\---
        \\name: test-local-edit-skill
        \\description: "Original description"
        \\---
        \\
        \\# Original content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, original_content);
    }

    // Now edit the local skill
    const new_description = "Updated description for local skill";
    const new_content = "# Updated content\n\nThis is the updated test.";

    const input = edit_skill_mod.EditSkillInput{
        .skill_name = skill_name,
        .description = new_description,
        .content = new_content,
        .is_global = false,
    };

    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>true</edited>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, skill_name) != null);

    // Read the file and verify it was actually updated with the new content
    const updated_file_content = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(updated_file_content);

    // New description and content should be present
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, new_description) != null);
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Updated content") != null);
    // Original description and content should be gone
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Original description") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated_file_content, "Original content") == null);
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression test (added 2026-08-15)
//
// edit_skill writes the updated skill back via `std.Io.Dir.createFileAbsolute
// (io, skill_file, .{})` (edit_skill.zig:132) — that call relies on the
// default `truncate: bool = true` to OVERWRITE (not append-to) the existing
// skill file. This test pins the contract by pre-seeding a skill with
// trailing junk AFTER the frontmatter, then editing with a SHORTER body,
// and asserting the trailing junk is GONE in the final file (would
// prove append-mode corruption if present).
// ---------------------------------------------------------------------------

test "edit_skill - edit truncates existing skill file (no append-mode corruption)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "edit-overwrite-skill";
    const tmp_path = "/tmp/nalar-edit-skill-overwrite-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);
    const skill_dir_path = try std.fs.path.join(alloc, &.{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{
        tmp_path, ".nalar", "skills", skill_name, "SKILL.MD",
    });
    defer alloc.free(skill_file_path);

    // Pre-seed a skill file with a marker INSIDE the frontmatter description
    // plus trailing junk OUTSIDE the content block that the edit MUST wipe.
    // The format is: ---\nname: ...\ndescription: "..."\n---\n<content>\n
    const seed = "---\nname: edit-overwrite-skill\ndescription: \"OLD-DESC-MARKER\"\n---\nOLD-CONTENT-MARKER trailing junk that should be completely wiped on edit append-junk-trailing-bytes-12345\n";
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file_path, .{});
        defer f.close(io);
        try std.Io.File.writeStreamingAll(f, io, seed);
    }

    // Edit the skill — replace BOTH description and content with shorter values.
    const input = edit_skill_mod.EditSkillInput{
        .skill_name = skill_name,
        .description = "new",
        .content = "v2",
        .is_global = false,
    };
    const output = try edit_skill_mod.executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<edited>true</edited>") != null);

    // Read back — must contain ONLY the new description+content; ALL of the
    // OLD markers and trailing junk must be GONE.
    const updated = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(updated);

    // New values are present
    try std.testing.expect(std.mem.indexOf(u8, updated, "new") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "v2") != null);

    // CRITICAL: no leftover from old seed — would prove append-mode corruption
    try std.testing.expect(std.mem.indexOf(u8, updated, "OLD-DESC-MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "OLD-CONTENT-MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "trailing junk that should be completely wiped") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "append-junk-trailing-bytes") == null);
}

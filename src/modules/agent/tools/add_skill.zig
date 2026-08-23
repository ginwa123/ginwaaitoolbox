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

const add_skill_mod = @import("add_skill.zig");

test "add_skill - empty name returns error" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "",
        .description = "Test description",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Skill name cannot be empty") != null);
}

test "add_skill - empty description returns error" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Description cannot be empty") != null);
}

test "add_skill - empty content returns error" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Content cannot be empty") != null);
}

test "add_skill - tool definition includes is_global parameter" {
    const tool_def = add_skill_mod.add_skill_tool;

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

test "add_skill - tool definition has correct required fields" {
    const tool_def = add_skill_mod.add_skill_tool;

    // Should have name, description, content as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 3);
    try std.testing.expect(std.mem.eql(u8, required[0], "name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "description"));
    try std.testing.expect(std.mem.eql(u8, required[2], "content"));
}

test "add_skill - is_global defaults to false" {
    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "Test content",
    };
    try std.testing.expect(input.is_global == false);
}

test "add_skill - buildSkillContent with special characters" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes",
        .content = "Test content with\\backslash",
        .is_global = false,
    };

    const content = add_skill_mod.buildSkillContent(alloc, input);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name: test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "description: \"Test \\\"description\\\" with quotes\"") != null);
}

test "add_skill - executeAddSkillToString validates empty content" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",  // Empty content should fail
        .is_global = false,
    };

    const output = add_skill_mod.executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "<created>false</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Content cannot be empty") != null);
}

test "add_skill - buildSkillContent escapes special characters" {
    const alloc = std.testing.allocator;

    const input = add_skill_mod.AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes and\\backslash",
        .content = "Test content",
        .is_global = false,
    };

    const content = add_skill_mod.buildSkillContent(alloc, input);
    defer alloc.free(content);

    // Should contain escaped description
    try std.testing.expect(std.mem.indexOf(u8, content, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\\\\") != null);
}

// ---------------------------------------------------------------------------
// Overwrite-contract regression tests (added 2026-08-15)
//
// add_skill writes the skill file via `std.Io.Dir.createFileAbsolute(io,
// skill_file, .{})` (add_skill.zig:121) — that call relies on the default
// `truncate: bool = true` to OVERWRITE (not fail-with-FileAlreadyExists,
// not append-to) an existing skill with the same name. These tests pin
// that contract end-to-end: re-running add_skill with the same `name`
// must produce the new skill content, with no leftover bytes from the
// first call.
//
// Why this matters: when the LLM refines a skill (e.g. updates its
// description based on user feedback), it re-runs add_skill with the
// same name — a regression that left the old bytes appended would
// silently corrupt the skill file.
// ---------------------------------------------------------------------------

test "add_skill - re-running with same name OVERWRITES (truncates, no append)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-overwrite-skill";
    const tmp_path = "/tmp/nalar-add-skill-overwrite-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{
        tmp_path, ".nalar", "skills", skill_name, "SKILL.MD",
    });
    defer alloc.free(skill_file_path);

    // First add_skill: write a long skill body
    const first_input = add_skill_mod.AddSkillInput{
        .name = skill_name,
        .description = "First version description",
        .content = "# First version\n\nThis is the original long body that should be completely replaced on overwrite.",
        .create_with_dir = true,
        .is_global = false,
    };
    const first_output = add_skill_mod.executeAddSkillToString(alloc, io, tmp_path, null, first_input);
    defer alloc.free(first_output);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "<created>true</created>") != null);

    // Sanity-check the first version landed on disk
    const first_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(first_read);
    try std.testing.expect(std.mem.indexOf(u8, first_read, "First version description") != null);

    // Second add_skill: write a SHORTER skill body with the SAME name.
    // If the createFile call is buggy and appends, the file would
    // contain BOTH versions concatenated.
    const second_input = add_skill_mod.AddSkillInput{
        .name = skill_name,
        .description = "Second desc",
        .content = "v2",
        .create_with_dir = true,
        .is_global = false,
    };
    const second_output = add_skill_mod.executeAddSkillToString(alloc, io, tmp_path, null, second_input);
    defer alloc.free(second_output);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "<created>true</created>") != null);

    // Read back — must contain ONLY second-version markers, NO first-version
    const second_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(second_read);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "Second desc") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "v2") != null);
    // CRITICAL: no leftover from first call — would prove append-mode corruption
    try std.testing.expect(std.mem.indexOf(u8, second_read, "First version description") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "First version\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_read, "should be completely replaced") == null);
}

test "add_skill - local creation (is_global=false) writes to .nalar/skills/<name>/SKILL.MD" {
    // Regression test for use-after-free bug: when is_global=false, skills_dir
    // was being freed too early (defer was scoped to the else block), causing
    // path.join to use a dangling pointer. The file would either not be
    // created or be created in the wrong place.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-local-skill";
    const tmp_path = "/tmp/nalar-add-skill-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_path);

    const input = add_skill_mod.AddSkillInput{
        .name = skill_name,
        .description = "Test description for local skill",
        .content = "# Test skill content\n\nThis is a test.",
        .create_with_dir = true,
        .is_global = false,
    };

    const output = add_skill_mod.executeAddSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    try std.testing.expect(std.mem.indexOf(u8, output, "<created>true</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, skill_name) != null);

    // Verify the file was actually created at the correct path:
    // <tmp_path>/.nalar/skills/<skill_name>/SKILL.MD
    // Check that the directory structure exists (this would fail with the old bug
    // because createDirPath was called with a freed-and-reused pointer)
    const dir_check = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(dir_check);
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, dir_check, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(dir_exists);

    // Check that the SKILL.MD file exists
    const file_check = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name, "SKILL.MD" });
    defer alloc.free(file_check);
    const file_exists = blk: {
        std.Io.Dir.cwd().access(io, file_check, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(file_exists);

    // Read the file and verify it has the expected content
    const file_content = try std.Io.Dir.cwd().readFileAlloc(io, file_check, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(file_content);

    try std.testing.expect(std.mem.indexOf(u8, file_content, "name: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, skill_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test description for local skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_content, "Test skill content") != null);
}

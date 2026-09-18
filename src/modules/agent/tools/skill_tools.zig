//! Skill agent tools: `list_skills` + `use_skill` + `remove_skill` +
//! `add_skill` + `edit_skill`.
//!
//! Merged from the five `*_skill*.zig` tool modules (2026-09-11
//! skills-merge refactor) — one file, five tools. The public surface is
//! unchanged: every `*Input` struct, `*_tool` definition,
//! `execute_*` entry point, and the `listAllSkills` / `freeSkillsListData`
//! / `toJson` helper shared with the HTTP layer keeps its
//! names. Only colliding private helpers gained per-tool prefixes
//! (`addSkill*` / `editSkill*` / `removeSkill*`); the two identical
//! `contains` test helpers were deduplicated to one. Every tool result
//! is a JSON object built with `std.json.Stringify.valueAlloc`.
//!
//! Note: `skills.zig` next to this file is the storage/filesystem layer
//! (imported here as `skills`), not a tool definition.

const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");
const helpers = @import("helpers");

// Helper to check if string contains substring (shared by the list/use skill tests)
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ─── list_skills ───

/// Shared data structure for skills list - used by both HTTP handler and AI agent tool
pub const SkillsListData = struct {
    global_skills: []const skills.SkillInfo,
    local_skills: []const skills.SkillInfo,
    cwd: ?[]const u8,
};

/// Tool definition for list_skills
pub const list_skills_tool_system_prompt =
    \\## List Skills Tool — Behavior
    \\Use `list_skills` to discover available skills (global + local).
    \\- Call to refresh the skill list before picking a skill to load. No parameters required beyond `cwd`.
    \\
;

pub const list_skills_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "list_skills",
        .description = "List all available skills with brief descriptions. Use this to discover what capabilities you can load.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "cwd",
                    .type = "string",
                    .description = "Absolute working directory for the command. REQUIRED — always set explicitly. " ++
                        "Never assume the current directory. All relative paths in the command resolve from here.",
                },
            },
            .required = &.{},
        },
        .system_prompt = list_skills_tool_system_prompt,
    },
};

/// List all skills (global + local) and return the data structure
/// Caller owns the returned memory and must free it with freeSkillsListData()
pub fn listAllSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
) !SkillsListData {
    // Get global skills path (from environment map - REQUIRED)
    if (environment == null) {
        return error.MissingEnvironment;
    }
    const global_path = skills.get_global_skills_path_from_env(allocator, environment.?);
    defer if (global_path) |p| allocator.free(p);

    // Get local skills path (from cwd or current directory)
    const local_path: ?[]const u8 = if (cwd_param) |cwd|
        skills.get_local_skills_path_for_dir(allocator, cwd)
    else
        skills.get_local_skills_path_from_io(allocator, io);
    defer if (local_path) |p| allocator.free(p);

    // List global skills
    var global_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (global_path) |path| {
        global_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }

    // List local skills
    var local_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (local_path) |path| {
        local_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }

    return SkillsListData{
        .global_skills = global_skills,
        .local_skills = local_skills,
        .cwd = cwd_param,
    };
}

/// Free memory allocated by listAllSkills()
pub fn freeSkillsListData(allocator: std.mem.Allocator, data: SkillsListData) void {
    skills.free_skills_list(allocator, data.global_skills);
    skills.free_skills_list(allocator, data.local_skills);
}

/// Serialize SkillsListData to JSON string
/// Caller owns the returned memory and must free it with allocator.free()
pub fn toJson(allocator: std.mem.Allocator, data: SkillsListData) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, data, .{});
}

/// Execute the list_skills tool - returns a JSON string for AI agent
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_list_skills(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
    environment: ?*const std.process.Environ.Map,
) ![]const u8 {
    const data = try listAllSkills(allocator, io, cwd_param, environment);
    defer freeSkillsListData(allocator, data);
    return toJson(allocator, data);
}

/// Parsed shape of `execute_list_skills` output, for tests.
pub const ListSkillsOutput = struct {
    global_skills: []skills.SkillInfo,
    local_skills: []skills.SkillInfo,
    cwd: ?[]const u8 = null,
};

// ─── use_skill ───

/// Input structure for use_skill tool
pub const UseSkillInput = struct {
    /// Load skill from file path. Accepts both absolute paths and relative
    /// paths (resolved against the session's current working directory).
    path: ?[]const u8 = null,
    /// Reserved for forward compatibility — currently has no effect because
    /// the only code path is `loadSkillFromPath`, which reads the file as-is.
    is_global: bool = false,
};

/// Result structure for use_skill tool
pub const UseSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    path: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for use_skill
pub const use_skill_tool_system_prompt =
    \\## Use Skill Tool — Behavior
    \\Use `use_skill` to load a skill's full instructions by exact file path (from `list_skills`).
    \\- The path is case-sensitive and ends in `SKILL.MD` — don't construct it from the name. Pass it verbatim.
    \\
;

pub const use_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "use_skill",
        .description = "Load a skill's full content from a file path. Use this when you need detailed guidance for a specific capability. Pass the file path (absolute or relative to the session's current working directory) via the `path` argument.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Load skill from file path. Accepts both absolute paths (e.g. /home/user/skill.md) and relative paths (resolved against the session's current working directory).",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "Reserved. Currently has no effect; the file is always loaded as-is from `path`.",
                },
            },
            .required = &.{ "path", "is_global" },
        },
        .system_prompt = use_skill_tool_system_prompt,
    },
};

/// JSON payload for use_skill results.
pub const UseSkillJSON = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    @"error": ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Parsed shape of `execute_use_skill_to_string` output, for tests.
pub const UseSkillOutput = struct {
    skill_name: []const u8 = "",
    content: []const u8 = "",
    loaded: bool = false,
    @"error": ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

fn useSkillJsonError(allocator: std.mem.Allocator, skill_name: []const u8, err_msg: []const u8) ![]const u8 {
    const clean_name = try helpers.sanitize_control_chars(allocator, skill_name);
    defer allocator.free(clean_name);
    const clean_err = try helpers.sanitize_control_chars(allocator, err_msg);
    defer allocator.free(clean_err);
    return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
        .skill_name = clean_name,
        .content = "",
        .loaded = false,
        .@"error" = clean_err,
        .available_skills = null,
    }, .{});
}

/// Execute the use_skill tool
/// Returns a JSON string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_use_skill_to_string(allocator: std.mem.Allocator, io: std.Io, input: UseSkillInput, environment: ?*const std.process.Environ.Map) ![]const u8 {
    _ = environment; // kept for signature compatibility; not used by the path-only code path
    const path = input.path orelse return error.InvalidInput;
    return loadSkillFromPath(allocator, io, path);
}

/// Load skill from a file path. Accepts both absolute and relative paths —
/// relative paths are resolved against the io's current working directory.
///
/// NOTE: this used to call `std.Io.Dir.openFileAbsolute` which has the
/// precondition `assert(path.isAbsolute(absolute_path))`. In debug builds
/// a non-absolute path triggered `unreachable`, killing the entire worker
/// process and bypassing every catch/try in the call chain
/// (see docs/plans/2025-01-15-get-skill-relative-path-panic.md). We now
/// use `cwd().openFile` which handles both cases — `openFileAbsolute` is
/// literally `openFile(.cwd(), ...)` + that assert.
fn loadSkillFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to open file \"{s}\": {s}", .{ path, @errorName(err) });
        defer allocator.free(msg);
        return try useSkillJsonError(allocator, "", msg);
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to read file \"{s}\": {s}", .{ path, @errorName(err) });
        defer allocator.free(msg);
        return try useSkillJsonError(allocator, "", msg);
    };
    defer allocator.free(content);

    // Extract skill_name: prefer the YAML frontmatter `name:` field;
    // fall back to the file basename (without extension) for files that
    // don't use the frontmatter convention. In both branches we own the
    // returned slice and free it after the JSON result is built.
    const skill_name: []const u8 = blk: {
        const filename = std.fs.path.basename(path);
        const ext = std.fs.path.extension(filename);
        const basename = filename[0 .. filename.len - ext.len];

        if (skills.parseYamlFrontmatter(allocator, content)) |fm| {
            defer allocator.free(fm.description);
            // Take ownership of fm.name; the defer below frees it after
            // Stringify copies the bytes into the result.
            break :blk fm.name;
        }
        // basename points into `content` (freed below); dupe to give it
        // the same lifetime as the frontmatter branch.
        break :blk try allocator.dupe(u8, basename);
    };
    defer allocator.free(skill_name);

    const clean_name = try helpers.sanitize_control_chars(allocator, skill_name);
    defer allocator.free(clean_name);
    const clean_content = try helpers.sanitize_control_chars(allocator, content);
    defer allocator.free(clean_content);
    return try std.json.Stringify.valueAlloc(allocator, UseSkillJSON{
        .skill_name = clean_name,
        .content = clean_content,
        .loaded = true,
        .@"error" = null,
        .available_skills = null,
    }, .{});
}

// ─── remove_skill ───

/// Input structure for remove_skill tool
pub const RemoveSkillInput = struct {
    skill_name: []const u8,
    session_id: []const u8,
    /// If true, remove from global skills directory (~/.config/nalar/skills/)
    /// If false, remove from local skills directory (.nalar/skills/)
    is_global: bool = false,
};

/// Result structure for remove_skill tool
pub const RemoveSkillResult = struct {
    skill_name: []const u8,
    removed: bool,
    err_msg: ?[]const u8 = null,
};

/// JSON payload for remove_skill results.
pub const RemoveSkillJSON = struct {
    skill_name: []const u8,
    removed: bool,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `execute_remove_skill_to_string` output, for tests.
pub const RemoveSkillOutput = struct {
    skill_name: []const u8 = "",
    removed: bool = false,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Create JSON error output for remove_skill
pub fn removeSkillJsonError(allocator: std.mem.Allocator, skill_name: []const u8, err_msg: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, skill_name) catch return "";
    defer allocator.free(clean_name);
    const clean_err = helpers.sanitize_control_chars(allocator, err_msg) catch return "";
    defer allocator.free(clean_err);
    return std.json.Stringify.valueAlloc(allocator, RemoveSkillJSON{
        .skill_name = clean_name,
        .removed = false,
        .path = null,
        .@"error" = clean_err,
    }, .{}) catch "";
}

fn removeSkillJsonSuccess(allocator: std.mem.Allocator, skill_name: []const u8, path: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, skill_name) catch return "";
    defer allocator.free(clean_name);
    const clean_path = helpers.sanitize_control_chars(allocator, path) catch return "";
    defer allocator.free(clean_path);
    return std.json.Stringify.valueAlloc(allocator, RemoveSkillJSON{
        .skill_name = clean_name,
        .removed = true,
        .path = clean_path,
        .@"error" = null,
    }, .{}) catch "";
}

/// Tool definition for remove_skill
pub const remove_skill_tool_system_prompt =
    \\## Remove Skill Tool — Behavior
    \\Use `remove_skill` to permanently delete a skill file.
    \\- Provide `skill_name` and `session_id`. Use only when the skill is obsolete or the user asks to remove it.
    \\
;

pub const remove_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "remove_skill",
        .description = "Remove a skill from the current session AND delete the skill file from .nalar/skills/. Use this to permanently delete a skill.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to remove and delete",
                },
                .{
                    .name = "session_id",
                    .type = "string",
                    .description = "The session ID (unused, kept for compatibility)",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, remove from global skills directory (~/.config/nalar/skills/). If false, remove from local directory (.nalar/skills/). Default: false",
                },
            },
            .required = &.{ "skill_name", "session_id" },
        },
        .system_prompt = remove_skill_tool_system_prompt,
    },
};

/// Execute the remove_skill tool - removes from session AND deletes file
/// Deletes skill file at .nalar/skills/<skill_name>/ or global ~/.config/nalar/skills/<skill_name>/
/// Returns a JSON string with the result
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_remove_skill_to_string(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    environment: ?*const std.process.Environ.Map,
    input: RemoveSkillInput,
) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        return removeSkillJsonError(allocator, "", "skill_name cannot be empty");
    }

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global) blk: {
        if (environment) |env| {
            const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                return removeSkillJsonError(allocator, input.skill_name, "Failed to get global skills path");
            };
            break :blk path;
        } else {
            return removeSkillJsonError(allocator, input.skill_name, "Environment not available for global skills");
        }
    } else try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" });

    // Build path to skill directory
    // Duplicate skill_name to ensure no aliasing with path.join's internal buffer allocation
    const skill_name_copy = try allocator.dupe(u8, input.skill_name);
    errdefer allocator.free(skill_name_copy);

    const skill_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ skills_dir, skill_name_copy });
    // skill_name_copy is no longer needed after path.join copies it
    allocator.free(skill_name_copy);

    // Check if the skill directory exists
    const dir_exists = blk: {
        std.Io.Dir.cwd().access(io, skill_dir_path, .{}) catch {
            break :blk false;
        };
        break :blk true;
    };

    if (!dir_exists) {
        // Skill directory doesn't exist - might be a built-in skill or already removed
        const out = removeSkillJsonError(allocator, input.skill_name, "Skill directory not found");

        if (input.is_global) allocator.free(skills_dir);
        allocator.free(skill_dir_path);
        return out;
    }

    // Delete the skill directory recursively
    std.Io.Dir.cwd().deleteTree(io, skill_dir_path) catch {
        const out = removeSkillJsonError(allocator, input.skill_name, "Failed to delete skill directory");

        if (input.is_global) allocator.free(skills_dir);
        allocator.free(skill_dir_path);
        return out;
    };

    // Return success
    const out = removeSkillJsonSuccess(allocator, input.skill_name, skill_dir_path);

    // Clean up allocated memory
    if (input.is_global) allocator.free(skills_dir);
    allocator.free(skill_dir_path);

    return out;
}

/// Generate error JSON response for parse failures (no name available)
pub fn removeSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return removeSkillJsonError(allocator, "", error_msg);
}

// ─── add_skill ───

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
pub const add_skill_tool_system_prompt =
    \\## Add Skill Tool — Behavior
    \\Use `add_skill` to create a new reusable skill file.
    \\- Provide `name`, `description`, and markdown `content`. Use to capture a proven workflow for future sessions.
    \\- Check for existing skill with `list_skills` first to avoid duplicates.
    \\
;

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
        .system_prompt = add_skill_tool_system_prompt,
    },
};

/// JSON payload for add_skill results. Both `skill_name` and `name` carry
/// the skill name: `skill_name` matches the tool schema, `name` matches the
/// legacy tag name read by existing JSON parsers.
pub const AddSkillJSON = struct {
    skill_name: []const u8,
    name: []const u8,
    created: bool,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `executeAddSkillToString` output, for tests.
pub const AddSkillOutput = struct {
    skill_name: []const u8 = "",
    name: []const u8 = "",
    created: bool = false,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Execute the add_skill tool
/// Creates a new skill file at .nalar/skills/<name>/SKILL.MD or global ~/.config/nalar/skills/<name>/SKILL.MD
/// Returns a JSON string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeAddSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, environment: ?*const std.process.Environ.Map, input: AddSkillInput) []const u8 {
    // Validate input
    if (input.name.len == 0) return addSkillJsonError(allocator, input.name, "Skill name cannot be empty");
    if (input.description.len == 0) return addSkillJsonError(allocator, input.name, "Description cannot be empty");
    if (input.content.len == 0) return addSkillJsonError(allocator, input.name, "Content cannot be empty");

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global) blk: {
        if (environment) |env| {
            const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                return addSkillJsonError(allocator, input.name, "Failed to get global skills path");
            };
            break :blk path;
        } else {
            return addSkillJsonError(allocator, input.name, "Environment not available for global skills");
        }
    } else std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" }) catch {
        return addSkillJsonError(allocator, input.name, "Failed to build skills directory path");
    };
    // skills_dir is heap-allocated in both branches (global via get_global_skills_path_from_env,
    // local via path.join). Free it once at the end of the function via a single defer.
    defer allocator.free(skills_dir);

    // Duplicate input.name to ensure no aliasing with path.join's internal buffer allocation
    const name_copy = allocator.dupe(u8, input.name) catch {
        return addSkillJsonError(allocator, input.name, "Failed to allocate memory for skill name");
    };
    defer allocator.free(name_copy);

    const skill_dir = std.fs.path.join(allocator, &[_][]const u8{ skills_dir, name_copy }) catch {
        return addSkillJsonError(allocator, input.name, "Failed to build skill directory path");
    };
    defer allocator.free(skill_dir);

    const skill_file = std.fs.path.join(allocator, &[_][]const u8{ skill_dir, "SKILL.MD" }) catch {
        return addSkillJsonError(allocator, input.name, "Failed to build skill file path");
    };
    defer allocator.free(skill_file);

    // Create directories if needed using std.io.Dir
    if (input.create_with_dir) {
        const cwd_dir = std.Io.Dir.cwd();
        cwd_dir.createDirPath(io, skill_dir) catch {
            return addSkillJsonError(allocator, input.name, "Failed to create skill directory");
        };
    }

    // Build skill content with YAML frontmatter
    const file_content = buildSkillContent(allocator, input);
    defer allocator.free(file_content);
    if (file_content.len == 0) {
        return addSkillJsonError(allocator, input.name, "Failed to build skill content");
    }

    // Write the file using absolute path with Io.Dir
    const file = std.Io.Dir.createFileAbsolute(io, skill_file, .{}) catch {
        return addSkillJsonError(allocator, input.name, "Failed to create skill file");
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, file_content) catch {
        return addSkillJsonError(allocator, input.name, "Failed to write skill file");
    };

    // Return success JSON
    return addSkillJsonSuccess(allocator, input.name, skill_file);
}

/// Build skill file content with YAML frontmatter
pub fn buildSkillContent(allocator: std.mem.Allocator, input: AddSkillInput) []const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = addSkillEscapeYamlString(allocator, input.description);
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
fn addSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) []const u8 {
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
fn addSkillJsonSuccess(allocator: std.mem.Allocator, name: []const u8, path: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, name) catch return "";
    defer allocator.free(clean_name);
    const clean_path = helpers.sanitize_control_chars(allocator, path) catch return "";
    defer allocator.free(clean_path);
    return std.json.Stringify.valueAlloc(allocator, AddSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .created = true,
        .path = clean_path,
        .@"error" = null,
    }, .{}) catch "";
}

/// Internal error-to-XML helper (doesn't return error)
/// Generate error JSON response
pub fn addSkillJsonError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, name) catch return "";
    defer allocator.free(clean_name);
    const clean_err = helpers.sanitize_control_chars(allocator, error_msg) catch return "";
    defer allocator.free(clean_err);
    return std.json.Stringify.valueAlloc(allocator, AddSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .created = false,
        .path = null,
        .@"error" = clean_err,
    }, .{}) catch "";
}

/// Append XML-safe content to an ArrayList
/// Generate error XML response
/// Generate error XML response for parse failures (no name available)
/// Generate error JSON response for parse failures (no name available)
pub fn addSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return addSkillJsonError(allocator, "", error_msg);
}

// ─── edit_skill ───

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
            .required = &.{"skill_name"},
        },
        .system_prompt = edit_skill_tool_system_prompt,
    },
};

/// JSON payload for edit_skill results. `skill_name`/`name` and
/// `updated`/`edited` are duplicated: the first of each pair matches the
/// tool schema, the second matches the legacy tag name.
pub const EditSkillJSON = struct {
    skill_name: []const u8,
    name: []const u8,
    updated: bool,
    edited: bool,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parsed shape of `executeEditSkillToString` output, for tests.
pub const EditSkillOutput = struct {
    skill_name: []const u8 = "",
    name: []const u8 = "",
    updated: bool = false,
    edited: bool = false,
    path: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Execute the edit_skill tool
/// Updates an existing skill file at .nalar/skills/<skill_name>/SKILL.MD or global ~/.config/nalar/skills/<skill_name>/SKILL.MD
/// Returns a JSON string with the result or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn executeEditSkillToString(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, environment: ?*const std.process.Environ.Map, input: EditSkillInput) ![]const u8 {
    // Validate input
    if (input.skill_name.len == 0) {
        return editSkillJsonError(allocator, input.skill_name, "Skill name cannot be empty");
    }

    // At least one of description or content must be provided
    if (input.description == null and input.content == null) {
        return editSkillJsonError(allocator, input.skill_name, "At least one of description or content must be provided");
    }

    // Determine skills directory based on is_global flag
    const skills_dir: []const u8 = if (input.is_global) blk: {
        if (environment) |env| {
            const path = skills.get_global_skills_path_from_env(allocator, env) orelse {
                return editSkillJsonError(allocator, input.skill_name, "Failed to get global skills path");
            };
            break :blk path;
        } else {
            return editSkillJsonError(allocator, input.skill_name, "Environment not available for global skills");
        }
    } else try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".nalar", "skills" });
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
        return editSkillJsonError(allocator, input.skill_name, "Skill file not found");
    }

    // Read existing skill content
    const existing_content = std.Io.Dir.cwd().readFileAlloc(io, skill_file, allocator, std.Io.Limit.limited(1024 * 1024)) catch {
        return editSkillJsonError(allocator, input.skill_name, "Failed to read existing skill file");
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
    const updated_content = try buildEditSkillContent(allocator, input.skill_name, new_description, new_content);
    defer allocator.free(updated_content);

    // Write the updated file
    const file = std.Io.Dir.createFileAbsolute(io, skill_file, .{}) catch {
        return editSkillJsonError(allocator, input.skill_name, "Failed to create skill file for writing");
    };
    defer std.Io.File.close(file, io);

    std.Io.File.writeStreamingAll(file, io, updated_content) catch {
        return editSkillJsonError(allocator, input.skill_name, "Failed to write skill file");
    };

    // Return success JSON
    return try editSkillJsonSuccess(allocator, input.skill_name, skill_file);
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

    const frontmatter_end = std.mem.indexOf(u8, file_content[frontmatter_start + 4 ..], "---\n") orelse {
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
                        result.description = try uneditSkillEscapeYamlString(allocator, value);
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
fn buildEditSkillContent(allocator: std.mem.Allocator, name: []const u8, description: []const u8, content: []const u8) ![]const u8 {
    // Escape quotes in description for YAML string
    const escaped_desc = try editSkillEscapeYamlString(allocator, description);
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
fn editSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
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
fn uneditSkillEscapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
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
fn editSkillJsonSuccess(allocator: std.mem.Allocator, name: []const u8, path: []const u8) ![]const u8 {
    const clean_name = try helpers.sanitize_control_chars(allocator, name);
    defer allocator.free(clean_name);
    const clean_path = try helpers.sanitize_control_chars(allocator, path);
    defer allocator.free(clean_path);
    return try std.json.Stringify.valueAlloc(allocator, EditSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .updated = true,
        .edited = true,
        .path = clean_path,
        .@"error" = null,
    }, .{});
}

/// Internal error-to-XML helper (doesn't return error)
/// Generate error JSON response
pub fn editSkillJsonError(allocator: std.mem.Allocator, name: []const u8, error_msg: []const u8) []const u8 {
    const clean_name = helpers.sanitize_control_chars(allocator, name) catch return "";
    defer allocator.free(clean_name);
    const clean_err = helpers.sanitize_control_chars(allocator, error_msg) catch return "";
    defer allocator.free(clean_err);
    return std.json.Stringify.valueAlloc(allocator, EditSkillJSON{
        .skill_name = clean_name,
        .name = clean_name,
        .updated = false,
        .edited = false,
        .path = null,
        .@"error" = clean_err,
    }, .{}) catch "";
}

/// Generate error XML response
/// Generate error XML response for parse failures (no name available)
/// Generate error JSON response for parse failures (no name available)
pub fn editSkillJsonErrorEmpty(allocator: std.mem.Allocator, error_msg: []const u8) []const u8 {
    return editSkillJsonError(allocator, "", error_msg);
}

// ─── tests: list_skills ───

test "toJson on empty lists parses to empty arrays and null cwd" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.global_skills.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
    try std.testing.expect(parsed.value.cwd == null);
}

test "toJson carries raw skill fields, parsed" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{
            .{
                .name = "test <skill>",
                .description = "desc & more",
                .path = "/path/with \"quotes\"",
            },
        },
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    // Raw text needs no escaping in JSON — parse and compare verbatim.
    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.global_skills.len);
    try std.testing.expectEqualStrings("test <skill>", parsed.value.global_skills[0].name);
    try std.testing.expectEqualStrings("desc & more", parsed.value.global_skills[0].description);
    try std.testing.expectEqualStrings("/path/with \"quotes\"", parsed.value.global_skills[0].path);
}

test "toJson includes cwd when present, parsed" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = "/test/cwd",
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/test/cwd", parsed.value.cwd orelse "");
}

test "toJson generates valid JSON" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    const json = try toJson(alloc, data);
    defer alloc.free(json);

    // Should be valid JSON structure
    try std.testing.expect(std.mem.startsWith(u8, json, "{"));
    try std.testing.expect(std.mem.endsWith(u8, json, "}"));
    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.global_skills.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
}

test "freeSkillsListData handles empty arrays" {
    const alloc = std.testing.allocator;

    const data = SkillsListData{
        .global_skills = &[_]skills.SkillInfo{},
        .local_skills = &[_]skills.SkillInfo{},
        .cwd = null,
    };

    // Should not panic
    freeSkillsListData(alloc, data);
}

test "execute_list_skills - finds local skill in cwd workspace" {
    // Regression test: ensure execute_list_skills correctly uses the cwd
    // parameter to find local skills. The execListSkills wiring in
    // tool_registry.zig used to pass null instead of ctx.cwd, which made
    // local skills invisible to the agent.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-list-local-skill";
    const tmp_path = "/tmp/nalar-list-skills-test";

    // Clean up any leftover from previous failed runs
    std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_path) catch {};

    // Pre-create a local skill file in the temp cwd
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ tmp_path, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const skill_content =
        \\---
        \\name: test-list-local-skill
        \\description: "Test description for list regression"
        \\---
        \\
        \\# Test content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    // Build a minimal environment map so listAllSkills can look up the global path.
    // Point HOME to a non-existent dir so global lookup returns no skills (clean output).
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/tmp/nalar-nonexistent-home-for-list-test");

    // Call execute_list_skills with the tmp_path as cwd
    const output = try execute_list_skills(alloc, io, tmp_path, &env);
    defer alloc.free(output);

    // The local skill should appear in the local_skills array
    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.local_skills.len);
    try std.testing.expectEqualStrings(skill_name, parsed.value.local_skills[0].name);
    try std.testing.expectEqualStrings("Test description for list regression", parsed.value.local_skills[0].description);
    try std.testing.expectEqualStrings(tmp_path, parsed.value.cwd orelse "");
}

test "execute_list_skills - does not show local skill from a different cwd" {
    // Counterpart test: when the cwd does NOT contain the skill, it should
    // not appear in local_skills. This guards against a regression where
    // the OS-level cwd (instead of the passed-in cwd) is used.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const skill_name = "test-list-other-cwd-skill";
    const skill_cwd = "/tmp/nalar-list-skills-other-cwd";
    const query_cwd = "/tmp/nalar-list-skills-different-cwd";

    // Clean up
    std.Io.Dir.cwd().deleteTree(io, skill_cwd) catch {};
    std.Io.Dir.cwd().deleteTree(io, query_cwd) catch {};
    defer {
        std.Io.Dir.cwd().deleteTree(io, skill_cwd) catch {};
        std.Io.Dir.cwd().deleteTree(io, query_cwd) catch {};
    }

    // Create the skill in skill_cwd
    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_cwd, ".nalar", "skills", skill_name });
    defer alloc.free(skill_dir_path);
    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    const skill_content =
        \\---
        \\name: test-list-other-cwd-skill
        \\description: "Skill in different cwd"
        \\---
        \\
        \\# Test content
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    // Build a minimal environment map
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", "/tmp/nalar-nonexistent-home-for-list-test");

    // Call with a DIFFERENT cwd — the skill should not appear
    const output = try execute_list_skills(alloc, io, query_cwd, &env);
    defer alloc.free(output);

    // The local skill should NOT appear (because it's in skill_cwd, not query_cwd)
    const parsed = try std.json.parseFromSlice(ListSkillsOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.local_skills.len);
}
// ─── tests: use_skill ───

test "use_skill_tool - has correct tool definition" {
    try std.testing.expectEqualStrings("use_skill", use_skill_tool.function.name);
    try std.testing.expect(use_skill_tool.function.parameters.properties.len == 2);
}

test "UseSkillInput - has correct defaults" {
    const input = UseSkillInput{};
    try std.testing.expect(input.path == null);
    try std.testing.expect(input.is_global == false);
}

test "UseSkillResult - has correct struct fields" {
    const result = UseSkillResult{
        .skill_name = "test",
        .content = "Test content",
        .loaded = true,
    };
    try std.testing.expectEqualStrings("test", result.skill_name);
    try std.testing.expectEqualStrings("Test content", result.content);
    try std.testing.expect(result.loaded == true);
    try std.testing.expect(result.path == null);
    try std.testing.expect(result.err_msg == null);
    try std.testing.expect(result.available_skills == null);
}

test "execute_use_skill_to_string - missing path returns InvalidInput" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = UseSkillInput{};
    const result = execute_use_skill_to_string(alloc, io, input, null);
    try std.testing.expectError(error.InvalidInput, result);
}

test "use_skill_tool - description is descriptive" {
    // The tool description should explain what the tool does
    try std.testing.expect(use_skill_tool.function.description.len > 10);
    try std.testing.expect(contains(use_skill_tool.function.description, "skill"));
    try std.testing.expect(contains(use_skill_tool.function.description, "content"));
}

test "execute_use_skill_to_string - loaded skill output preserves skill name" {
    // Sanity test: when the skill is found, the output contains the skill
    // name and content (not a use-after-free case, but worth verifying the
    // happy path still works after the refactor).
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const unique_skill_name = "_regression_uaf_use_skill_loaded_test";
    const unique_marker = "REGRESSION_MARKER_12345";
    const tmp_home = "/tmp/nalar-uaf-test-home-loaded";
    const global_skills_dir = "/tmp/nalar-uaf-test-home-loaded/.config/nalar/skills";

    const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_skills_dir, unique_skill_name });
    defer alloc.free(skill_dir_path);
    const skill_file_path = try std.fs.path.join(alloc, &[_][]const u8{ skill_dir_path, "SKILL.MD" });
    defer alloc.free(skill_file_path);

    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, skill_dir_path);

    const skill_content =
        \\---
        \\name: _regression_uaf_use_skill_loaded_test
        \\description: "Loaded-path regression test"
        \\---
        \\
        \\# Test content with REGRESSION_MARKER_12345
        \\
    ;
    {
        const f = try std.Io.Dir.createFileAbsolute(io, skill_file_path, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io, skill_content);
    }

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", tmp_home);

    const output = try execute_use_skill_to_string(
        alloc,
        io,
        .{ .path = skill_file_path },
        &env,
    );
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.loaded);
    try std.testing.expectEqualStrings(unique_skill_name, parsed.value.skill_name);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.content, unique_marker) != null);
    try std.testing.expect(parsed.value.@"error" == null);
}

test "use_skill_tool - schema declares is_global property" {
    // Find the is_global property in the tool definition. This guards against
    // the field being accidentally removed from the schema.
    const props = use_skill_tool.function.parameters.properties;
    var found_is_global = false;
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "is_global")) {
            found_is_global = true;
            try std.testing.expectEqualStrings("boolean", prop.type);
            break;
        }
    }
    try std.testing.expect(found_is_global);
}

test "execute_use_skill_to_string - absolute path loads skill file (loadSkillFromPath baseline)" {
    // Baseline: loadSkillFromPath with an absolute path must still work
    // after the openFileAbsolute → cwd().openFile swap. This guards against
    // a regression where the new code accidentally breaks the existing
    // absolute-path happy path.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/nalar-get-skill-abs-path-test";
    const skill_file = "/tmp/nalar-get-skill-abs-path-test/SKILL.MD";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: absolute-path-test
            \\description: "Absolute path baseline test"
            \\---
            \\
            \\# Absolute path body
            \\
        );
    }

    const input = UseSkillInput{ .path = skill_file };
    const output = try execute_use_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.loaded);
    try std.testing.expectEqualStrings("absolute-path-test", parsed.value.skill_name);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.content, "Absolute path body") != null);
}

test "execute_use_skill_to_string - relative path resolves against cwd (panic regression)" {
    // REGRESSION: previously, passing a relative path caused
    // std.Io.Dir.openFileAbsolute to `unreachable`-panic, killing the
    // entire worker process and bypassing every catch/try in the call
    // chain. See docs/plans/2025-01-15-get-skill-relative-path-panic.md
    //
    // We create a skill file at a relative path under cwd, then call
    // execute_use_skill_to_string with that relative path. Before the fix
    // this would SIGABRT; after the fix it loads successfully.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "tmp_use_skill_relative_test";
    const skill_file = "tmp_use_skill_relative_test/SKILL.MD";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(io, skill_file, .{});
        defer std.Io.File.close(f, io);
        try std.Io.File.writeStreamingAll(f, io,
            \\---
            \\name: relative-path-test
            \\description: "Relative path regression test"
            \\---
            \\
            \\# Relative path body
            \\
        );
    }

    const input = UseSkillInput{ .path = skill_file };
    const output = try execute_use_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.loaded);
    try std.testing.expectEqualStrings("relative-path-test", parsed.value.skill_name);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.content, "Relative path body") != null);
}

test "execute_use_skill_to_string - non-existent path returns JSON error (no panic, includes path)" {
    // REGRESSION: previously, a non-existent relative path would return a
    // generic "Failed to open file" with no path or OS error info — and if
    // a future caller ever wrapped openFileAbsolute without the same
    // defensive logic, it would panic and kill the worker. The fix
    // surfaces the path and the underlying OS error so the LLM can
    // self-correct on the next turn.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const missing_path = "this/path/does/not/exist/SKILL.MD";
    const input = UseSkillInput{ .path = missing_path };
    const output = try execute_use_skill_to_string(alloc, io, input, null);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(UseSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.loaded);
    // The path must appear in the error so the LLM knows what was tried.
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.@"error" orelse "", missing_path) != null);
    // Must NOT contain the word "unreachable" from the panic message.
    try std.testing.expect(std.mem.indexOf(u8, output, "unreachable") == null);
}
// ─── tests: remove_skill ───

test "remove_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = RemoveSkillInput{
        .skill_name = "",
        .session_id = "test-session",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try execute_remove_skill_to_string(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(RemoveSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.removed);
    try std.testing.expectEqualStrings("skill_name cannot be empty", parsed.value.@"error" orelse "");
}

test "remove_skill - tool definition includes is_global parameter" {
    const tool_def = remove_skill_tool;

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

test "remove_skill - tool definition has correct required fields" {
    const tool_def = remove_skill_tool;

    // Should have skill_name and session_id as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 2);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "session_id"));
}

test "remove_skill - is_global defaults to false" {
    const input = RemoveSkillInput{
        .skill_name = "test-skill",
        .session_id = "test-session",
    };
    try std.testing.expect(input.is_global == false);
}
// ─── tests: add_skill ───

test "add_skill - empty name returns error" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "",
        .description = "Test description",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings("Skill name cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - empty description returns error" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "",
        .content = "Test content",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings("Description cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - empty content returns error" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "",
        .is_global = false,
    };

    const io = std.testing.io;
    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings("Content cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - tool definition includes is_global parameter" {
    const tool_def = add_skill_tool;

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
    const tool_def = add_skill_tool;

    // Should have name, description, content as required (not is_global)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 3);
    try std.testing.expect(std.mem.eql(u8, required[0], "name"));
    try std.testing.expect(std.mem.eql(u8, required[1], "description"));
    try std.testing.expect(std.mem.eql(u8, required[2], "content"));
}

test "add_skill - is_global defaults to false" {
    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "Test content",
    };
    try std.testing.expect(input.is_global == false);
}

test "add_skill - buildSkillContent with special characters" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes",
        .content = "Test content with\\backslash",
        .is_global = false,
    };

    const content = buildSkillContent(alloc, input);
    defer alloc.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "name: test-skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "description: \"Test \\\"description\\\" with quotes\"") != null);
}

test "add_skill - executeAddSkillToString validates empty content" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test description",
        .content = "", // Empty content should fail
        .is_global = false,
    };

    const output = executeAddSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.created);
    try std.testing.expectEqualStrings("Content cannot be empty", parsed.value.@"error" orelse "");
}

test "add_skill - buildSkillContent escapes special characters" {
    const alloc = std.testing.allocator;

    const input = AddSkillInput{
        .name = "test-skill",
        .description = "Test \"description\" with quotes and\\backslash",
        .content = "Test content",
        .is_global = false,
    };

    const content = buildSkillContent(alloc, input);
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
    const first_input = AddSkillInput{
        .name = skill_name,
        .description = "First version description",
        .content = "# First version\n\nThis is the original long body that should be completely replaced on overwrite.",
        .create_with_dir = true,
        .is_global = false,
    };
    const first_output = executeAddSkillToString(alloc, io, tmp_path, null, first_input);
    defer alloc.free(first_output);
    const first_parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, first_output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer first_parsed.deinit();
    try std.testing.expect(first_parsed.value.created);

    // Sanity-check the first version landed on disk
    const first_read = try std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, alloc, std.Io.Limit.limited(64 * 1024));
    defer alloc.free(first_read);
    try std.testing.expect(std.mem.indexOf(u8, first_read, "First version description") != null);

    // Second add_skill: write a SHORTER skill body with the SAME name.
    // If the createFile call is buggy and appends, the file would
    // contain BOTH versions concatenated.
    const second_input = AddSkillInput{
        .name = skill_name,
        .description = "Second desc",
        .content = "v2",
        .create_with_dir = true,
        .is_global = false,
    };
    const second_output = executeAddSkillToString(alloc, io, tmp_path, null, second_input);
    defer alloc.free(second_output);
    const second_parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, second_output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer second_parsed.deinit();
    try std.testing.expect(second_parsed.value.created);

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

    const input = AddSkillInput{
        .name = skill_name,
        .description = "Test description for local skill",
        .content = "# Test skill content\n\nThis is a test.",
        .create_with_dir = true,
        .is_global = false,
    };

    const output = executeAddSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    const parsed = try std.json.parseFromSlice(AddSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.created);
    try std.testing.expectEqualStrings(skill_name, parsed.value.skill_name);

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
// ─── tests: edit_skill ───

test "edit_skill - empty skill_name returns error" {
    const alloc = std.testing.allocator;

    const input = EditSkillInput{
        .skill_name = "",
        .description = try alloc.dupe(u8, "New description"),
        .content = null,
        .is_global = false,
    };
    defer alloc.free(input.description.?);

    const io = std.testing.io;
    const output = try executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.updated);
    try std.testing.expectEqualStrings("Skill name cannot be empty", parsed.value.@"error" orelse "");
}

test "edit_skill - neither description nor content provided returns error" {
    const alloc = std.testing.allocator;

    const input = EditSkillInput{
        .skill_name = "test-skill",
        .description = null,
        .content = null,
        .is_global = false,
    };

    const io = std.testing.io;
    const output = try executeEditSkillToString(alloc, io, "/tmp", null, input);
    defer alloc.free(output);

    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.updated);
    try std.testing.expectEqualStrings("At least one of description or content must be provided", parsed.value.@"error" orelse "");
}

test "edit_skill - tool definition includes is_global parameter" {
    const tool_def = edit_skill_tool;

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
    const tool_def = edit_skill_tool;

    // Should have skill_name as required (not description or content)
    const required = tool_def.function.parameters.required;
    try std.testing.expect(required.len == 1);
    try std.testing.expect(std.mem.eql(u8, required[0], "skill_name"));
}

test "edit_skill - is_global defaults to false" {
    const input = EditSkillInput{
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

    const input = EditSkillInput{
        .skill_name = skill_name,
        .description = new_description,
        .content = new_content,
        .is_global = false,
    };

    const output = try executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);

    // Verify the success response
    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.updated);
    try std.testing.expectEqualStrings(skill_name, parsed.value.skill_name);

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
    const input = EditSkillInput{
        .skill_name = skill_name,
        .description = "new",
        .content = "v2",
        .is_global = false,
    };
    const output = try executeEditSkillToString(alloc, io, tmp_path, null, input);
    defer alloc.free(output);
    const parsed = try std.json.parseFromSlice(EditSkillOutput, alloc, output, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.updated);

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

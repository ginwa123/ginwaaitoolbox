const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for get_skill tool
pub const GetSkillInput = struct {
    skill_name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    /// If true, only search the global skills directory (~/.config/nalar/skills/).
    /// If false (default), search local (.nalar/skills/) first, then fall back to global.
    /// Has no effect when `path` is set (path is always loaded as-is).
    is_global: bool = false,
};

/// Result structure for get_skill tool
pub const GetSkillResult = struct {
    skill_name: []const u8,
    content: []const u8,
    loaded: bool,
    path: ?[]const u8 = null,
    err_msg: ?[]const u8 = null,
    available_skills: ?[]const []const u8 = null,
};

/// Tool definition for get_skill
pub const get_skill_tool = AgentTool{
    .type = "function",
    .function = .{
        .name = "get_skill",
        .description = "Load a skill's full content on-demand. Use this when you need detailed guidance for a specific capability. By default both local (.nalar/skills/) and global (~/.config/nalar/skills/) directories are searched; pass is_global=true to only search the global directory.",
        .parameters = .{
            .type = "object",
            .properties = &.{
                .{
                    .name = "skill_name",
                    .type = "string",
                    .description = "The exact name of the skill to load",
                },
                .{
                    .name = "path",
                    .type = "string",
                    .description = "Load skill from absolute file path. When set, is_global has no effect and the file is loaded as-is.",
                },
                .{
                    .name = "is_global",
                    .type = "boolean",
                    .description = "If true, only search the global skills directory (~/.config/nalar/skills/). If false (default), search local first, then fall back to global.",
                },
            },
            .required = &.{},
        },
    },
};

/// Execute the get_skill tool
/// Returns an XML string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_get_skill_to_string(allocator: std.mem.Allocator, io: std.Io, input: GetSkillInput, environment: ?*const std.process.Environ.Map) ![]const u8 {
    // Check if path is provided - load from file
    if (input.path) |path| {
        return loadSkillFromPath(allocator, io, path);
    }

    // Otherwise try to parse by skill name
    if (input.skill_name) |skill_name| {
        return loadSkillByName(allocator, io, skill_name, input.is_global, environment);
    }

    // No skill_name or path provided
    return error.InvalidInput;
}

/// Load skill from absolute file path
fn loadSkillFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to open file</error>
        , .{});
        return result;
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to read file</error>
        , .{});
        return result;
    };
    defer allocator.free(content);

    // Extract filename without extension for skill_name
    const filename = std.fs.path.basename(path);
    const ext = std.fs.path.extension(filename);
    const skill_name = filename[0 .. filename.len - ext.len];

    const result = try std.fmt.allocPrint(allocator,
        \\<skill_name>{s}</skill_name>
        \\<content>{s}</content>
        \\<loaded>true</loaded>
    , .{ skill_name, content });
    return result;
}

/// Load skill by name from built-in skills
/// If is_global is true, only the global path (~/.config/nalar/skills/) is searched.
/// If is_global is false, both local and global paths are searched, local first.
fn loadSkillByName(allocator: std.mem.Allocator, io: std.Io, skill_name: []const u8, is_global: bool, environment: ?*const std.process.Environ.Map) ![]const u8 {
    // Try to parse the skill. When is_global is true, only the global path is
    // searched; otherwise local is tried first, then global as fallback.
    if (skills.parse_skill(allocator, io, skill_name, is_global, environment)) |content| {
        defer allocator.free(content);
        // Success - return the skill content
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<content>{s}</content>
            \\<loaded>true</loaded>
        , .{ skill_name, content });
        return result;
    } else {
        // Skill not found - list available skills from the searched scope.
        //
        // IMPORTANT: we append each skill's name into `available_str` *while*
        // the source SkillInfo slice is still alive. Previously we copied slice
        // headers into an intermediate `all_skills: ArrayList([]const u8)`, then
        // `defer free_skills_list` freed the backing memory. The next loop
        // then read 0xAA-filled freed memory (Zig debug allocator's free-fill
        // pattern), producing the garbled `<skill>...</skill>` output that
        // looks like an encoding bug. See NALAR.md.
        var available_str: std.ArrayList(u8) = .empty;
        defer available_str.deinit(allocator);

        // List global skills (always - they're the fallback scope, and when
        // is_global=true they're the only scope).
        if (environment) |env| {
            if (skills.get_global_skills_path_from_env(allocator, env)) |global_path| {
                defer allocator.free(global_path);
                const global_list = skills.list_skills_from_dir_path(allocator, io, global_path);
                defer skills.free_skills_list(allocator, global_list);
                for (global_list) |skill| {
                    try available_str.appendSlice(allocator, "<skill>");
                    try available_str.appendSlice(allocator, skill.name);
                    try available_str.appendSlice(allocator, "</skill>");
                }
            }
        }

        // List local skills only when not in global-only mode.
        if (!is_global) {
            if (skills.get_local_skills_path_from_io(allocator, io)) |local_path| {
                defer allocator.free(local_path);
                const local_list = skills.list_skills_from_dir_path(allocator, io, local_path);
                defer skills.free_skills_list(allocator, local_list);
                for (local_list) |skill| {
                    try available_str.appendSlice(allocator, "<skill>");
                    try available_str.appendSlice(allocator, skill.name);
                    try available_str.appendSlice(allocator, "</skill>");
                }
            }
        }

        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name>{s}</skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Skill not found</error>
            \\<available_skills>{s}</available_skills>
        , .{ skill_name, available_str.items });

        return result;
    }
}

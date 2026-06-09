const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Input structure for get_skill tool
pub const GetSkillInput = struct {
    /// Load skill from file path. Accepts both absolute paths and relative
    /// paths (resolved against the session's current working directory).
    path: ?[]const u8 = null,
    /// Reserved for forward compatibility — currently has no effect because
    /// the only code path is `loadSkillFromPath`, which reads the file as-is.
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
    },
};

/// Execute the get_skill tool
/// Returns an XML string with the skill content or error message
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_get_skill_to_string(allocator: std.mem.Allocator, io: std.Io, input: GetSkillInput, environment: ?*const std.process.Environ.Map) ![]const u8 {
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
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to open file "{s}": {s}</error>
        , .{ path, @errorName(err) });
        return result;
    };
    defer std.Io.File.close(file, io);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(std.math.maxInt(usize))) catch |err| {
        const result = try std.fmt.allocPrint(allocator,
            \\<skill_name></skill_name>
            \\<content></content>
            \\<loaded>false</loaded>
            \\<error>Failed to read file "{s}": {s}</error>
        , .{ path, @errorName(err) });
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

const std = @import("std");
const schemas = @import("schemas.zig");
const ToolProperty = schemas.ToolProperty;
const ToolParameters = schemas.ToolParameters;
const AgentToolFunction = schemas.AgentToolFunction;
const AgentTool = schemas.AgentTool;
const skills = @import("skills.zig");

/// Result structure for list_skills tool
pub const ListSkillsResult = struct {
    skills: []skills.SkillInfo,
};

/// Tool definition for list_skills
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
    },
};

/// Execute the list_skills tool
/// Returns a JSON string with the list of available skills
/// Caller owns the returned memory and must free it with allocator.free()
pub fn execute_list_skills(allocator: std.mem.Allocator, io: std.Io, cwd_param: ?[]const u8, environment: ?*const std.process.Environ.Map) ![]const u8 {
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
    defer skills.free_skills_list(allocator, global_skills);

    // List local skills
    var local_skills: []skills.SkillInfo = &[_]skills.SkillInfo{};
    if (local_path) |path| {
        local_skills = skills.list_skills_from_dir_path(allocator, io, path);
    }
    defer skills.free_skills_list(allocator, local_skills);

    // Build JSON using std.json.Stringify
    const response = ListSkillsResponse{
        .global_skills = global_skills,
        .local_skills = local_skills,
        .cwd = cwd_param,
    };

    return std.json.Stringify.valueAlloc(allocator, response, .{});
}

/// Response structure for list_skills tool
pub const ListSkillsResponse = struct {
    global_skills: []const skills.SkillInfo,
    local_skills: []const skills.SkillInfo,
    cwd: ?[]const u8,
};
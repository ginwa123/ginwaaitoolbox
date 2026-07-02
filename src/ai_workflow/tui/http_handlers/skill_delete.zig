const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const skill_mod = nalarcore.skill_mod;

/// Response structure for skill delete endpoint
pub const SkillDeleteResponse = struct {
    success: bool,
    skill_name: []const u8,
    deleted_from: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const SkillDeleteError = error{
    OutOfMemory,
    MissingName,
    EmptyName,
    MissingCwdForLocal,
    GlobalSkillsDirectoryNotFound,
    LocalSkillsDirectoryNotFound,
    SkillNotFound,
    DirectoryDeletionFailed,
};

const SkillDeleteInput = struct {
    name: []const u8,
    is_global: bool,
    cwd: ?[]const u8,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
};

const SkillDeleteResult = struct {
    /// Pre-serialized JSON deleted_from hint string ("global" or the local
    /// skills dir path). Caller decides how to encode it in the response.
    deleted_from_hint: []const u8,
};

/// DELETE /api/skills?name=...&is_global=...&cwd=...
/// Deletes a skill from either global (~/.config/nalar/skills/) or local (.nalar/skills/) directory
pub fn skillDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();

    const name = req.query.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter is required",
        }, .{}) });
    };

    const is_global_str = req.query.get("is_global") orelse "false";
    const is_global = std.mem.eql(u8, is_global_str, "true");
    const cwd = req.query.get("cwd");

    const result = useCase(allocator, .{
        .name = name,
        .is_global = is_global,
        .cwd = cwd,
        .io = ctx.io,
        .environment = di.environment,
    }) catch |err| {
        const status: u16 = switch (err) {
            error.MissingName, error.EmptyName, error.MissingCwdForLocal => 400,
            error.GlobalSkillsDirectoryNotFound, error.LocalSkillsDirectoryNotFound, error.SkillNotFound => 404,
            error.DirectoryDeletionFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.MissingName => "name query parameter is required",
            error.EmptyName => "name query parameter cannot be empty",
            error.MissingCwdForLocal => "cwd query parameter is required for local skill deletion",
            error.GlobalSkillsDirectoryNotFound => "Global skills directory not found",
            error.LocalSkillsDirectoryNotFound => "Local skills directory not found",
            error.SkillNotFound => blk: {
                const m = std.fmt.allocPrint(allocator, "Skill '{s}' not found in {s} directory", .{
                    name,
                    if (is_global) "global" else "local",
                }) catch "Skill not found";
                break :blk m;
            },
            error.DirectoryDeletionFailed => "Failed to delete skill directory",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{ .status_code = status, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = name,
            .error_message = message,
        }, .{}) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
        .success = true,
        .skill_name = name,
        .deleted_from = result.deleted_from_hint,
    }, .{}) });
}

fn useCase(allocator: std.mem.Allocator, input: SkillDeleteInput) SkillDeleteError!SkillDeleteResult {
    if (input.name.len == 0) return error.EmptyName;

    if (input.is_global) {
        const global_path = skill_mod.get_global_skills_path_from_env(allocator, input_environment(input));
        defer if (global_path) |p| allocator.free(p);

        if (global_path == null) return error.GlobalSkillsDirectoryNotFound;

        const skill_dir_path = try findSkillFolderByName(allocator, input.io, global_path.?, input.name);
        if (skill_dir_path == null) return error.SkillNotFound;
        defer allocator.free(skill_dir_path.?);

        std.Io.Dir.cwd().deleteTree(input.io, skill_dir_path.?) catch {
            return error.DirectoryDeletionFailed;
        };

        return .{ .deleted_from_hint = "global" };
    } else {
        if (input.cwd == null) return error.MissingCwdForLocal;

        const local_path = skill_mod.get_local_skills_path_for_dir(allocator, input.cwd.?);
        defer if (local_path) |p| allocator.free(p);

        if (local_path == null) return error.LocalSkillsDirectoryNotFound;

        const skill_dir_path = try findSkillFolderByName(allocator, input.io, local_path.?, input.name);
        if (skill_dir_path == null) return error.SkillNotFound;
        defer allocator.free(skill_dir_path.?);

        std.Io.Dir.cwd().deleteTree(input.io, skill_dir_path.?) catch {
            return error.DirectoryDeletionFailed;
        };

        return .{ .deleted_from_hint = local_path.? };
    }
}

fn input_environment(input: SkillDeleteInput) *const std.process.Environ.Map {
    return input.environment.?;
}

/// Find the folder path for a skill by its name from YAML frontmatter
/// Returns allocated path string if found, null if not found
fn findSkillFolderByName(allocator: std.mem.Allocator, io: std.Io, skills_dir: []const u8, skill_name: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, skills_dir, .{ .iterate = true }) catch {
        return null;
    };
    defer std.Io.Dir.close(dir, io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        const skill_file_path = std.fs.path.join(allocator, &[_][]const u8{ skills_dir, entry.name, "SKILL.MD" }) catch continue;
        defer allocator.free(skill_file_path);

        const content = std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, allocator, std.Io.Limit.limited(100 * 1024)) catch {
            continue;
        };
        defer allocator.free(content);

        if (content.len == 0) continue;

        if (skill_mod.parseYamlFrontmatter(allocator, content)) |parsed| {
            if (std.mem.eql(u8, parsed.name, skill_name)) {
                // Return the folder path, not the SKILL.MD path
                const folder_path = std.fs.path.join(allocator, &[_][]const u8{ skills_dir, entry.name }) catch continue;
                return folder_path;
            }
        }
    }

    return null;
}
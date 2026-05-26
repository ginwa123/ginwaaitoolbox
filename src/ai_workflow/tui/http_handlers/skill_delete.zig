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

/// DELETE /api/skills?name=...&is_global=...&cwd=...
/// Deletes a skill from either global (~/.config/nalar/skills/) or local (.nalar/skills/) directory
pub fn skillDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const environment = di.environment;

    // Get query parameters
    const name = req.query.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter is required",
        }, .{}) });
    };

    if (name.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter cannot be empty",
        }, .{}) });
    }

    // Parse is_global parameter (default: false)
    const is_global_str = req.query.get("is_global") orelse "false";
    const is_global = std.mem.eql(u8, is_global_str, "true");

    // Get optional cwd for local skills
    const cwd = req.query.get("cwd");

    const io = ctx.io;

    if (is_global) {
        // Delete from global skills directory
        const global_path = skill_mod.get_global_skills_path_from_env(allocator, environment.?);
        defer if (global_path) |p| allocator.free(p);

        if (global_path == null) {
            return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Global skills directory not found",
            }, .{}) });
        }

        // Find the skill folder by skill name (from YAML, not folder name)
        const skill_dir_path = try findSkillFolderByName(allocator, io, global_path.?, name);
        if (skill_dir_path == null) {
            return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = try std.fmt.allocPrint(allocator, "Skill '{s}' not found in global directory", .{name}),
            }, .{}) });
        }
        defer allocator.free(skill_dir_path.?);

        // Delete the skill directory recursively
        std.Io.Dir.cwd().deleteTree(io, skill_dir_path.?) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Failed to delete skill directory",
            }, .{}) });
        };

        return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = true,
            .skill_name = name,
            .deleted_from = "global",
        }, .{}) });
    } else {
        // Delete from local skills directory
        if (cwd == null) {
            return res.jsonResponse( .{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "cwd query parameter is required for local skill deletion",
            }, .{}) });
        }

        const local_path = skill_mod.get_local_skills_path_for_dir(allocator, cwd.?);
        defer if (local_path) |p| allocator.free(p);

        if (local_path == null) {
            return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Local skills directory not found",
            }, .{}) });
        }

        // Find the skill folder by skill name (from YAML, not folder name)
        const skill_dir_path = try findSkillFolderByName(allocator, io, local_path.?, name);
        if (skill_dir_path == null) {
            return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = try std.fmt.allocPrint(allocator, "Skill '{s}' not found in local directory", .{name}),
            }, .{}) });
        }
        defer allocator.free(skill_dir_path.?);

        // Delete the skill directory recursively
        std.Io.Dir.cwd().deleteTree(io, skill_dir_path.?) catch {
            return res.jsonResponse(.{ .status_code = 500, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Failed to delete skill directory",
            }, .{}) });
        };

        return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = true,
            .skill_name = name,
            .deleted_from = local_path,
        }, .{}) });
    }
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

const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const skills = root_mod.skills;

const httpz = http_server.httpz;

/// Response structure for skill delete endpoint
pub const SkillDeleteResponse = struct {
    success: bool,
    skill_name: []const u8,
    deleted_from: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

/// DELETE /api/skills?name=...&is_global=...&cwd=...
/// Deletes a skill from either global (~/.config/nalar/skills/) or local (.nalar/skills/) directory
pub fn skillDeleteHandler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Get query parameters
    const query = try req.query();

    const name = query.get("name") orelse {
        res.status = 400;
        const response = SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter is required",
        };
        res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
        return;
    };

    if (name.len == 0) {
        res.status = 400;
        const response = SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter cannot be empty",
        };
        res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
        return;
    }

    // Parse is_global parameter (default: false)
    const is_global_str = query.get("is_global") orelse "false";
    const is_global = std.mem.eql(u8, is_global_str, "true");

    // Get optional cwd for local skills
    const cwd = query.get("cwd");

    const io = self.io;

    if (is_global) {
        // Delete from global skills directory
        const environment = self.server.environment;
        const global_path = skills.get_global_skills_path_from_env(alloc, environment);
        defer if (global_path) |p| alloc.free(p);

        if (global_path == null) {
            res.status = 404;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Global skills directory not found",
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }

        const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ global_path.?, name });
        defer alloc.free(skill_dir_path);

        // Check if the skill directory exists
        const dir_exists = blk: {
            std.Io.Dir.cwd().access(io, skill_dir_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (!dir_exists) {
            res.status = 404;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = try std.fmt.allocPrint(alloc, "Skill '{s}' not found in global directory", .{name}),
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }

        // Delete the skill directory recursively
        std.Io.Dir.cwd().deleteTree(io, skill_dir_path) catch {
            res.status = 500;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Failed to delete skill directory",
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        };

        res.status = 200;
        const response = SkillDeleteResponse{
            .success = true,
            .skill_name = name,
            .deleted_from = "global",
        };
        res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
        return;
    } else {
        // Delete from local skills directory
        if (cwd == null) {
            res.status = 400;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "cwd query parameter is required for local skill deletion",
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }

        const local_path = skills.get_local_skills_path_for_dir(alloc, cwd.?);
        defer if (local_path) |p| alloc.free(p);

        if (local_path == null) {
            res.status = 404;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Local skills directory not found",
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }

        const skill_dir_path = try std.fs.path.join(alloc, &[_][]const u8{ local_path.?, name });
        defer alloc.free(skill_dir_path);

        // Check if the skill directory exists
        const dir_exists = blk: {
            std.Io.Dir.cwd().access(io, skill_dir_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (!dir_exists) {
            res.status = 404;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = try std.fmt.allocPrint(alloc, "Skill '{s}' not found in local directory", .{name}),
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }

        // Delete the skill directory recursively
        std.Io.Dir.cwd().deleteTree(io, skill_dir_path) catch {
            res.status = 500;
            const response = SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = "Failed to delete skill directory",
            };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        };

        res.status = 200;
        const response = SkillDeleteResponse{
            .success = true,
            .skill_name = name,
            .deleted_from = local_path,
        };
        res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
        return;
    }
}
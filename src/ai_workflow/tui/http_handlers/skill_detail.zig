const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const skills = root_mod.skills;

const httpz = http_server.httpz;

/// Response structure for skill detail endpoint
pub const SkillDetailResponse = struct {
    skill: ?SkillDetail = null,
    error_message: ?[]const u8 = null,
};

/// Skill detail structure with full content
pub const SkillDetail = struct {
    name: []const u8,
    description: []const u8,
    content: []const u8,
    path: []const u8,
    is_global: bool,
};

/// GET /api/skills/:name - Get detailed skill information including full content
/// Searches both global (~/.config/nalar/skills/) and local (.nalar/skills/) directories
pub fn skillDetailHandler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Get skill name from path parameter
    const skill_name = req.param("name") orelse {
        res.status = 400;
        const response = SkillDetailResponse{ .error_message = "Skill name is required" };
        res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
        return;
    };

    // Get environment from server
    const environment = self.server.environment;

    // Get global and local skills paths
    const global_path = skills.get_global_skills_path_from_env(alloc, environment);
    defer if (global_path) |p| alloc.free(p);

    const local_path = skills.get_local_skills_path_from_io(alloc, self.io);
    defer if (local_path) |p| alloc.free(p);

    // Try to find the skill in global directory first
    if (global_path) |path| {
        if (try findSkillByName(alloc, self.io, path, skill_name)) |detail| {
            res.status = 200;
            const response = SkillDetailResponse{ .skill = detail };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }
    }

    // Try local directory
    if (local_path) |path| {
        if (try findSkillByName(alloc, self.io, path, skill_name)) |detail| {
            res.status = 200;
            const response = SkillDetailResponse{ .skill = detail };
            res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
            return;
        }
    }

    // Skill not found
    res.status = 404;
    const response = SkillDetailResponse{ .error_message = try std.fmt.allocPrint(alloc, "Skill '{s}' not found", .{skill_name}) };
    res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});
}

/// Find a skill by name in the given directory
/// Returns SkillDetail with allocated strings, or null if not found
fn findSkillByName(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, skill_name: []const u8) !?SkillDetail {
    // Open the skills directory
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        return null;
    };
    defer std.Io.Dir.close(dir, io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Check if this folder matches the skill name
        if (!std.mem.eql(u8, entry.name, skill_name)) continue;

        // Build path to SKILL.MD
        const skill_file_path = std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name, "SKILL.MD" }) catch continue;
        defer allocator.free(skill_file_path);

        // Read the skill file
        const content = std.Io.Dir.cwd().readFileAlloc(io, skill_file_path, allocator, std.Io.Limit.limited(100 * 1024)) catch {
            continue;
        };
        defer allocator.free(content);

        if (content.len == 0) continue;

        // Parse YAML frontmatter
        if (skills.parseYamlFrontmatter(allocator, content)) |parsed| {
            // The content from parseYamlFrontmatter has already extracted name/description
            // We return the full content including frontmatter
            const path_copy = try allocator.dupe(u8, skill_file_path);
            errdefer allocator.free(path_copy);

            const name_copy = try allocator.dupe(u8, parsed.name);
            errdefer allocator.free(name_copy);

            const desc_copy = try allocator.dupe(u8, parsed.description);
            errdefer allocator.free(desc_copy);

            return SkillDetail{
                .name = name_copy,
                .description = desc_copy,
                .content = try allocator.dupe(u8, content),
                .path = path_copy,
                .is_global = true, // Will be overwritten by caller if local
            };
        }
    }

    return null;
}

/// Find a skill by name and return whether it's global or local
/// is_global parameter indicates if searching global directory
fn findSkillByNameWithScope(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, skill_name: []const u8, is_global: bool) !?SkillDetail {
    const detail = try findSkillByName(allocator, io, dir_path, skill_name);
    if (detail) |*d| {
        d.is_global = is_global;
    }
    return detail;
}
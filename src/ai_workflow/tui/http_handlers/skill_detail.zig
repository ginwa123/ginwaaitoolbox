const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const skill_mod = nalarcore.skill_mod;

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
pub fn skillDetailHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    // Get skill name from path parameter
    const skill_name = req.params.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .error_message = "Skill name is required" }, .{}) });
    };

    const di = try nalarcore.getSingleton();
    const environment = di.environment;

    // Get global and local skills paths
    const global_path = skill_mod.get_global_skills_path_from_env(allocator, environment.?);
    defer if (global_path) |p| allocator.free(p);

    const local_path = skill_mod.get_local_skills_path_from_io(allocator, ctx.io);
    defer if (local_path) |p| allocator.free(p);

    // Try to find the skill in global directory first
    if (global_path) |path| {
        if (try findSkillByName(allocator, ctx.io, path, skill_name)) |detail| {
            return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .skill = detail }, .{}) });
        }
    }

    // Try local directory
    if (local_path) |path| {
        if (try findSkillByName(allocator, ctx.io, path, skill_name)) |detail| {
            var detail_with_scope = detail;
            detail_with_scope.is_global = false;
            return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .skill = detail_with_scope }, .{}) });
        }
    }

    // Skill not found
    return res.jsonResponse(.{ .status_code = 404, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .error_message = try std.fmt.allocPrint(allocator, "Skill '{s}' not found", .{skill_name}) }, .{}) });
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
        if (skill_mod.parseYamlFrontmatter(allocator, content)) |parsed| {
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

const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const skills_mod = root_mod.skills;

const httpz = http_server.httpz;

/// GET /api/skills - List all skills from global and local directories
/// Global skills come from ~/.config/nalar/skills/ (or XDG_CONFIG_HOME)
/// Local skills come from {cwd}/.nalar/skills/
pub fn skillsListHandler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    // Get optional cwd from query parameter
    const query = try req.query();
    const cwd_param = query.get("cwd");

    // Get environment from server
    const environment = self.server.environment;

    // Get global skills path (from config folder)
    const global_path = skills_mod.get_global_skills_path_from_env(alloc, environment);

    // Get local skills path (from cwd)
    const local_path: ?[]const u8 = if (cwd_param) |cwd|
        skills_mod.get_local_skills_path_for_dir(alloc, cwd)
    else
        skills_mod.get_local_skills_path_from_io(alloc, self.io);
    defer if (local_path) |p| alloc.free(p);
    defer if (global_path) |p| alloc.free(p);

    // List global skills
    var global_skills: []skills_mod.SkillInfo = &[_]skills_mod.SkillInfo{};
    if (global_path) |path| {
        global_skills = skills_mod.list_skills_from_dir_path(alloc, self.io, path);
    }

    // List local skills
    var local_skills: []skills_mod.SkillInfo = &[_]skills_mod.SkillInfo{};
    if (local_path) |path| {
        local_skills = skills_mod.list_skills_from_dir_path(alloc, self.io, path);
    }

    // Build response using std.json.Stringify
    const response = SkillsListResponse{
        .global_skills = global_skills,
        .local_skills = local_skills,
        .cwd = cwd_param,
    };

    res.status = 200;
    res.body = try std.json.Stringify.valueAlloc(alloc, response, .{});

    // Free skills
    skills_mod.free_skills_list(alloc, global_skills);
    skills_mod.free_skills_list(alloc, local_skills);
}

/// Response structure for skills list endpoint
pub const SkillsListResponse = struct {
    global_skills: []const skills_mod.SkillInfo,
    local_skills: []const skills_mod.SkillInfo,
    cwd: ?[]const u8,
};
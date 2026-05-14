const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const skills_mod = root_mod.skills;
const list_skills_mod = root_mod.list_skills_tool;

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

    // List all skills using shared module
    const data = try list_skills_mod.listAllSkills(alloc, self.io, cwd_param, environment);
    errdefer list_skills_mod.freeSkillsListData(alloc, data);

    // Convert to JSON using shared module
    const json_response = try list_skills_mod.toJson(alloc, data);

    res.status = 200;
    res.body = json_response;
}
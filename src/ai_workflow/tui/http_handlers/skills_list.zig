const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const list_skills_mod = nalarcore.list_skills_tool;


/// GET /api/skills - List all skills from global and local directories
/// Global skills come from ~/.config/nalar/skills/ (or XDG_CONFIG_HOME)
/// Local skills come from {cwd}/.nalar/skills/
pub fn skillsListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const cwd_param = req.query.get("cwd");

    const di = try nalarcore.getSingleton();
    const environment = di.environment;


    // List all skills using shared module
    const data = try list_skills_mod.listAllSkills(allocator, ctx.io, cwd_param, environment);
    errdefer list_skills_mod.freeSkillsListData(allocator, data);

    // Convert to JSON using shared module
    const json_response = try list_skills_mod.toJson(allocator, data);

    return res.jsonResponse( .{ .status_code = 200, .data = json_response });
}

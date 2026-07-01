//! `GET /api/skills` — list all skills from global and local dirs.
//!
//! Global skills come from `~/.config/nalar/skills/` (or
//! `XDG_CONFIG_HOME`); local skills come from `{cwd}/.nalar/skills/`.
//!
//! Layered as `useCase` (resolve singleton + read skills + serialize
//! to JSON) and a thin handler that maps errors to status codes.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const list_skills_mod = nalarcore.list_skills_tool;

pub const SkillsListError = error{
    GlobalContextNotInitialized,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
) SkillsListError![]u8 {
    const di = nalarcore.getSingleton() catch return error.GlobalContextNotInitialized;
    const environment = di.environment;

    // List all skills using the shared module. `listAllSkills` returns
    // a `SkillsListData` whose `errdefer freeSkillsListData` is the
    // caller's responsibility.
    const data = try list_skills_mod.listAllSkills(allocator, io, cwd_param, environment);
    errdefer list_skills_mod.freeSkillsListData(allocator, data);

    // Convert to JSON. Caller owns the returned slice (lives until
    // the per-request arena is reset).
    return try list_skills_mod.toJson(allocator, data);
}

// =====================================================================
// Handler
// =====================================================================

pub fn skillsListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const cwd_param = req.query.get("cwd");

    const json_response = useCase(allocator, ctx.io, cwd_param) catch |err| {
        const status: u16 = switch (err) {
            error.GlobalContextNotInitialized => 500,
        };
        const message: []const u8 = switch (err) {
            error.GlobalContextNotInitialized => "Global context not initialized",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try nalarcore.http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = json_response });
}
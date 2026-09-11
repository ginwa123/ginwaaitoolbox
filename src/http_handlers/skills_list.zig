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
const list_skills_mod = nalarcore.skill_tools;

/// Domain-level error set for `useCase`. The `listAllSkills` +
/// `toJson` pipeline can fail with various Io / allocation errors
/// (OutOfMemory, Canceled, …) — we collapse all of these into the
/// single `Internal` variant since they all map to the same 500
/// status and the caller doesn't need to distinguish them.
pub const SkillsListError = error{
    Internal,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_param: ?[]const u8,
) SkillsListError![]const u8 {
    const di = nalarcore.getSingleton() catch return error.Internal;
    const environment = di.environment;

    // List all skills. Catch the broader set of Io/alloc errors and
    // collapse them to `error.Internal` so the declared error set
    // matches the body's actual error surface.
    const data = list_skills_mod.listAllSkills(allocator, io, cwd_param, environment) catch return error.Internal;
    errdefer list_skills_mod.freeSkillsListData(allocator, data);

    // Convert to JSON. `toJson` returns `error_set![]const u8` —
    // collapse any internal errors to `error.Internal`.
    return list_skills_mod.toJson(allocator, data) catch return error.Internal;
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
            error.Internal => 500,
        };
        const message: []const u8 = switch (err) {
            error.Internal => "Internal server error",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try nalarcore.http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = json_response });
}
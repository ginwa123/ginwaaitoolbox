//! `GET /api/skills` — list all skills from the `skills` table.
//!
//! Global rows (`is_global = 1`) and the workspace's local rows
//! (`is_global = 0 AND cwd = ?`) are returned in the same
//! `{global_skills, local_skills, cwd}` envelope the filesystem era used, so
//! the frontend is unchanged and `list_skills`' tool payload keeps its shape.
//!
//! Each entry's `path` is the row's `source_path` — provenance, and empty for
//! skills the agent created.
//!
//! Layered as `useCase` (resolve DB + read + serialize) and a thin handler that
//! maps errors to status codes.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const list_skills_mod = nalarcore.skill_tools;
const sqlite = nalarcore.sqlite;

/// Domain-level error set for `useCase`.
pub const SkillsListError = error{
    Internal,
};

/// =====================================================================
// Use case
/// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    cwd_param: ?[]const u8,
) SkillsListError![]const u8 {
    // The listing path can fail with Io / Db / alloc errors (OutOfMemory,
    // Canceled, Constraint, …) — all of which map to the same 500, so they
    // collapse into one variant rather than widening the error set.
    const data = list_skills_mod.listAllSkills(allocator, io, db, cwd_param) catch return error.Internal;
    errdefer list_skills_mod.freeSkillsListData(allocator, data);

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
    const di = try nalarcore.getSingleton();

    const json_response = useCase(allocator, ctx.io, di.db, cwd_param) catch |err| {
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

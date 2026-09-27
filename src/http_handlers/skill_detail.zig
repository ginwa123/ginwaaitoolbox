//! `GET /api/skills/:name` — one skill, with its full content, from the
//! `skills` table.
//!
//! Resolution is local-first then global, matching `use_skill`, so the detail
//! view and the agent agree on which row "the skill named X" means. The
//! response shape is unchanged from the filesystem era — including
//! `is_global: boolean` and `path` (sourced from the row's `source_path`,
//! which is empty for skills the agent created).

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const skills_db = nalarcore.skills_db;
const sqlite = nalarcore.sqlite;

/// Response structure for skill detail endpoint
pub const SkillDetailResponse = struct {
    skill: ?SkillDetail = null,
    error_message: ?[]const u8 = null,
};

/// Skill detail structure with full content
pub const SkillDetail = struct {
    name: []const u8,
    description: []const u8,
    /// `'||'`-joined, or "" when the frontmatter carried no tags.
    tags: []const u8,
    content: []const u8,
    /// Provenance only — the row's `source_path`. May be "".
    path: []const u8,
    is_global: bool,
};

pub const SkillDetailError = error{
    Internal,
    NotFound,
    /// Unreachable under the per-request arena, but the dupes building
    /// SkillDetail can fail and the type system needs the variant named.
    OutOfMemory,
};

/// Look the row up and shape it for the wire.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    skill_name: []const u8,
    cwd_param: ?[]const u8,
) SkillDetailError!SkillDetail {
    // Prefer the caller's cwd — the frontend knows the active session's
    // workspace, the server does not. Falls back to the server's own cwd so
    // a plain `GET /api/skills/:name` still resolves local skills.
    const source_cwd: []const u8 = if (cwd_param) |c| (if (c.len > 0) c else ".") else ".";
    // canonicalCwd only fails on OOM, which collapses to 500 like every other
    // internal failure here.
    const canonical = skills_db.canonicalCwd(allocator, io, source_cwd) catch return error.Internal;
    defer allocator.free(canonical);

    const row = (skills_db.getSkill(allocator, db, skill_name, null, canonical) catch return error.Internal) orelse
        return error.NotFound;
    defer skills_db.freeSkillRow(allocator, row);

    return .{
        .name = try allocator.dupe(u8, row.name),
        .description = try allocator.dupe(u8, row.description),
        .tags = try allocator.dupe(u8, row.tags),
        .content = try allocator.dupe(u8, row.content),
        .path = try allocator.dupe(u8, row.source_path),
        .is_global = row.is_global,
    };
}

/// GET /api/skills/:name - Get detailed skill information including full content
pub fn skillDetailHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const skill_name = req.params.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .error_message = "Skill name is required" }, .{}) });
    };

    if (skill_name.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .error_message = "Skill name cannot be empty" }, .{}) });
    }

    const di = try nalarcore.getSingleton();
    const cwd_param = req.query.get("cwd");

    // The dupes inside `detail` live in the per-request arena, so nothing
    // here needs an explicit free.
    const detail = useCase(allocator, ctx.io, di.db, skill_name, cwd_param) catch |err| {
        const status: u16 = switch (err) {
            error.Internal, error.OutOfMemory => 500,
            error.NotFound => 404,
        };
        const message: []const u8 = switch (err) {
            error.Internal, error.OutOfMemory => "Internal server error",
            error.NotFound => try std.fmt.allocPrint(allocator, "Skill '{s}' not found", .{skill_name}),
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .error_message = message }, .{}),
        });
    };
    return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDetailResponse{ .skill = detail }, .{}) });
}

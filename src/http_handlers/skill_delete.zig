//! `DELETE /api/skills?name=…&is_global=…&cwd=…` — delete one row from the
//! `skills` table and best-effort clean its `SKILL.MD` mirror.
//!
//! The query string is unchanged from the filesystem era, which is why the
//! `is_global` decision mattered: a `(is_global, cwd, name)` key means a local
//! delete is unresolvable without `cwd`, so that case still returns 400 — the
//! same message the frontend already surfaces.

const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const skills_db = nalarcore.skills_db;
const sqlite = nalarcore.sqlite;

/// Response structure for skill delete endpoint
pub const SkillDeleteResponse = struct {
    success: bool,
    skill_name: []const u8,
    deleted_from: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const SkillDeleteError = error{
    Internal,
    NotFound,
    /// Unreachable under the per-request arena; see the note in
    /// skill_detail.zig.
    OutOfMemory,
};

/// Delete the row, then clean the mirror. Mirror failure is swallowed: the row
/// is gone, which is what the endpoint promised.
fn useCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    name: []const u8,
    is_global: bool,
    cwd: []const u8,
) SkillDeleteError!?[]const u8 {
    // A global row is keyed on cwd = "" by the schema invariant, so there is
    // nothing to canonicalise on that branch.
    const canonical: []const u8 = if (is_global) "" else
        (skills_db.canonicalCwd(allocator, io, cwd) catch return error.Internal);
    defer if (!is_global) allocator.free(canonical);

    const row = (skills_db.getSkill(allocator, db, name, is_global, canonical) catch
        return error.Internal) orelse
        return error.NotFound;
    defer skills_db.freeSkillRow(allocator, row);

    _ = skills_db.deleteSkill(allocator, db, name, is_global, canonical) catch
        return error.Internal;

    // source_path is <dir>/<name>/SKILL.MD; the folder is its parent.
    if (row.source_path.len > 0) {
        if (std.fs.path.dirname(row.source_path)) |folder| {
            std.Io.Dir.cwd().deleteTree(io, folder) catch {};
        }
    }

    return try allocator.dupe(u8, if (is_global) "global" else canonical);
}

/// DELETE /api/skills?name=...&is_global=...&cwd=...
pub fn skillDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const name = req.query.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter is required",
        }, .{}) });
    };

    if (name.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = "",
            .error_message = "name query parameter cannot be empty",
        }, .{}) });
    }

    const is_global = std.mem.eql(u8, req.query.get("is_global") orelse "false", "true");
    const cwd = req.query.get("cwd");

    // A local row is keyed by its workspace, so without `cwd` the key is
    // incomplete. Same 400 the filesystem version returned.
    if (!is_global and (cwd == null or cwd.?.len == 0)) {
        return res.jsonResponse(.{ .status_code = 400, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
            .success = false,
            .skill_name = name,
            .error_message = "cwd query parameter is required for local skill deletion",
        }, .{}) });
    }

    const di = try nalarcore.getSingleton();

    const deleted_from = useCase(allocator, ctx.io, di.db, name, is_global, cwd orelse "") catch |err| {
        const status: u16 = switch (err) {
            error.Internal, error.OutOfMemory => 500,
            error.NotFound => 404,
        };
        const message: []const u8 = switch (err) {
            error.Internal, error.OutOfMemory => "Internal server error",
            error.NotFound => try std.fmt.allocPrint(allocator, "Skill '{s}' not found", .{name}),
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
                .success = false,
                .skill_name = name,
                .error_message = message,
            }, .{}),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.json.Stringify.valueAlloc(allocator, SkillDeleteResponse{
        .success = true,
        .skill_name = name,
        .deleted_from = deleted_from,
    }, .{}) });
}

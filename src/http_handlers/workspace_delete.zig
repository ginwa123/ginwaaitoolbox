const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const auth_common = @import("auth_common.zig");

pub const WorkspaceDeleteError = error{
    OutOfMemory,
    DatabaseError,
    /// The workspace does not exist, or belongs to another user. The two
    /// cases are deliberately indistinguishable (404, never 403) so a
    /// caller cannot probe for the existence of someone else's ids.
    NotFound,
};

/// DELETE /api/workspaces/:id
pub fn workspaceDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"id required\"}" });
    }

    const result = useCase(allocator, sqlite_db, id, di.auth_enabled, req.headers) catch |err| {
        const message: []const u8 = switch (err) {
            error.DatabaseError => "Failed to delete workspace",
            error.OutOfMemory => "Out of memory",
            error.NotFound => "Workspace not found",
        };
        const status: u16 = switch (err) {
            error.NotFound => 404,
            else => 500,
        };
        return res.jsonResponse(.{ .status_code = status, .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}) });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{result.id}) });
}

const WorkspaceDeleteResult = struct {
    id: []const u8,
};

fn useCase(
    allocator: std.mem.Allocator,
    sqlite_db: *nalarcore.sqlite.SqliteBackend,
    id: []const u8,
    auth_enabled: bool,
    headers: anytype,
) WorkspaceDeleteError!WorkspaceDeleteResult {
    // Resolve the owner server-side (cookie only — never the body/path) and
    // refuse to touch a workspace this request cannot see. Without this a
    // caller could destroy another user's workspace by guessing its id.
    const owner = auth_common.resolveRequestUserId(allocator, sqlite_db, auth_enabled, headers) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(owner);

    {
        var q = sqlite_db.query(
            allocator,
            "SELECT 1 FROM workspaces WHERE id = ? AND " ++ comptime auth_common.ownerVisibilityClause("workspaces"),
            &[_][]const u8{ id, owner, owner },
        ) catch {
            std.log.warn("workspaceDelete: visibility check failed for {s}", .{id});
            return error.DatabaseError;
        };
        defer q.deinit();
        const row = q.next() catch {
            return error.DatabaseError;
        };
        if (row == null) return error.NotFound;
        if (row) |r| r.deinit(allocator);
    }

    sqlite_db.exec(
        allocator,
        "DELETE FROM workspaces WHERE id = ? AND " ++ comptime auth_common.ownerVisibilityClause("workspaces"),
        &[_][]const u8{ id, owner, owner },
    ) catch {
        std.log.warn("workspaceDelete: DELETE failed for {s}", .{id});
        return error.DatabaseError;
    };
    return .{ .id = id };
}
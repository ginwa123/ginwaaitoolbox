const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

pub const WorkspaceDeleteError = error{
    OutOfMemory,
    DatabaseError,
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

    const result = useCase(allocator, sqlite_db, id) catch |err| {
        const message: []const u8 = switch (err) {
            error.DatabaseError => "Failed to delete workspace",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{ .status_code = 500, .data = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{message}) });
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
) WorkspaceDeleteError!WorkspaceDeleteResult {
    sqlite_db.exec(allocator, "DELETE FROM workspaces WHERE id = ?", &[_][]const u8{id}) catch {
        std.log.warn("workspaceDelete: DELETE failed for {s}", .{id});
        return error.DatabaseError;
    };
    return .{ .id = id };
}
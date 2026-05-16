const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

/// DELETE /api/workspaces/:id
pub fn workspaceDeleteHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;
    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"id required\"}" });
    }

    sqlite_db.exec(allocator, "DELETE FROM workspaces WHERE id = ?", &.{id}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = "{\"error\":\"Failed to delete workspace\"}" });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"id\":\"{s}\"}}", .{id}) });
}


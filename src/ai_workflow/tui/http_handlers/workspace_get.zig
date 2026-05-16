const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// GET /api/workspaces/:id
pub fn workspaceGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"id required\"}" });
    }

    var rows = sqlite_db.query(allocator, "SELECT id, name, created_at, updated_at FROM workspaces WHERE id = ?", &.{id}) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = "{\"error\":\"Database query failed\"}" });
    };
    defer rows.deinit();

    const row = rows.next() catch {
        return res.jsonResponse(.{ .status_code = 500, .data = "{\"error\":\"Failed to fetch row\"" });
    };
    if (row) |r| {
        defer r.deinit(allocator);
        const ws_id = r.values[0];
        const name = r.values[1];
        const created_at = r.values[2];
        const updated_at = r.values[3];
        return res.jsonResponse(.{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"}}", .{ ws_id, name, created_at, updated_at }) });
    } else {
        return res.jsonResponse(.{ .status_code = 404, .data = "{\"error\":\"Workspace not found\"" });
    }
    return res.jsonResponse(.{ .status_code = 500, .data = "{\"error\":\"Server not initialized\"" });
}


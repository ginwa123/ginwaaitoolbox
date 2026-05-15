const std = @import("std");
const root_mod = @import("nalarcore");
const gserverz = root_mod.gserverz;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

/// GET /api/workspaces/:id
pub fn workspaceGetHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse, _: *anyopaque) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const id = req.params.get("id") orelse "";
    if (id.len == 0) {
        return res.jsonResponse(allocator, .{ .status_code = 400, .data = "{\"error\":\"id required\"}" });
    }

    if (gserverz.global_server) |server| {
        if (server.ctx) |server_ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(server_ctx)));
            const sqlite_db = ctxTui.db;

            var rows = sqlite_db.query(allocator, "SELECT id, name, created_at, updated_at FROM workspaces WHERE id = ?", &.{id}) catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = "{\"error\":\"Database query failed\"}" });
            };
            defer rows.deinit();

            const row = rows.next() catch {
                return res.jsonResponse(allocator, .{ .status_code = 500, .data = "{\"error\":\"Failed to fetch row\"" });
            };
            if (row) |r| {
                defer r.deinit(allocator);
                const ws_id = r.values[0];
                const name = r.values[1];
                const created_at = r.values[2];
                const updated_at = r.values[3];
                return res.jsonResponse(allocator, .{ .status_code = 200, .data = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"}}", .{ ws_id, name, created_at, updated_at }) });
            } else {
                return res.jsonResponse(allocator, .{ .status_code = 404, .data = "{\"error\":\"Workspace not found\"" });
            }
        }
    }
    return res.jsonResponse(allocator, .{ .status_code = 500, .data = "{\"error\":\"Server not initialized\"" });
}
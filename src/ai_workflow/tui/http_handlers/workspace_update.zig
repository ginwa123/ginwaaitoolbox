const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;

/// PUT /api/workspaces/:id
pub fn workspaceUpdateHandler(_: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const id = req.param("id") orelse "";
    if (id.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"id required\"}";
        return;
    }

    const body = req.body() orelse "";

    if (body.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"session_id required\"}";
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"Invalid JSON\"}";
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    const session_id_val = root.get("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"session_id required\"}";
        return;
    };
    if (session_id_val != .string) {
        res.status = 400;
        res.body = "{\"error\":\"session_id must be a string\"}";
        return;
    }

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            sqlite_db.exec(alloc, "UPDATE workspaces SET session_id = ? WHERE id = ?", &.{ session_id_val.string, id }) catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to update workspace\"}";
                return;
            };

            res.status = 200;
            res.body = try std.fmt.allocPrint(alloc, "{{\"success\":true,\"id\":\"{s}\",\"session_id\":\"{s}\"}}", .{ id, session_id_val.string });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
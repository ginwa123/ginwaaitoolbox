const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;

/// Generate a unique item ID
fn generateItemId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp_ns = ts.toNanoseconds();
    return std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
}

/// POST /api/workspaces/:workspace_id/items - Create a new workspace item
pub fn workspaceItemsCreateHandler(
    handler: *http_server.HttpServer.ServerHandler,
    req: *httpz.Request,
    res: *httpz.Response,
) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const workspace_id = req.param("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"workspace_id required\"}";
        return;
    }

    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = "{\"error\":\"item_type required\"}";
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"Invalid JSON\"}";
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const item_type_val = root.get("item_type") orelse {
        res.status = 400;
        res.body = "{\"error\":\"item_type required\"}";
        return;
    };
    if (item_type_val != .string) {
        res.status = 400;
        res.body = "{\"error\":\"item_type must be a string\"}";
        return;
    }

    const item_type = item_type_val.string;
    const item_id = try generateItemId(alloc, handler.io);

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            // Insert with timestamps
            sqlite_db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, created_at, updated_at) VALUES (?, ?, ?, datetime('now'), datetime('now'))", &.{ item_id, workspace_id, item_type }) catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to create workspace item\"}";
                return;
            };

            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"workspace_id\":\"{s}\",\"item_type\":\"{s}\"}}", .{
                item_id,
                workspace_id,
                item_type,
            });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
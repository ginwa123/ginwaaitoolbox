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
        res.body = "{\"error\":\"request body required\"}";
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status = 400;
        res.body = "{\"error\":\"Invalid JSON\"}";
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Extract name (required)
    const name_val = root.get("name") orelse {
        res.status = 400;
        res.body = "{\"error\":\"name required\"}";
        return;
    };
    if (name_val != .string) {
        res.status = 400;
        res.body = "{\"error\":\"name must be a string\"}";
        return;
    }
    const name = name_val.string;

    // Extract path (required)
    const path_val = root.get("path") orelse {
        res.status = 400;
        res.body = "{\"error\":\"path required\"}";
        return;
    };
    if (path_val != .string) {
        res.status = 400;
        res.body = "{\"error\":\"path must be a string\"}";
        return;
    }
    const path = path_val.string;

    // Extract item_type (optional, default to "folder")
    var item_type: []const u8 = "folder";
    if (root.get("item_type")) |type_val| {
        if (type_val == .string) {
            item_type = type_val.string;
        }
    }

    const item_id = try generateItemId(alloc, handler.io);

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            // Insert with timestamps and item_type, name, path columns
            sqlite_db.exec(alloc, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))", &.{ item_id, workspace_id, item_type, name, path }) catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to create workspace item\"}";
                return;
            };

            res.status = 201;
            // Return proper response with id, name, path so frontend can update
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"workspace_id\":\"{s}\",\"item_type\":\"{s}\",\"name\":\"{s}\",\"path\":\"{s}\"}}", .{
                item_id,
                workspace_id,
                item_type,
                name,
                path,
            });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
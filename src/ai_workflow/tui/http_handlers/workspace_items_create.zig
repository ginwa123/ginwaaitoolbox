const std = @import("std");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

/// Generate a unique item ID
fn generateItemId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const timestamp_ns = ts.toNanoseconds();
    return std.fmt.allocPrint(allocator, "item_{d}", .{timestamp_ns});
}

/// POST /api/workspaces/:workspace_id/items - Create a new workspace item
pub fn workspaceItemsCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.ai_mod.models.getSingleton();
    const sqlite_db = di.db;

    const workspace_id = req.params.get("workspace_id") orelse "";
    if (workspace_id.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"workspace_id required\"" });
    }

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"request body required\"" });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"Invalid JSON\"" });
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    // Extract name (required)
    const name_val = root.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"name required\"" });
    };
    if (name_val != .string) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"name must be a string\"" });
    }
    const name = name_val.string;

    // Extract path (required)
    const path_val = root.get("path") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"path required\"" });
    };
    if (path_val != .string) {
        return res.jsonResponse(.{ .status_code = 400, .data = "{\"error\":\"path must be a string\"" });
    }
    const path = path_val.string;

    // Extract item_type (optional, default to "folder")
    var item_type: []const u8 = "folder";
    if (root.get("item_type")) |type_val| {
        if (type_val == .string) {
            item_type = type_val.string;
        }
    }

    const item_id = try generateItemId(allocator, ctx.io);

    // Insert with timestamps and item_type, name, path columns
    sqlite_db.exec(allocator, "INSERT INTO workspace_items (id, workspace_id, item_type, name, path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, datetime('now'), datetime('now'))", &.{ item_id, workspace_id, item_type, name, path }) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = "{\"error\":\"Failed to create workspace item\"" });
    };

    return res.jsonResponse(.{ .status_code = 201, .data = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\",\"workspace_id\":\"{s}\",\"item_type\":\"{s}\",\"name\":\"{s}\",\"path\":\"{s}\"}}", .{
        item_id,
        workspace_id,
        item_type,
        name,
        path,
    }) });
}


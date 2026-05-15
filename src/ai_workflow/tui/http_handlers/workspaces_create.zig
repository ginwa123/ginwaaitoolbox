const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const process = nalarcore.helpers.process;
const getCurrentProcessId = process.getCurrentProcessId;
const ai_mod = nalarcore.ai_mod;
const sqlite = nalarcore.sqlite;

/// POST /api/workspaces
pub fn workspacesCreateHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.ai_mod.models.getSingleton();
    const sqlite_db = di.db;

    const body = req.body;
    if (body.len == 0) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name required" }) });
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Invalid JSON" }) });
    };

    const root = parsed.value.object;
    const name = root.get("name") orelse {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name required" }) });
    };
    if (name != .string) {
        return res.jsonResponse(.{ .status_code = 400, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "name must be a string" }) });
    }

    // Generate workspace ID
    const ts = std.Io.Timestamp.now(ctx.io, .real);
    const ts_nanos: i64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
    const pid = getCurrentProcessId();
    const entropy: u64 = (@as(u64, @intCast(pid)) << 32) ^ @as(u64, @intCast(ts_nanos));
    var random_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &random_bytes, entropy, .little);
    var hex_buf: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_buf[i * 2] = process.hex_digits[b >> 4];
        hex_buf[i * 2 + 1] = process.hex_digits[b & 0xF];
    }
    const workspace_id = try std.fmt.allocPrint(allocator, "ws_{d}_{s}", .{ ts_nanos, &hex_buf });

    createWorkspace(allocator, sqlite_db, workspace_id, name.string) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Failed to create workspace" }) });
    };

    return res.jsonResponse(.{ .status_code = 201, .data = try http_response.makeWorkspaceResponse(allocator, .{
        .id = workspace_id,
        .name = name.string,
        .created_at = null,
        .updated_at = null,
    }) });
}

fn createWorkspace(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, workspace_id: []const u8, name: []const u8) !void {
    _ = try db.exec(allocator, "INSERT INTO workspaces (id, name, created_at, updated_at) VALUES (?, ?, datetime('now'), datetime('now'))", &.{ workspace_id, name });
}


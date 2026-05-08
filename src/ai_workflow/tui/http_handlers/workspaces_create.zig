const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;
const http_response = nalarcore.http_response;

const httpz = http_server.httpz;
const process = nalarcore.helpers.process;

/// Cross-platform process ID getter (using helper)
const getCurrentProcessId = process.getCurrentProcessId;

/// POST /api/workspaces
pub fn workspacesCreateHandler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const body = req.body() orelse "";
    if (body.len == 0) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "name required" });
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Invalid JSON" });
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const name = root.get("name") orelse {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "name required" });
        return;
    };
    if (name != .string) {
        res.status = 400;
        res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "name must be a string" });
        return;
    }

    // Generate workspace ID
    const ts = std.Io.Timestamp.now(self.io, .real);
    const ts_nanos: i64 = @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
    const pid = getCurrentProcessId();
    const entropy: u64 = @intFromPtr(self) ^ (@as(u64, @intCast(pid)) << 32) ^ @as(u64, @intCast(ts_nanos));
    var random_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &random_bytes, entropy, .little);
    var hex_buf: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_buf[i * 2] = process.hex_digits[b >> 4];
        hex_buf[i * 2 + 1] = process.hex_digits[b & 0xF];
    }
    const workspace_id = try std.fmt.allocPrint(alloc, "ws_{d}_{s}", .{ ts_nanos, hex_buf });

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            sqlite_db.exec(alloc, "INSERT INTO workspaces (id, name) VALUES (?, ?)", &.{ workspace_id, name.string }) catch {
                res.status = 500;
                res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Failed to create workspace" });
                return;
            };

            res.status = 201;
            res.body = try http_response.makeWorkspaceResponse(alloc, .{ .id = workspace_id, .name = name.string });
            return;
        }
    }
    res.status = 500;
    res.body = try http_response.makeErrorResponse(alloc, .{ .@"error" = "Server not initialized" });
}
const std = @import("std");
const root_mod = @import("nalarcore");
const http_server = root_mod.http_server;
const nalarcore = root_mod;
const ai_workflow = nalarcore.ai_workflow;

const httpz = http_server.httpz;

/// Cross-platform process ID getter
fn getCurrentProcessId() std.c.pid_t {
    if (@hasDecl(std.c, "getpid")) {
        return std.c.getpid();
    } else if (@hasDecl(std.os.windows, "GetCurrentProcessId")) {
        return @intCast(std.os.windows.GetCurrentProcessId());
    }
    @compileError("getpid not available on this platform");
}

/// POST /api/workspaces
pub fn workspacesCreateHandler(self: *http_server.HttpServer.ServerHandler, req: *httpz.Request, res: *httpz.Response) anyerror!void {
    const alloc = req.arena;
    res.content_type = .JSON;

    const body = req.body() orelse "";

    // Parse JSON body for session_id
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

    const session_id = root.get("session_id") orelse {
        res.status = 400;
        res.body = "{\"error\":\"session_id required\"}";
        return;
    };
    if (session_id != .string) {
        res.status = 400;
        res.body = "{\"error\":\"session_id must be a string\"}";
        return;
    }

    // Generate workspace ID
    const ts = std.Io.Clock.now(.real, self.io);
    const ts_sec: i64 = ts.toSeconds();
    const pid = getCurrentProcessId();
    const entropy: u64 = @intFromPtr(self) ^ (@as(u64, @intCast(pid)) << 32) ^ @as(u64, @intCast(ts_sec));
    var random_bytes: [8]u8 = undefined;
    @as(*u64, @ptrCast(@alignCast(&random_bytes))).* = entropy;
    var hex_buf: [16]u8 = undefined;
    for (random_bytes, 0..) |b, i| {
        hex_buf[i * 2] = "0123456789abcdef"[b >> 4];
        hex_buf[i * 2 + 1] = "0123456789abcdef"[b & 0xF];
    }
    const workspace_id = try std.fmt.allocPrint(alloc, "ws_{d}_{s}", .{ ts_sec, hex_buf });

    if (http_server.global_server) |server| {
        if (server.ctx) |ctx| {
            const ctxTui = @as(*ai_workflow.ContextIPCTui, @ptrCast(@alignCast(ctx)));
            const sqlite_db = ctxTui.db;

            // Insert into workspaces table
            sqlite_db.exec(alloc, "INSERT INTO workspaces (id, session_id) VALUES (?, ?)", &.{ workspace_id, session_id.string }) catch {
                res.status = 500;
                res.body = "{\"error\":\"Failed to create workspace\"}";
                return;
            };

            res.status = 201;
            res.body = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\",\"session_id\":\"{s}\"}}", .{ workspace_id, session_id.string });
            return;
        }
    }
    res.status = 500;
    res.body = "{\"error\":\"Server not initialized\"}";
}
//! `DELETE /api/terminal/sessions/:id` — kill the shell, close the
//! PTY, drop the session. Success: 200 `{ ok: true }`. Unknown id:
//! 404. Idempotent in effect (a second delete is a 404, not an error
//! to retry — the session is already gone).

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const terminal_session = @import("terminal_session.zig");

pub const TerminalDeleteResponse = struct {
    ok: bool,
};

pub fn terminalDeleteHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const id = req.params.get("id") orelse {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing id" }),
        });
    };
    if (id.len == 0) {
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Missing id" }),
        });
    }

    terminal_session.destroySession(id) catch |err| {
        const status: u16 = switch (err) {
            error.SessionNotFound => 404,
            error.UnsupportedPlatform => 501,
            else => 500,
        };
        const message: []const u8 = switch (err) {
            error.SessionNotFound => "terminal session not found",
            error.UnsupportedPlatform => "terminal sessions require Linux or macOS",
            else => "failed to delete terminal session",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalDeleteResponse{ .ok = true }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

const testing = std.testing;

test "delete response serializes ok:true" {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, TerminalDeleteResponse{ .ok = true }, .{});
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "true") != null);
}

//! `GET /api/terminal/sessions/:id/output?cursor=N` — poll PTY output.
//!
//! Drains newly arrived bytes, then returns everything since the
//! absolute `cursor` (missing/garbage cursor replays from the oldest
//! retained byte). Success: 200
//! `{ data, cursor, exited, exit_code }` where `cursor` is the new
//! absolute offset to pass back, `exited` reports child termination,
//! and `exit_code` is null while running. Unknown id: 404.
//!
//! `data` strips NUL bytes (JSON safety, same convention as the
//! background-process log tail).

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const terminal_session = @import("terminal_session.zig");

pub const TerminalOutputResponse = struct {
    data: []const u8,
    cursor: u64,
    exited: bool,
    exit_code: ?i32,
};

pub fn terminalOutputHandler(
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

    const session = terminal_session.getSession(id) orelse {
        return res.jsonResponse(.{
            .status_code = 404,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "terminal session not found" }),
        });
    };

    const cursor = terminal_session.parseCursor(req.query.get("cursor"));
    // Owned copy under the session lock: no borrow into the live ring
    // buffer survives the unlock, so a concurrent drain realloc can
    // never free memory we still read (heap UAF -> remap abort).
    const owned = terminal_session.readOutputAlloc(allocator, session, cursor) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };
    defer allocator.free(owned.data);

    // Strip NUL bytes for JSON safety.
    const clean = stripNul(allocator, owned.data) catch {
        return res.jsonResponse(.{
            .status_code = 500,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Out of memory" }),
        });
    };

    const json_str = try std.json.Stringify.valueAlloc(allocator, TerminalOutputResponse{
        .data = clean,
        .cursor = owned.cursor,
        .exited = owned.exited,
        .exit_code = owned.exit_code,
    }, .{});
    return res.jsonResponse(.{ .status_code = 200, .data = json_str });
}

/// Copy `raw` minus NUL bytes into an owned slice.
pub fn stripNul(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var kept: usize = 0;
    for (raw) |b| {
        if (b != 0) kept += 1;
    }
    const out = try allocator.alloc(u8, kept);
    var i: usize = 0;
    for (raw) |b| {
        if (b == 0) continue;
        out[i] = b;
        i += 1;
    }
    return out;
}

const testing = std.testing;

test "stripNul removes NUL bytes and keeps the rest" {
    const out = try stripNul(testing.allocator, "a\x00b\x00c");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abc", out);
}

test "stripNul passes clean input through" {
    const out = try stripNul(testing.allocator, "hello");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

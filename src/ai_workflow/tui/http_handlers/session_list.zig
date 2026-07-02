//! `GET /api/sessions` — list sessions with cursor pagination.
//!
//! Optional query params: `limit` (default 50), `cursor` (pagination),
//! `cwd` (filter by working directory), `sort_by` (`created_at` or
//! `updated_at`), `direction` (`asc` or `desc`).
//!
//! Layered as `useCase` (resolve singleton + parse query + DB call +
//! build JSON) and a thin handler that maps errors to status codes.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const llm_history = nalarcore.llm_history;

pub const SessionListError = error{
    QueryFailed,
    /// `buildSessionListJson` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`). Effectively unreachable on the per-request
    /// arena, but the type system requires the variant.
    OutOfMemory,
};

pub const SessionListInput = struct {
    limit: u32,
    cursor: ?[]const u8,
    cwd: ?[]const u8,
    sort_field: llm_history.SessionSortField,
    sort_direction: llm_history.SessionSortDirection,
};

pub const SessionListResult = []const u8; // pre-serialized JSON

// =====================================================================
// Use case
// =====================================================================

/// Parse query params into the typed input.
fn parseInput(query: anytype) !SessionListInput {
    const limit_str = query.get("limit") orelse "50";
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    const sort_by_str = query.get("sort_by") orelse "created_at";
    const sort_field = llm_history.enumFromString(llm_history.SessionSortField, sort_by_str) catch .created_at;

    const direction_str = query.get("direction") orelse "desc";
    const sort_direction = llm_history.enumFromString(llm_history.SessionSortDirection, direction_str) catch .desc;

    return .{
        .limit = limit,
        .cursor = query.get("cursor"),
        .cwd = query.get("cwd"),
        .sort_field = sort_field,
        .sort_direction = sort_direction,
    };
}

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: SessionListInput,
) SessionListError!SessionListResult {
    const result = llm_history.getSessionListWithCursor(
        allocator,
        db,
        null,
        null,
        input.cwd,
        input.limit,
        input.cursor,
        input.sort_field,
        input.sort_direction,
    ) catch return error.QueryFailed;
    defer {
        for (result.sessions) |s| s.deinit(allocator);
        allocator.free(result.sessions);
    }

    // has_more is true iff we got the full page back.
    const has_more = result.sessions.len == @as(usize, input.limit);

    // The cursor value is the last item's sort-field value
    // (created_at or updated_at depending on sort_field).
    const cursor_value: ?[]const u8 = if (result.sessions.len > 0)
        switch (input.sort_field) {
            .updated_at => result.sessions[result.sessions.len - 1].updated_at,
            else => result.sessions[result.sessions.len - 1].created_at,
        }
    else
        null;

    return try llm_history.buildSessionListJson(
        allocator,
        result.sessions,
        result.total,
        has_more,
        cursor_value,
    );
}

// =====================================================================
// Handler
// =====================================================================

pub fn sessionListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const input = parseInput(req.query) catch |err| {
        // Today `parseInput` never returns an error (parseInt with
        // catch defaults; enumFromString with catch defaults). Kept
        // for forward compatibility — if a future field gains a
        // strict parse, surface it as 400.
        return res.jsonResponse(.{
            .status_code = 400,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = @errorName(err) }),
        });
    };

    const response = useCase(allocator, sqlite_db, input) catch |err| {
        const status: u16 = switch (err) {
            error.QueryFailed => 500,
            error.OutOfMemory => 500,
        };
        const message: []const u8 = switch (err) {
            error.QueryFailed => "Database query failed",
            error.OutOfMemory => "Out of memory",
        };
        return res.jsonResponse(.{
            .status_code = status,
            .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = message }),
        });
    };

    return res.jsonResponse(.{ .status_code = 200, .data = response });
}
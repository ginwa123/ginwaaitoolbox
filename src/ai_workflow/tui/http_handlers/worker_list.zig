//! `GET /api/workers` — list all workers.
//!
//! Query params:
//!   - `limit`: max workers to return (default 50)
//!   - `session_id`: filter by session_id (optional)
//!
//! Layered as `useCase` (resolve singleton + build query + walk rows +
//! build response) and a thin handler that maps errors to status codes.

const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;

pub const WorkerListError = error{
    QueryFailed,
    /// `makeWorkerListResponse` returns `![]u8` (its body uses
    /// `std.json.Stringify.valueAlloc` which can fail with
    /// `OutOfMemory`). On the per-request arena this is
    /// effectively unreachable, but the type system requires the
    /// variant so `try makeWorkerListResponse` propagates a typed
    /// error.
    OutOfMemory,
};

pub const WorkerListInput = struct {
    limit: u32,
    session_id_filter: ?[]const u8,
};

pub const WorkerListResult = struct {
    json: []const u8,
    count: u32,
};

// =====================================================================
// Use case
// =====================================================================

fn useCase(
    allocator: std.mem.Allocator,
    db: *nalarcore.sqlite.SqliteBackend,
    input: WorkerListInput,
) WorkerListError!WorkerListResult {
    // Build query with optional session_id filter. SQL convention:
    // alias the table (`w`) so the column references stay
    // unambiguous when filters grow (see project memory
    // nalar-sql-alias-tables.md).
    const base_sql = "SELECT w.id, w.session_id, w.working_directory, w.last_activity, w.last_activity_description, w.created_at FROM worker w";
    const query_sql = if (input.session_id_filter != null)
        try std.fmt.allocPrint(allocator, "{s} WHERE w.session_id = ? ORDER BY w.last_activity DESC", .{base_sql})
    else
        try std.fmt.allocPrint(allocator, "{s} ORDER BY w.last_activity DESC", .{base_sql});

    const query_params: []const []const u8 = if (input.session_id_filter) |sid|
        &[_][]const u8{sid}
    else
        &[_][]const u8{};

    var rows = db.query(allocator, query_sql, query_params) catch return error.QueryFailed;

    var workers = std.ArrayList(http_response.WorkerInfo).empty;
    while (true) {
        const row_opt = rows.next() catch break;
        const row = row_opt orelse break;

        try workers.append(allocator, .{
            .id = row.values[0],
            .session_id = row.values[1],
            .working_directory = row.values[2],
            .last_activity = row.values[3],
            .last_activity_description = row.values[4],
            .created_at = row.values[5],
            .status = "running",
            .is_running = true,
            .queue_count = 0,
        });

        if (workers.items.len >= input.limit) break;
    }

    const count: u32 = @intCast(workers.items.len);
    const json = try http_response.makeWorkerListResponse(allocator, workers.items, count);
    return .{ .json = json, .count = count };
}

// =====================================================================
// Handler
// =====================================================================

pub fn workerListHandler(
    ctx: gserverz.HttpContext,
    req: gserverz.HttpRequest,
    res: gserverz.HttpResponse,
) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const limit_str = req.query.get("limit") orelse "50";
    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    const input = WorkerListInput{
        .limit = limit,
        .session_id_filter = req.query.get("session_id"),
    };

    const outcome = useCase(allocator, sqlite_db, input) catch |err| {
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

    _ = outcome.count;
    return res.jsonResponse(.{ .status_code = 200, .data = outcome.json });
}
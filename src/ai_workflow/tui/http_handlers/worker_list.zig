const std = @import("std");
const http_response = @import("http_response.zig");
const nalarcore = @import("nalarcore");
const gserverz = nalarcore.gserverz;
const ai_mod = nalarcore.ai_mod;

/// List all workers
/// Query params:
///   - limit: max number of workers to return (u32, default: 50)
///   - status: filter by status (running, idle, stopped, all - default: all)
///   - session_id: filter by session_id (optional, for checking if session is processing)
/// Returns JSON array of worker info from both database and registry
pub fn workerListHandler(ctx: gserverz.HttpContext, req: gserverz.HttpRequest, res: gserverz.HttpResponse) !gserverz.HttpResponse {
    const allocator = ctx.allocator;

    const di = try nalarcore.getSingleton();
    const sqlite_db = di.db;

    const limit_str = req.query.get("limit") orelse "50";
    const session_id_filter = req.query.get("session_id");

    const limit = std.fmt.parseInt(u32, limit_str, 10) catch 50;

    // Build query with optional session_id filter
    const base_sql = "SELECT id, session_id, working_directory, last_activity, last_activity_description, created_at FROM worker";
    const query_sql: []const u8 = if (session_id_filter != null)
        try std.fmt.allocPrint(allocator, "{s} WHERE session_id = ? ORDER BY last_activity DESC", .{base_sql})
    else
        try std.fmt.allocPrint(allocator, "{s} ORDER BY last_activity DESC", .{base_sql});

    const query_params: []const []const u8 = if (session_id_filter) |sid|
        &[_][]const u8{sid}
    else
        &[_][]const u8{};

    // Query worker table from database
    var rows = sqlite_db.query(allocator, query_sql, query_params) catch {
        return res.jsonResponse(.{ .status_code = 500, .data = try http_response.makeErrorResponse(allocator, .{ .@"error" = "Database query failed" }) });
    };

    // Collect workers into array list
    var workers = std.ArrayList(http_response.WorkerInfo).empty;

    while (true) {
        const row_opt = rows.next() catch break;
        const row = row_opt orelse break;

        const db_id = row.values[0];
        const session_id = row.values[1];
        const working_directory = row.values[2];
        const last_activity = row.values[3];
        const last_activity_description = row.values[4];
        const created_at = row.values[5];

        const status = "running";
        const is_running = true;
        const queue_count: u32 = 0;

        try workers.append(allocator, .{
            .id = db_id,
            .session_id = session_id,
            .working_directory = working_directory,
            .last_activity = last_activity,
            .last_activity_description = last_activity_description,
            .created_at = created_at,
            .status = status,
            .is_running = is_running,
            .queue_count = queue_count,
        });

        // Check limit
        if (workers.items.len >= limit) break;
    }

    const count: u32 = @intCast(workers.items.len);
    return res.jsonResponse(.{ .status_code = 200, .data = try http_response.makeWorkerListResponse(allocator, workers.items, count) });
}


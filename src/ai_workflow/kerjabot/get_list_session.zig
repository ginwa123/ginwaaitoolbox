const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

/// Sort field options for session list
pub const SortField = enum {
    created_at,
    session_id,
    session_name,
    agent,
};

/// Sort order options
pub const SortOrder = enum {
    asc,
    desc,
};

/// Cursor for pagination (base64 encoded created_at timestamp)
pub const CursorData = struct {
    created_at: []const u8,
};

/// Get a list of sessions from the database with cursor pagination and sorting
pub fn getSessionList(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    limit: u32,
    cursor: ?[]const u8,
    sort_field: SortField,
    sort_order: SortOrder,
) !struct { sessions: []SessionInfo, total: u32, next_cursor: ?[]const u8, has_more: bool } {
    _ = sort_field; // Reserved for future: support sorting by other fields with offset pagination

    // Sort direction
    const sort_dir: []const u8 = if (sort_order == .asc) "ASC" else "DESC";

    // For cursor-based pagination, we use created_at as the cursor
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit + 1}); // Fetch one extra to check has_more
    defer allocator.free(limit_str);

    var sql: []const u8 = undefined;
    var args: []const []const u8 = undefined;

    if (cursor) |cur| {
        // Cursor-based pagination
        const having_cond = if (sort_order == .asc) ">= ?" else "<= ?";
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at,
            \\COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history
            \\GROUP BY session_id HAVING MAX(created_at) {s} ORDER BY MAX(created_at) {s} LIMIT ?
        , .{ having_cond, sort_dir });
        args = &.{ cur, limit_str };
    } else {
        // No cursor - first page
        sql = try std.fmt.allocPrint(allocator,
            \\SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at,
            \\COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history
            \\GROUP BY session_id ORDER BY MAX(created_at) {s} LIMIT ?
        , .{sort_dir});
        args = &.{limit_str};
    }
    defer allocator.free(sql);

    var rows = try db.query(allocator, sql, args);
    defer rows.deinit();

    // Build sessions array
    var session_array: [100]SessionInfo = undefined;
    var count: usize = 0;
    var last_created_at: ?[]const u8 = null;

    while (try rows.next()) |row| {
        if (count >= limit) break; // Stop at limit (we fetched limit+1 above)
        session_array[count] = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
        };
        last_created_at = session_array[count].created_at;
        count += 1;
        row.deinit(allocator);
    }

    // Copy to slice
    var sessions = try allocator.alloc(SessionInfo, count);
    for (0..count) |i| {
        sessions[i] = session_array[i];
    }

    // Determine if there are more results
    const has_more = count >= limit;
    const next_cursor = if (has_more and last_created_at != null)
        try allocator.dupe(u8, last_created_at.?)
    else
        null;

    // Get total count
    const count_sql = "SELECT COUNT(DISTINCT session_id) FROM llm_history";
    var count_rows = try db.query(allocator, count_sql, &.{});
    defer count_rows.deinit();

    var total: u32 = 0;
    if (try count_rows.next()) |row| {
        total = std.fmt.parseInt(u32, row.values[0], 10) catch 0;
        row.deinit(allocator);
    }

    return .{
        .sessions = sessions,
        .total = total,
        .next_cursor = next_cursor,
        .has_more = has_more,
    };
}

/// Session info for list view
pub const SessionInfo = struct {
    session_id: []const u8,
    session_dir: []const u8,
    created_at: []const u8,
    agent: []const u8,
    session_name: []const u8,

    pub fn deinit(self: *const SessionInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.session_dir);
        alloc.free(self.created_at);
        alloc.free(self.agent);
        alloc.free(self.session_name);
    }
};

const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

/// Get a list of sessions from the database
pub fn getSessionList(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    limit: u32,
    offset: u32,
) !struct { sessions: []SessionInfo, total: u32 } {
    // Query sessions from database
    const sql = "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, '') FROM llm_history GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT ? OFFSET ?";
    
    const limit_str = try std.fmt.allocPrint(allocator, "{d}", .{limit});
    const offset_str = try std.fmt.allocPrint(allocator, "{d}", .{offset});
    defer {
        allocator.free(limit_str);
        allocator.free(offset_str);
    }
    
    var rows = try db.query(allocator, sql, &.{ limit_str, offset_str });
    defer rows.deinit();

    // Build array manually
    var session_array: [100]SessionInfo = undefined;
    var count: usize = 0;

    while (try rows.next()) |row| {
        if (count >= 100) break;
        session_array[count] = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
        };
        count += 1;
        row.deinit(allocator);
    }
    
    // Copy to slice
    var sessions = try allocator.alloc(SessionInfo, count);
    for (0..count) |i| {
        sessions[i] = session_array[i];
    }

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

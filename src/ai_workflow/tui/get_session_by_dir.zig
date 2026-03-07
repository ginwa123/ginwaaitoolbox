const std = @import("std");
const tree1 = @import("nalarcore");
const sqlite = tree1.sqlite;
const SessionInfo = @import("tui_workflow.zig").SessionInfo;

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_dir: []const u8,
) ![]SessionInfo {
    var results: std.ArrayList(SessionInfo) = .empty;

    const sql = "SELECT session_id, COALESCE(session_dir, '') as session_dir, MAX(created_at) as created_at FROM llm_history WHERE session_dir = ?  GROUP BY session_id ORDER BY created_at DESC LIMIT 10";
    var rows = try db.query(allocator, sql, .{&.{session_dir}});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
        };
        try results.append(allocator, session);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

test {
    _ = @import("get_session_by_dir_test.zig");
}

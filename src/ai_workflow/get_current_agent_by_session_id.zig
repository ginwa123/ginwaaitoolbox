const std = @import("std");
const tree1_mod = @import("tree1");
const sqlite = tree1_mod.sqlite;

pub fn run(allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8) ![]const u8 {
    const sql = "SELECT COALESCE(agent, 'GeneralAgent'), COALESCE(session_name, ''), COALESCE(loop_index, 0) FROM llm_history WHERE session_id = ? ORDER BY created DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        return try allocator.dupe(u8, row.values[0]);
    } else {
        return try allocator.dupe(u8, "GeneralAgent");
    }
}

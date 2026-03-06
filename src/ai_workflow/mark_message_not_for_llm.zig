const std = @import("std");
const tree1 = @import("tree1");
const sqlite = tree1.sqlite;

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "UPDATE llm_history SET is_feed_to_llm = 0 WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

const std = @import("std");
const tree1 = @import("nalarcore");
const sqlite = tree1.sqlite;

pub fn mark_message_not_for_llm_run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "UPDATE llm_history SET is_feed_to_llm = 0 WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}


const std = @import("std");
const nalarcore = @import("nalarcore");

const sqlite = nalarcore.sqlite;

pub fn markHistoryNotForLLMRun(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !void {
    const sql = "UPDATE llm_history SET is_feed_to_llm = 0 WHERE session_id = ?";
    try db.exec(allocator, sql, &.{session_id});
}

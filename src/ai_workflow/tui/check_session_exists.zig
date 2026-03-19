const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

/// Check if a session exists in the database
/// Returns true if session exists, false otherwise or on error
pub fn checkSessionExists(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT COUNT(*) as cnt FROM llm_history WHERE session_id = ?";
    
    const result = db.queryRow(allocator, sql, &.{session_id}) catch return false;
    defer result.deinit(allocator);
    
    if (result.values.len > 0) {
        const count_str = std.mem.sliceTo(result.values[0], 0);
        if (std.fmt.parseInt(i32, count_str, 10)) |count| {
            return count > 0;
        } else |_| {}
    }
    
    return false;
}

test {
    _ = @import("check_session_exists_test.zig");
}

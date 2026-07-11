const std = @import("std");
const mod = @import("mod.zig");
const sqlite = mod.nalarcore.sqlite;

/// Check if a session is currently running (exists in worker table)
pub fn isWorkerRunning(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM worker WHERE id = ? LIMIT 1";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();
    return (rows.next() catch return false) != null;
}

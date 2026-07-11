const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;

pub fn hasQueuedMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) bool {
    const sql = "SELECT 1 FROM session_queue_messages WHERE session_id = ? LIMIT 1";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();

    if (rows.next() catch return false) |row| {
        const queued = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
        return queued == 1;
    }

    return false;
}

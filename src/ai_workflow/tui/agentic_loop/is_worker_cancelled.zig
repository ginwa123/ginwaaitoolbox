const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const helpers = nalarcore.helpers;

pub const IsWorkerCancelledInput = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
};

pub fn isWorkerCancelled(
    obj: IsWorkerCancelledInput,
) bool {
    const allocator = obj.allocator;
    const db = obj.db;
    const session_id = obj.session_id;

    const sql = "SELECT cancelled FROM worker WHERE id = ?";
    var rows = db.query(allocator, sql, &.{session_id}) catch return false;
    defer rows.deinit();
    if (rows.next() catch return false) |row| {
        const cancelled = std.fmt.parseInt(i32, row.values[0], 10) catch 0;
        return cancelled == 1;
    }
    return false;
}

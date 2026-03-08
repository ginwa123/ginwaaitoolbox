const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;
const logger_mod = tree1_mod.logger;

/// Check if a skill is already loaded in the database
pub fn isLoaded(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    skill_name: []const u8,
) !bool {
    if (session_id.len == 0) return false;

    const sql = "SELECT 1 FROM session_skills WHERE session_id = ? AND skill_name = ? LIMIT 1";
    var rows = try db.query(allocator, sql, &.{ session_id, skill_name });
    defer rows.deinit();

    if (try rows.next()) |row| {
        row.deinit(allocator);
        return true;
    }
    return false;
}

/// Save a loaded skill to the database for persistence
pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    skill_name: []const u8,
    content: []const u8,
) !void {
    // Skip if session_id is empty
    if (session_id.len == 0) return;

    const sql = "INSERT OR REPLACE INTO session_skills (session_id, skill_name, content, loaded_at) VALUES (?, ?, ?, strftime('%s', 'now'))";
    try db.exec(allocator, sql, &.{ session_id, skill_name, content });
    logger.debugFmt("Skill '{s}' saved to database for session {s}", .{ skill_name, session_id }) catch {};
}

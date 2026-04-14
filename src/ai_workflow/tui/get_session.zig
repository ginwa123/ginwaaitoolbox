const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

/// Get a single session by ID from the database
pub fn getSession(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?SessionDetail {
    const sql = "SELECT DISTINCT session_id, COALESCE(session_dir, ''), MAX(created_at) as created_at, COALESCE(agent, 'Agent'), COALESCE(session_name, ''), COALESCE(model, 'gpt-4'), COALESCE(temperature, 0.2) FROM llm_history WHERE session_id = ? GROUP BY session_id";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionDetail{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
            .agent = try allocator.dupe(u8, row.values[3]),
            .session_name = try allocator.dupe(u8, row.values[4]),
            .model = try allocator.dupe(u8, row.values[5]),
            .temperature = std.fmt.parseFloat(f32, row.values[6]) catch 0.2,
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

/// Get the latest finish_reason for a session from the database
/// Returns the most recent finish_reason value (e.g., "stop", "tool_calls", "length", etc.)
/// Returns null if no history exists for the session
pub fn getLatestFinishReason(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?[]const u8 {
    // Query to get the most recent finish_reason for the session
    const sql = "SELECT finish_reason FROM llm_history WHERE session_id = ? AND finish_reason IS NOT NULL AND finish_reason != '' ORDER BY created_at DESC LIMIT 1";

    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const finish_reason = try allocator.dupe(u8, row.values[0]);
        row.deinit(allocator);
        return finish_reason;
    }

    return null;
}

/// Session detail info
pub const SessionDetail = struct {
    session_id: []const u8,
    session_dir: []const u8,
    created_at: []const u8,
    agent: []const u8,
    session_name: []const u8,
    model: []const u8,
    temperature: f32,

    pub fn deinit(self: *const SessionDetail, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.session_dir);
        alloc.free(self.created_at);
        alloc.free(self.agent);
        alloc.free(self.session_name);
        alloc.free(self.model);
    }
};

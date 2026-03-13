const std = @import("std");
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

pub const AgentState = struct {
    agent: []const u8,
    temperature: f32,
    is_thinking: bool,
};

pub fn run(allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8) !AgentState {
    std.debug.print("get_current_agent_by_session_id: looking for session_id='{s}'\n", .{session_id});
    const sql = "SELECT COALESCE(agent, 'Agent'), COALESCE(temperature, 0.2), COALESCE(is_thinking, 0) FROM llm_history WHERE session_id = ? ORDER BY created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        std.debug.print("get_current_agent_by_session_id: found row agent='{s}' temp='{s}' thinking='{s}'\n", .{ row.values[0], row.values[1], row.values[2] });
        const agent_name = try allocator.dupe(u8, row.values[0]);
        const temperature = try std.fmt.parseFloat(f32, row.values[1]);
        const is_thinking = std.mem.eql(u8, row.values[2], "1");
        return AgentState{
            .agent = agent_name,
            .temperature = temperature,
            .is_thinking = is_thinking,
        };
    } else {
        std.debug.print("get_current_agent_by_session_id: NO ROWS FOUND for session_id='{s}', returning defaults\n", .{session_id});
        return AgentState{
            .agent = try allocator.dupe(u8, "Agent"),
            .temperature = 0.2,
            .is_thinking = false,
        };
    }
}

test {
    _ = @import("get_current_agent_by_session_id_test.zig");
}

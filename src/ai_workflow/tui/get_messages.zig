const std = @import("std");
const tui_workflow = @import("tui_workflow.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

pub fn GetMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]TUIHistory {
    var results: std.ArrayList(TUIHistory) = .empty;

    const sql = "SELECT id, session_id, model, created_at, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, ''), COALESCE(reasoning_content, ''), COALESCE(agent, 'Agent'), COALESCE(session_name, ''), COALESCE(loop_index, 0), COALESCE(temperature, 0.2), COALESCE(is_thinking, 0) FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL) ORDER BY created_at ASC";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .agent = try allocator.dupe(u8, row.values[9]),
            .session_name = try allocator.dupe(u8, row.values[10]),
            .loop_index = std.fmt.parseInt(u32, row.values[11], 10) catch 0,
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

pub fn GetMessageLatest(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?TUIHistory {
    const sql = "SELECT id, session_id, model, created_at, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, ''), COALESCE(reasoning_content, ''), COALESCE(agent, 'Agent'), COALESCE(session_name, ''), COALESCE(loop_index, 0), COALESCE(temperature, 0.2), COALESCE(is_thinking, 0), COALESCE(tool_name, '') FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL) ORDER BY created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const history = TUIHistory{
            .id = try allocator.dupe(u8, row.values[0]),
            .session_id = try allocator.dupe(u8, row.values[1]),
            .model = try allocator.dupe(u8, row.values[2]),
            .created_at = try allocator.dupe(u8, row.values[3]),
            .response_content = try allocator.dupe(u8, row.values[4]),
            .finish_reason = try allocator.dupe(u8, row.values[5]),
            .role = try allocator.dupe(u8, row.values[6]),
            .tools = try allocator.dupe(u8, row.values[7]),
            .reasoning_content = if (row.values[8].len > 0) try allocator.dupe(u8, row.values[8]) else null,
            .agent = try allocator.dupe(u8, row.values[9]),
            .session_name = try allocator.dupe(u8, row.values[10]),
            .loop_index = std.fmt.parseInt(u32, row.values[11], 10) catch 0,
            .tool_name = try allocator.dupe(u8, row.values[14]),
        };
        row.deinit(allocator);
        return history;
    }

    return null;
}

test {
    _ = @import("get_messages_test.zig");
}

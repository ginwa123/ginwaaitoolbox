const std = @import("std");
const tui_workflow = @import("workflow.zig");
const TUIHistory = @import("models.zig").TUIHistory;
const SessionInfo = tui_workflow.SessionInfo;
const tree1_mod = @import("nalarcore");
const sqlite = tree1_mod.sqlite;

// ============================================================================
// Get Messages Functions
// ============================================================================

pub fn get_messages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) ![]TUIHistory {
    var results: std.ArrayList(TUIHistory) = .empty;

    const sql = "SELECT id, session_id, model, created_at, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, ''), COALESCE(reasoning_content, ''), COALESCE(agent, 'Agent'), COALESCE(session_name, ''), COALESCE(loop_index, 0), COALESCE(tool_name, ''), COALESCE(parent_session_id, ''), COALESCE(temperature, 0.2), COALESCE(is_thinking, 0), COALESCE(prompt_tokens, 0), COALESCE(completion_tokens, 0), COALESCE(total_tokens, 0), COALESCE(is_input, 0), COALESCE(is_output, 0) FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL) ORDER BY created_at ASC";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const parent_session_id_str = row.values[14];
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
            .tool_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[15]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[16], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[17], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[19], 10) catch 0,
            .is_input = std.mem.eql(u8, row.values[20], "1"),
            .is_output = std.mem.eql(u8, row.values[21], "1"),
        };
        try results.append(allocator, history);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

pub fn get_message_latest(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !?TUIHistory {
    const sql = "SELECT id, session_id, model, created_at, response_content, finish_reason, COALESCE(role, 'assistant'), COALESCE(tool_calls_json, ''), COALESCE(reasoning_content, ''), COALESCE(agent, 'Agent'), COALESCE(session_name, ''), COALESCE(loop_index, 0), COALESCE(tool_name, ''), COALESCE(parent_session_id, ''), COALESCE(temperature, 0.2), COALESCE(is_thinking, 0), COALESCE(prompt_tokens, 0), COALESCE(completion_tokens, 0), COALESCE(total_tokens, 0), COALESCE(is_input, 0), COALESCE(is_output, 0) FROM llm_history WHERE session_id = ? AND (is_feed_to_llm = 1 OR is_feed_to_llm IS NULL) ORDER BY created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const parent_session_id_str = row.values[14];
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
            .tool_name = try allocator.dupe(u8, row.values[12]),
            .parent_session_id = if (parent_session_id_str.len > 0) try allocator.dupe(u8, parent_session_id_str) else null,
            .temperature = std.fmt.parseFloat(f32, row.values[15]) catch 0.2,
            .is_thinking = std.mem.eql(u8, row.values[16], "1"),
            .prompt_tokens = std.fmt.parseInt(u32, row.values[17], 10) catch 0,
            .completion_tokens = std.fmt.parseInt(u32, row.values[18], 10) catch 0,
            .total_tokens = std.fmt.parseInt(u32, row.values[19], 10) catch 0,
            .is_input = std.mem.eql(u8, row.values[20], "1"),
            .is_output = std.mem.eql(u8, row.values[21], "1"),
        };
        row.deinit(allocator);
        return history;
    }

    return null;
}

// ============================================================================
// Get Session By Directory Functions
// ============================================================================

pub fn get_sessions_by_dir(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_dir: []const u8,
) ![]SessionInfo {
    var results: std.ArrayList(SessionInfo) = .empty;

    const sql = "SELECT session_id, COALESCE(session_dir, '') as session_dir, MAX(created_at) as created_at FROM llm_history WHERE session_dir = ? GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT 10";
    var rows = try db.query(allocator, sql, &[_][]const u8{session_dir});
    defer rows.deinit();

    while (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
        };
        try results.append(allocator, session);
        row.deinit(allocator);
    }

    return results.toOwnedSlice(allocator);
}

/// Get the latest session for a given directory
/// Returns null if no sessions exist for that directory
pub fn getLatestSessionByDir(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_dir: []const u8,
) !?SessionInfo {
    const sql = "SELECT session_id, COALESCE(session_dir, '') as session_dir, MAX(created_at) as created_at FROM llm_history WHERE session_dir = ? GROUP BY session_id ORDER BY MAX(created_at) DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &[_][]const u8{session_dir});
    defer rows.deinit();

    if (try rows.next()) |row| {
        const session = SessionInfo{
            .session_id = try allocator.dupe(u8, row.values[0]),
            .session_dir = try allocator.dupe(u8, row.values[1]),
            .created_at = try allocator.dupe(u8, row.values[2]),
        };
        row.deinit(allocator);
        return session;
    }

    return null;
}

// ============================================================================
// Get Current Agent By Session ID Functions
// ============================================================================

pub const AgentState = struct {
    agent: []const u8,
    temperature: f32,
    is_thinking: bool,
};

pub fn get_current_agent_by_session_id(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
) !AgentState {
    const sql = "SELECT COALESCE(agent, 'Agent'), COALESCE(temperature, 0.5), COALESCE(is_thinking, 1) FROM llm_history WHERE session_id = ? ORDER BY created_at DESC LIMIT 1";
    var rows = try db.query(allocator, sql, &.{session_id});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(allocator);
        const agent_name = try allocator.dupe(u8, row.values[0]);
        const temperature = try std.fmt.parseFloat(f32, row.values[1]);
        const is_thinking = std.mem.eql(u8, row.values[2], "1");
        return AgentState{
            .agent = agent_name,
            .temperature = temperature,
            .is_thinking = is_thinking,
        };
    } else {
        return AgentState{
            .agent = try allocator.dupe(u8, "Agent"),
            .temperature = 0.5,
            .is_thinking = true,
        };
    }
}

// ============================================================================
// Tests
// ============================================================================

test {
    _ = @import("session_helpers_test.zig");
}

const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const sqlite = tree1_mod.sqlite;

/// Serialize tool_calls array to JSON string
pub fn serializeToolCalls(allocator: std.mem.Allocator, tool_calls: []agent.ToolCall) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return try aw.toOwnedSlice();
}

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    response_content: ?[]const u8,
    response_finish_reason: ?[]const u8,
    response_reasoning_content: ?[]const u8,
    role: ?[]const u8,
    finish_reason: ?[]const u8,
    tool_calls: ?[]agent.ToolCall,
    tool_call_id: ?[]const u8,
    agent_name: ?[]const u8,
    session_name: ?[]const u8,
    loop_index: u32,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.time.nanoTimestamp()});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.time.milliTimestamp()});
    defer allocator.free(created_at);

    var contentStr = content orelse "";
    const finishReasonStr = finish_reason orelse
        (response_finish_reason orelse "null");
    const roleStr = role orelse "assistant";
    const reasoningStr = response_reasoning_content orelse "";
    const agentStr = agent_name orelse "ExplorationAgent";

    if (response_content) |c| {
        contentStr = c;
    }

    std.debug.print("saveMessage aa role={s} content={s}", .{ roleStr, contentStr });

    // Determine tool_calls_json: prefer serialized tool_calls, fall back to tool_call_id, then empty string
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    } else if (tool_call_id) |tcid| {
        toolCallsJson = tcid;
    }
    defer if (toolCallsOwned) |tcj| allocator.free(tcj);

    const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)";

    const copy_session_id = try allocator.dupe(u8, session_id);
    defer allocator.free(copy_session_id);
    const copy_model = try allocator.dupe(u8, model);
    defer allocator.free(copy_model);
    const copy_content = try allocator.dupe(u8, contentStr);
    defer allocator.free(copy_content);
    const copy_finish_reason = try allocator.dupe(u8, finishReasonStr);
    defer allocator.free(copy_finish_reason);
    const copy_role = try allocator.dupe(u8, roleStr);
    defer allocator.free(copy_role);
    const copy_tool_calls = try allocator.dupe(u8, toolCallsJson);
    defer allocator.free(copy_tool_calls);
    const copy_reasoning = try allocator.dupe(u8, reasoningStr);
    defer allocator.free(copy_reasoning);
    const copy_cwd = try allocator.dupe(u8, cwd);
    defer allocator.free(copy_cwd);
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
    const copy_session_name = try allocator.dupe(u8, session_name orelse "");
    defer allocator.free(copy_session_name);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{loop_index});
    defer allocator.free(loop_index_str);
    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_reasoning, copy_cwd, copy_agent, copy_session_name, loop_index_str, created_at };

    try db.exec(allocator, sql, sqlArgs);
}

test {
    _ = @import("save_message_test.zig");
}

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

pub const SaveMessageInput = struct {
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
    tool_name: ?[]const u8 = null,
    agent_name: ?[]const u8,
    session_name: ?[]const u8,
    loop_index: u32,
    temperature: f32,
    is_thinking: bool,
    is_input: bool = false,
    is_output: bool = false,
    parent_session_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    prompt_tokens: usize = 0,
    completion_tokens: usize = 0,
    total_tokens: usize = 0,
};

pub fn SaveMessage(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: SaveMessageInput,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.time.nanoTimestamp()});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.time.milliTimestamp()});
    defer allocator.free(created_at);

    var contentStr = input.content orelse "";
    const finishReasonStr = input.finish_reason orelse
        (input.response_finish_reason orelse "null");
    const roleStr = input.role orelse "assistant";
    const reasoningStr = input.response_reasoning_content orelse "";
    const agentStr = input.agent_name orelse "Agent";

    if (input.response_content) |c| {
        contentStr = c;
    }


    // Determine tool_calls_json: prefer serialized tool_calls, fall back to tool_call_id, then empty string
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (input.tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    } else if (input.tool_call_id) |tcid| {
        toolCallsJson = tcid;
    }
    defer if (toolCallsOwned) |tcj| allocator.free(tcj);

    const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, temperature, is_thinking, created_at, parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

    const copy_session_id = try allocator.dupe(u8, input.session_id);
    defer allocator.free(copy_session_id);
    const copy_model = try allocator.dupe(u8, input.model);
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
    const copy_cwd = try allocator.dupe(u8, input.cwd);
    defer allocator.free(copy_cwd);
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
    const copy_session_name = try allocator.dupe(u8, input.session_name orelse "");
    defer allocator.free(copy_session_name);
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    defer allocator.free(loop_index_str);
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    defer allocator.free(temperature_str);
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try allocator.dupe(u8, input.parent_session_id orelse "");
    defer allocator.free(copy_parent_session_id);
    const copy_parent_id = try allocator.dupe(u8, input.parent_id orelse "");
    defer allocator.free(copy_parent_id);
    const copy_tool_name = try allocator.dupe(u8, input.tool_name orelse "");
    defer allocator.free(copy_tool_name);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_reasoning, copy_cwd, copy_agent, copy_session_name, loop_index_str, temperature_str, is_thinking_str, created_at, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name };

    try db.exec(allocator, sql, sqlArgs);
}

test {
    _ = @import("save_message_test.zig");
}

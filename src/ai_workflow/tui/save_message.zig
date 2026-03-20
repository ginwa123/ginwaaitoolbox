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

pub const save_messageInput = struct {
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    content: ?[]const u8,
    reasoning_content: ?[]const u8,
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

pub fn save_message(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    input: save_messageInput,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{}", .{std.time.nanoTimestamp()});
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.time.milliTimestamp()});

    const contentStr = input.content orelse "";
    const finishReasonStr = input.finish_reason orelse "null";
    const roleStr = input.role orelse "assistant";
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent_name orelse "Agent";

    // Determine tool_calls_json: prefer serialized tool_calls, fall back to tool_call_id, then empty string
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (input.tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    } else if (input.tool_call_id) |tcid| {
        toolCallsJson = tcid;
    }

    const sql = "INSERT INTO llm_history (id, session_id, model, response_content, finish_reason, role, tool_calls_json, reasoning_content, session_dir, is_feed_to_llm, agent, session_name, loop_index, temperature, is_thinking, created_at, parent_session_id, parent_id, prompt_tokens, completion_tokens, total_tokens, is_input, is_output, tool_name) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";

    const copy_session_id = try allocator.dupe(u8, input.session_id);
    const copy_model = try allocator.dupe(u8, input.model);
    const copy_content = try allocator.dupe(u8, contentStr);
    const copy_finish_reason = try allocator.dupe(u8, finishReasonStr);
    const copy_role = try allocator.dupe(u8, roleStr);
    const copy_tool_calls = try allocator.dupe(u8, toolCallsJson);
    const copy_reasoning = try allocator.dupe(u8, reasoningStr);
    const copy_cwd = try allocator.dupe(u8, input.cwd);
    const copy_agent = try allocator.dupe(u8, agentStr);
    const copy_session_name = try allocator.dupe(u8, input.session_name orelse "");
    const loop_index_str = try std.fmt.allocPrint(allocator, "{}", .{input.loop_index});
    const temperature_str = try std.fmt.allocPrint(allocator, "{d:.2}", .{input.temperature});
    const is_thinking_str = if (input.is_thinking) "1" else "0";
    const copy_parent_session_id = try allocator.dupe(u8, input.parent_session_id orelse "");
    const copy_parent_id = try allocator.dupe(u8, input.parent_id orelse "");
    const copy_tool_name = try allocator.dupe(u8, input.tool_name orelse "");
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_reasoning, copy_cwd, copy_agent, copy_session_name, loop_index_str, temperature_str, is_thinking_str, created_at, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name };

    try db.exec(allocator, sql, sqlArgs);
}

test {
    _ = @import("save_message_test.zig");
}

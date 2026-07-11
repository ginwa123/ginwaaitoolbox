const std = @import("std");
const mod = @import("mod.zig");
const nalarcore = mod.nalarcore;
const sqlite = nalarcore.sqlite;
const logger_mod = nalarcore.loggermod;
const agent = nalarcore.agent;
const LLMHistory = mod.LLMHistory;
const event_bus_mod = nalarcore.event_bus;

pub const InsertLLMHistoriesInput = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.SqliteBackend,
    logger: ?*logger_mod.Logger,
    is_emit_sse: bool,
    event_bus: ?*event_bus_mod.EventBus,
    entity: LLMHistory,
};

// pub const SaveMessageInput = struct {
//     session_id: []const u8,
//     model: []const u8,
//     cwd: []const u8,
//     content: ?[]const u8,
//     reasoning_content: ?[]const u8,
//     role: ?[]const u8,
//     finish_reason: ?[]const u8,
//     tool_calls: ?[]agent.ToolCall,
//     tool_call_id: ?[]const u8,
//     tool_name: ?[]const u8 = null,
//     agent_name: ?[]const u8,
//     loop_index: u32,
//     temperature: f32,
//     is_thinking: bool,
//     is_input: bool = false,
//     is_output: bool = false,
//     parent_session_id: ?[]const u8 = null,
//     parent_id: ?[]const u8 = null,
//     prompt_tokens: usize = 0,
//     completion_tokens: usize = 0,
//     total_tokens: usize = 0,
//     diffview_before: ?[]const u8 = null,
//     diffview_after: ?[]const u8 = null,
//     image_urls: ?[][]const u8 = null,
//     is_feed_to_llm: bool = true,
// };

pub fn inserLLMHistories(
    obj: InsertLLMHistoriesInput,
) !void {
    const allocator = obj.allocator;
    const db = obj.db;
    const logger = obj.logger;
    _ = logger;
    const io = obj.io;

    const input = obj.entity;

    const id = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(id);
    const created_at = try std.fmt.allocPrint(allocator, "{}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
    defer allocator.free(created_at);

    const contentStr = input.content orelse "";
    const finishReasonStr = input.finish_reason orelse "null";
    const roleStr = input.role orelse "assistant";
    const reasoningStr = input.reasoning_content orelse "";
    const agentStr = input.agent_name orelse "Agent";

    // tool_calls_json holds ONLY the serialized tool_calls array (assistant message wire format).
    // For tool result messages, the tool_call_id lives in the dedicated tool_call_id column —
    // do NOT overload tool_calls_json with the id. That overload caused the 2013 bug where the
    // transform could not tell a JSON array from a plain id string.
    var toolCallsJson: []const u8 = "";
    var toolCallsOwned: ?[]u8 = null;
    if (input.tool_calls) |tc| {
        toolCallsOwned = try serializeToolCalls(allocator, tc);
        toolCallsJson = toolCallsOwned.?;
    }
    defer if (toolCallsOwned) |tcj| allocator.free(tcj);

    const sql =
        \\INSERT INTO llm_history (
        \\    id,
        \\    session_id,
        \\    model,
        \\    response_content,
        \\    finish_reason,
        \\    role,
        \\    tool_calls_json,
        \\    tool_call_id,
        \\    reasoning_content,
        \\    is_feed_to_llm,
        \\    agent,
        \\    loop_index,
        \\    temperature,
        \\    is_thinking,
        \\    created_at,
        \\    parent_session_id,
        \\    parent_id,
        \\    prompt_tokens,
        \\    completion_tokens,
        \\    total_tokens,
        \\    is_input,
        \\    is_output,
        \\    tool_name,
        \\    diffview_before,
        \\    diffview_after,
        \\    image_url
        \\) VALUES (
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
        \\    ?, ?, ?, ?, ?, ?
        \\)
    ;

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
    const copy_agent = try allocator.dupe(u8, agentStr);
    defer allocator.free(copy_agent);
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
    const copy_tool_call_id = try allocator.dupe(u8, input.tool_call_id orelse "");
    defer allocator.free(copy_tool_call_id);
    const prompt_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.prompt_tokens});
    defer allocator.free(prompt_tokens_str);
    const completion_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.completion_tokens});
    defer allocator.free(completion_tokens_str);
    const total_tokens_str = try std.fmt.allocPrint(allocator, "{}", .{input.total_tokens});
    defer allocator.free(total_tokens_str);
    const copy_diffview_before = try allocator.dupe(u8, input.diffview_before orelse "");
    defer allocator.free(copy_diffview_before);
    const copy_diffview_after = try allocator.dupe(u8, input.diffview_after orelse "");
    defer allocator.free(copy_diffview_after);

    const copy_is_feed_to_llm = try allocator.dupe(u8, if (input.is_feed_to_llm) "1" else "0");
    defer allocator.free(copy_is_feed_to_llm);

    // Join multiple image URLs with || delimiter
    var image_urls_str: []const u8 = "";
    var copy_image_urls: ?[]u8 = null;
    if (input.image_urls) |urls| {
        if (urls.len > 0) {
            var combined = std.ArrayList(u8).empty;
            defer combined.deinit(allocator);
            for (urls, 0..) |url, i| {
                if (i > 0) try combined.appendSlice(allocator, "||");
                try combined.appendSlice(allocator, url);
            }
            copy_image_urls = try allocator.dupe(u8, combined.items);
            image_urls_str = copy_image_urls.?;
        }
    }
    defer if (copy_image_urls) |c| allocator.free(c);

    const sqlArgs = &.{ id, copy_session_id, copy_model, copy_content, copy_finish_reason, copy_role, copy_tool_calls, copy_tool_call_id, copy_reasoning, copy_is_feed_to_llm, copy_agent, loop_index_str, temperature_str, is_thinking_str, created_at, copy_parent_session_id, copy_parent_id, prompt_tokens_str, completion_tokens_str, total_tokens_str, if (input.is_input) "1" else "0", if (input.is_output) "1" else "0", copy_tool_name, copy_diffview_before, copy_diffview_after, image_urls_str };

    try db.exec(allocator, sql, sqlArgs);

    // Update the session's cwd in the sessions table
    const copy_cwd = try allocator.dupe(u8, input.cwd);
    defer allocator.free(copy_cwd);
    try db.exec(allocator, "UPDATE sessions SET cwd = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?", &.{ copy_cwd, copy_session_id });

    _ = on_event_sent.onEventSendLLMHistory(allocator, .{
        .session_id = session_id,
        .model = config.model,
        .cwd = cwd,
        .content = error_message,
        .reasoning_content = null,
        .role = agent.Role.user.to_str(),
        .finish_reason = "null",
        .tool_calls_json = null,
        .tool_call_id = null,
        .agent_name = initial_agent,
        .loop_index = 0,
        .temperature = initial_agent_state.temperature,
        .is_thinking = initial_agent_state.is_thinking,
        .parent_id = session_id,
        .parent_session_id = session_id,
        .is_input = true,
        .is_output = false,
        .image_url = null,
        .session_skills = session_skills_err,
    }) catch |on_event_sent_err| {
        logger.errFmt("[{s}] failed to sent llm historry: {s}\n", .{ keyword, @errorName(on_event_sent_err) });
    };
}

fn serializeToolCalls(allocator: std.mem.Allocator, tool_calls: []agent.ToolCall) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try aw.writer.print("{f}", .{std.json.fmt(tool_calls, .{})});
    return aw.toOwnedSlice();
}

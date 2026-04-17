const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const llm_history = @import("llm_history.zig");
const save_message = llm_history.saveMessage;
const on_event_send_new = @import("on_event_sent.zig").on_event_send_new;
const session_helpers = llm_history;
const get_current_agent_by_session_id = llm_history.get_current_agent_by_session_id;

pub fn handle_content_filter_run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    res_dynamic_agent: agent.CallResponse,
    agent_temperature: f32,
    is_thinking: bool,
) !bool {
    // Fetch current agent from DB
    const current_agent_state = try get_current_agent_by_session_id(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;
    logger.infoFmt("FINISH REASON CONTENT FILTER - content was filtered due to safety policies", .{}) catch {};

    // Save the filtered response to history
    _ = try save_message(
        allocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = res_dynamic_agent.content,
        .reasoning_content = res_dynamic_agent.reasoning_content,
        .role = agent.Role.assistant.toStr(),
        .finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null,
        .tool_calls = null,
        .tool_call_id = null,
        .agent_name = current_agent,
        .session_name = session_name,
        .loop_index = loop_counter,
        .temperature = agent_temperature,
        .is_thinking = is_thinking,
        .prompt_tokens = res_dynamic_agent.usage.prompt_tokens,
        .completion_tokens = res_dynamic_agent.usage.completion_tokens,
        .total_tokens = res_dynamic_agent.usage.total_tokens,
    });

    // The response content may be empty or contain partial filtered content
    if (res_dynamic_agent.content) |c| {
        if (c.len > 0) {
            // Send the partial content with content_filter finish reason
            _ = try on_event_send_new(allocator, .{
                .session_id = session_id,
                .model = model,
                .cwd = cwd,
                .content = res_dynamic_agent.content,
                .reasoning_content = res_dynamic_agent.reasoning_content,
                .role = "assistant",
                .finish_reason = "content_filter",
                .tool_calls = null,
                .tool_call_id = null,
                .tool_name = null,
                .agent_name = current_agent,
                .session_name = session_name,
                .loop_index = loop_counter,
                .temperature = agent_temperature,
                .is_thinking = is_thinking,
                .is_input = false,
                .is_output = false,
                .parent_session_id = session_id,
                .parent_id = session_id,
            }) catch {};
        } else {
            // No content, send error message
            _ = try on_event_send_new(allocator, .{
                .session_id = session_id,
                .model = model,
                .cwd = cwd,
                .content = "Content was filtered due to safety policies. Please rephrase your request.",
                .reasoning_content = null,
                .role = "assistant",
                .finish_reason = "stop",
                .tool_calls = null,
                .tool_call_id = null,
                .tool_name = null,
                .agent_name = current_agent,
                .session_name = session_name,
                .loop_index = loop_counter,
                .temperature = agent_temperature,
                .is_thinking = is_thinking,
                .is_input = false,
                .is_output = false,
                .parent_session_id = session_id,
                .parent_id = session_id,
            });
        }
    } else {
        // No content, send error message
        on_event_send_new(allocator, .{
            .session_id = session_id,
            .model = model,
            .cwd = cwd,
            .content = "Content was filtered due to safety policies. Please rephrase your request.",
            .reasoning_content = null,
            .role = "assistant",
            .finish_reason = "stop",
            .tool_calls = null,
            .tool_call_id = null,
            .tool_name = null,
            .agent_name = current_agent,
            .session_name = session_name,
            .loop_index = loop_counter,
            .temperature = agent_temperature,
            .is_thinking = is_thinking,
            .is_input = false,
            .is_output = false,
            .parent_session_id = session_id,
            .parent_id = session_id,
        }) catch {};
    }

    return true; // Signal caller to break the loop
}


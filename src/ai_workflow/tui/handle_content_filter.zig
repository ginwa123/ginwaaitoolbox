const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const SaveMessage = @import("save_message.zig").SaveMessage;
const send_response = @import("send_response.zig");
const send_error = @import("send_error.zig");
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");

pub fn run(
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
    const current_agent_state = try get_current_agent_by_session_id.run(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;
    logger.infoFmt("FINISH REASON CONTENT FILTER - content was filtered due to safety policies", .{}) catch {};

    // Save the filtered response to history
    SaveMessage(
        allocator, db, .{
        .session_id = session_id,
        .model = model,
        .cwd = cwd,
        .content = null,
        .response_content = res_dynamic_agent.content,
        .response_finish_reason = if (res_dynamic_agent.finish_reason) |fr| fr.toStr() else null,
        .response_reasoning_content = res_dynamic_agent.reasoning_content,
        .role = agent.Role.assistant.toStr(),
        .finish_reason = null,
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
    }) catch |err| {
        const err_name = @errorName(err);
        logger.errFmt("saveMessage error: {s}", .{err_name}) catch {};
    };

    // Send error response to client with content_filter finish reason
    // The response content may be empty or contain partial filtered content
    if (res_dynamic_agent.content) |c| {
        if (c.len > 0) {
            // Send the partial content with content_filter finish reason
            send_response.SendResponse(allocator, session_id, logger, res_dynamic_agent, "content_filter");
        } else {
            // No content, send error message
            send_error.run(allocator, session_id, logger, "Content was filtered due to safety policies. Please rephrase your request.", "user_choice");
        }
    } else {
        // No content, send error message
        send_error.run(allocator, session_id, logger, "Content was filtered due to safety policies. Please rephrase your request.", "user_choice");
    }

    return true; // Signal caller to break the loop
}

test {
    _ = @import("handle_content_filter_test.zig");
}

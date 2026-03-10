const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const prompt = tree1_mod.prompt;
const change_agent_tool = tree1_mod.change_agent_tool;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const save_message = @import("save_message.zig");
const send_tool_result = @import("send_tool_result.zig");
const get_tree_dir = @import("get_tree_dir.zig");

pub fn run(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
    agent_temperature: *f32,
    isThinking: *bool,
) !void {
    const parsed = try std.json.parseFromSlice(
        change_agent_tool.ChangeAgentToolResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    const agent_name = parsed.value.agent;
    // const agent_message = parsed.value.message;
    const new_agent_temperature = parsed.value.temperature;
    if (new_agent_temperature) |temperature| {
        agent_temperature.* = temperature;
    }

    const new_is_thinking = parsed.value.is_thinking;
    if (new_is_thinking) |thinking| {
        isThinking.* = thinking;
    }

    const contentChangeAgent = try std.fmt.allocPrint(
        allocator,
        "<change_agent_tool>\n{s}\n<change_agent_tool>",
        .{tool_call.function.arguments},
    );

    // 1. Create tool result message and add to messages_list (required for API)
    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = contentChangeAgent,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    _ = try messages_list.append(allocator, tool_result_msg);

    // 2. Save tool result to database
    _ = save_message.run(allocator, db, session_id, model, cwd, contentChangeAgent, null, null, null, "tool", "tool", null, tool_call.id, agent_name, session_name, loop_counter, agent_temperature.*, isThinking.*) catch |err| {
        logger.errFmt("saveMessageAsTool error: {s}", .{@errorName(err)}) catch {};
    };
    send_tool_result.run(allocator, session_id, logger, contentChangeAgent, tool_call.id, tool_call.function.name, null);

    logger.infoFmt("Switched to agent: {s}", .{agent_name}) catch {};
}

test {
    _ = @import("handle_change_agent_tool_test.zig");
}

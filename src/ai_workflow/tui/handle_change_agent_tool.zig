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
    parent_allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    logger: *logger_mod.Logger,
    conn_fd: std.posix.fd_t,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    session_name: ?[]const u8,
    loop_counter: u32,
    messages_list: *std.ArrayList(agent.AgentMessage),
    tool_call: agent.ToolCall,
    agent_temperature: *f32,
    isThinking: *bool,
    current_agent: *[]const u8,
) !void {
    const parsed = try std.json.parseFromSlice(
        change_agent_tool.ChangeAgentToolResult,
        allocator,
        tool_call.function.arguments,
        .{},
    );
    defer parsed.deinit();

    const agent_name = parsed.value.agent;
    const agent_message = parsed.value.message;
    const new_agent_temperature = parsed.value.temperature;
    if (new_agent_temperature) |temperature| {
        agent_temperature.* = temperature;
    }

    const new_is_thinking = parsed.value.is_thinking;
    if (new_is_thinking) |thinking| {
        isThinking.* = thinking;
    }

    var agent_prompt: []const u8 = if (std.mem.eql(u8, agent_name, "GeneralAgent"))
        prompt.GeneralAgent
    else if (std.mem.eql(u8, agent_name, "ExplorationAgent"))
        prompt.ExplorationAgent
    else if (std.mem.eql(u8, agent_name, "PlanningAgent"))
        prompt.PlanningAgent
    else if (std.mem.eql(u8, agent_name, "ExecutingAgent"))
        prompt.ExecutingAgent
    else if (std.mem.eql(u8, agent_name, "KnowledgeAgent"))
        prompt.KnowledgeAgent
    else if (std.mem.eql(u8, agent_name, "ReviewAgent"))
        prompt.ReviewAgent
    else {
        logger.warnFmt("change_agent_tool: unknown agent '{s}'", .{agent_name}) catch {};
        return;
    };

    agent_prompt = prompt.agenticCodingWithCwd(allocator, cwd, agent_prompt, try get_tree_dir.run(allocator, cwd), "") catch |err| {
        logger.errFmt("Failed to format agent prompt: {s}", .{@errorName(err)}) catch {};
        return;
    };

    const msgPrompt = try std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}",
        .{ agent_prompt, agent_message },
    );

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
    try messages_list.append(allocator, tool_result_msg);

    // 2. Save tool result to database
    save_message.run(allocator, db, session_id, model, cwd, contentChangeAgent, null, "tool", "tool", null, tool_call.id, agent_name, session_name, loop_counter) catch |err| {
        logger.errFmt("saveMessageAsTool error: {s}", .{@errorName(err)}) catch {};
    };
    send_tool_result.run(allocator, conn_fd, logger, contentChangeAgent, tool_call.id, tool_call.function.name, null);

    // Update the loop-persistent current_agent variable
    current_agent.* = try parent_allocator.dupe(u8, agent_name);

    // 3. Replace system message only, keep all history
    var system_replaced = false;
    for (messages_list.items) |*msg| {
        if (msg.role == .system) {
            msg.content = msgPrompt;
            system_replaced = true;
            break;
        }
    }
    if (!system_replaced) {
        try messages_list.insert(allocator, 0, agent.AgentMessage{
            .role = .system,
            .content = msgPrompt,
        });
    }

    logger.infoFmt("Switched to agent: {s}", .{agent_name}) catch {};
}

test {
    _ = @import("handle_change_agent_tool_test.zig");
}

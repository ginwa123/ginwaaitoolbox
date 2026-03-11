const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const tool_models = tree1_mod.tool_models;
const logger_mod = tree1_mod.logger;
const sqlite = tree1_mod.sqlite;
const spawn_sub_agent_tool = @import("../../modules/agent/tools/spawn_sub_agent.zig");
const save_message = @import("save_message.zig");
const send_tool_result = @import("send_tool_result.zig");
const get_current_agent_by_session_id = @import("get_current_agent_by_session_id.zig");

const MAX_SUB_AGENTS = 20;

/// Parse XML input and run spawn_sub_agent handler
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
    agent_temperature: f32,
    is_thinking: bool,
    api_key: []const u8,
    base_url: []const u8,
) !void {
    _ = api_key;
    _ = base_url;
    // Parse the XML input from function.arguments
    const parsed = try spawn_sub_agent_tool.parseSubAgents(allocator, tool_call.function.arguments, MAX_SUB_AGENTS);
    defer parsed.deinit(allocator);
    
    logger.infoFmt("spawn_sub_agent: spawning {} parallel sub-agents", .{parsed.sub_agents.len}) catch {};
    
    // TODO: Implement parallel sub-agent execution
    // For now, return a placeholder result
    const result_msg = try std.fmt.allocPrint(
        allocator,
        "Spawned {} sub-agents (parallel execution TBD)",
        .{parsed.sub_agents.len},
    );
    defer allocator.free(result_msg);
    
    // Fetch current agent from DB
    const current_agent_state = try get_current_agent_by_session_id.run(
        allocator,
        db,
        session_id,
    );
    const current_agent = current_agent_state.agent;
    
    const tool_result_msg = agent.AgentMessage{
        .role = .tool,
        .content = result_msg,
        .tool_call_id = try allocator.dupe(u8, tool_call.id),
    };
    try messages_list.append(allocator, tool_result_msg);
    
    // Save to DB
    _ = try save_message.run(
        allocator, db, session_id, model, cwd,
        result_msg, null, null, null, "tool", "tool", null, tool_call.id,
        current_agent, session_name, loop_counter, agent_temperature, is_thinking);
    
    _ = send_tool_result.run(allocator, session_id, logger, result_msg, tool_call.id, "spawn_sub_agent", null);
}

test {
    _ = @import("handle_spawn_sub_agent_test.zig");
}

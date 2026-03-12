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

/// Run a single sub-agent with the given instruction
fn runSubAgent(
    allocator: std.mem.Allocator,
    logger: *logger_mod.Logger,
    instruction: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
) ![]const u8 {
    // Create a simple agent with no tools - just pure LLM response
    var sub_agent = try agent.Agent.init(allocator, logger);
    defer sub_agent.deinit();
    
    sub_agent.apiKey = api_key;
    sub_agent.model = model;
    sub_agent.baseUrl = base_url;
    
    // Build messages: empty system + user instruction
    const messages = try allocator.alloc(agent.AgentMessage, 1);
    messages[0] = .{
        .role = .user,
        .content = instruction,
    };
    
    const params = agent.AgentCall{
        .tools = &[_]tool_models.AgentTool{},
        .messages = messages,
        .temperature = 0.3,
        .max_tokens = 4000,
    };
    
    const response = try sub_agent.call(params);
    defer response.deinit();
    
    if (response.content) |content| {
        return try allocator.dupe(u8, content);
    }
    
    return try allocator.dupe(u8, "(empty response)");
}

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
    // Parse the XML input from function.arguments
    const parsed = try spawn_sub_agent_tool.parseSubAgents(allocator, tool_call.function.arguments, MAX_SUB_AGENTS);
    defer parsed.deinit(allocator);
    
    logger.infoFmt("spawn_sub_agent: spawning {} parallel sub-agents", .{parsed.sub_agents.len}) catch {};
    
    // Run each sub-agent and collect results
    var results: std.ArrayList([]const u8) = .empty;
    defer {
        for (results.items) |r| allocator.free(r);
        results.deinit(allocator);
    }
    
    for (parsed.sub_agents) |sub_agent| {
        logger.infoFmt("spawn_sub_agent: running agent '{s}' with instruction: {s}", .{ sub_agent.name, sub_agent.instruction }) catch {};
        
        const result = runSubAgent(allocator, logger, sub_agent.instruction, api_key, model, base_url) catch |err| {
            logger.errFmt("spawn_sub_agent: agent '{s}' failed: {s}", .{ sub_agent.name, @errorName(err) }) catch {};
            const err_msg = try std.fmt.allocPrint(allocator, "ERROR: {s}", .{@errorName(err)});
            defer allocator.free(err_msg);
            try results.append(allocator, err_msg);
            continue;
        };
        try results.append(allocator, result);
    }
    
    // Build combined result message
    var combined_result = std.ArrayList(u8).empty;
    defer combined_result.deinit(allocator);
    var w = combined_result.writer(allocator);
    
    try w.writeAll("<sub_agent_results>\n");
    for (parsed.sub_agents, 0..) |sub_agent, i| {
        try w.print("  <result name=\"{s}\">\n", .{sub_agent.name});
        if (i < results.items.len) {
            // Escape XML entities in result
            const result = results.items[i];
            for (result) |ch| {
                switch (ch) {
                    '&' => try w.writeAll("&amp;"),
                    '<' => try w.writeAll("&lt;"),
                    '>' => try w.writeAll("&gt;"),
                    '"' => try w.writeAll("&quot;"),
                    '\'' => try w.writeAll("&apos;"),
                    else => try w.writeByte(ch),
                }
            }
        }
        try w.writeAll("\n  </result>\n");
    }
    try w.writeAll("</sub_agent_results>");
    
    const result_msg = try combined_result.toOwnedSlice(allocator);
    
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
    
    logger.infoFmt("spawn_sub_agent: completed {} sub-agents", .{parsed.sub_agents.len}) catch {};
}

test {
    _ = @import("handle_spawn_sub_agent_test.zig");
}

const std = @import("std");
const tree1_mod = @import("tree1");
const agent = tree1_mod.agent;
const get_messages = @import("get_messages.zig");
const sqlite = tree1_mod.sqlite;
const prompt = tree1_mod.prompt;
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_messages = @import("transform_llm_history_to_agent_messages.zig");

pub fn run(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    tree_dir: []const u8,
    historyMessages: []TUIHistory,
    skills: []const u8,
) ![]agent.AgentMessage {

    // Determine the agent to use from the latest message in history
    var agent_to_use: []const u8 = "GeneralAgent";
    if (historyMessages.len > 0) {
        // Get the agent from the last message
        const last_msg = historyMessages[historyMessages.len - 1];
        agent_to_use = last_msg.agent;
    }

    // Get the appropriate prompt for the agent
    const agent_prompt: []const u8 = if (std.mem.eql(u8, agent_to_use, "GeneralAgent"))
        prompt.GeneralAgent
    else if (std.mem.eql(u8, agent_to_use, "ExplorationAgent"))
        prompt.ExplorationAgent
    else if (std.mem.eql(u8, agent_to_use, "PlanningAgent"))
        prompt.PlanningAgent
    else if (std.mem.eql(u8, agent_to_use, "ExecutingAgent"))
        prompt.ExecutingAgent
    else if (std.mem.eql(u8, agent_to_use, "KnowledgeAgent"))
        prompt.KnowledgeAgent
    else
        prompt.GeneralAgent;

    const systemContent = try prompt.agenticCodingWithCwdAndSkills(allocator, cwd, agent_prompt, tree_dir, skills);

    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = systemContent,
    };

    var allMessages: std.ArrayList(agent.AgentMessage) = .empty;

    try allMessages.append(allocator, systemMessage);

    for (historyMessages) |hist| {
        const agentMsgs = try transform_llm_history_to_agent_messages.run(allocator, hist);
        for (agentMsgs) |msg| {
            try allMessages.append(allocator, msg);
        }
    }

    return try allMessages.toOwnedSlice(allocator);
}

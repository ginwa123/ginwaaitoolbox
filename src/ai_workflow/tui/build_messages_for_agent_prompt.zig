const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const session_helpers = @import("session_helpers.zig");
const sqlite = tree1_mod.sqlite;
const prompt = tree1_mod.prompt;
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_messages = @import("transform_llm_history_to_agent_messages.zig");

pub fn BuildMessages(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    historyMessages: []TUIHistory,
    skills: []const u8,
    memoryMd: []const u8,
    backgroundProcessmessage: []const u8,
    agentUsed: []const u8,
) ![]agent.AgentMessage {

    // buildAgentPrompt now handles processMessages internally
    const systemContent = try prompt.buildAgentPrompt(allocator, cwd, "", skills, memoryMd, backgroundProcessmessage, agentUsed);

    const systemMessage = agent.AgentMessage{
        .role = .system,
        .content = systemContent,
    };

    var allMessages: std.ArrayList(agent.AgentMessage) = .empty;

    try allMessages.append(allocator, systemMessage);
    for (historyMessages) |hist| {
        const agentMsgs = try transform_llm_history_to_agent_messages.transform_llm_history_to_agent_message(allocator, hist);
        for (agentMsgs) |msg| {
            try allMessages.append(allocator, msg);
        }
    }

    return try allMessages.toOwnedSlice(allocator);
}


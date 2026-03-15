const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const get_messages = @import("get_messages.zig");
const sqlite = tree1_mod.sqlite;
const prompt = tree1_mod.prompt;
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_messages = @import("transform_llm_history_to_agent_messages.zig");

pub fn BuildMessages(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    tree_dir: []const u8,
    historyMessages: []TUIHistory,
    skills: []const u8,
    memoryMd: []const u8,
) ![]agent.AgentMessage {

    // Always use the unified Agent prompt
    const agent_prompt: []const u8 = prompt.Agent;

    const systemContent = try prompt.buildAgentPrompt(allocator, cwd, agent_prompt, tree_dir, skills, memoryMd);

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
        allocator.free(agentMsgs);
    }

    return try allMessages.toOwnedSlice(allocator);
}

/// Build messages with background process info included in system prompt
pub fn BuildMessagesWithBackgroundProcesses(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    session_id: []const u8,
    cwd: []const u8,
    tree_dir: []const u8,
    historyMessages: []TUIHistory,
    skills: []const u8,
    memoryMd: []const u8,
) ![]agent.AgentMessage {
    // Get background process content
    const bg_process_content = if (db != null and session_id.len > 0)
        try @import("build_background_process_content.zig").BuildBackgroundProcessContent(allocator, db.?, session_id)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(bg_process_content);

    // Build messages with background process content
    var messages = try BuildMessages(allocator, cwd, tree_dir, historyMessages, skills, memoryMd);
    
    // If there's background process content, append it to the system message
    if (bg_process_content.len > 0 and messages.len > 0 and messages[0].role == .system) {
        // Re-build system content with background processes appended
        allocator.free(messages[0].content);
        const currentContent = try prompt.buildAgentPrompt(allocator, cwd, prompt.Agent, tree_dir, skills, memoryMd);
        const combined = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ currentContent, bg_process_content });
        allocator.free(currentContent);
        messages[0].content = combined;
    }
    
    return messages;
}

test {
    _ = @import("build_messages_for_agent_test.zig");
}

const std = @import("std");
const tree1_mod = @import("nalarcore");
const agent = tree1_mod.agent;
const llm_history = @import("llm_history.zig");
const session_helpers = llm_history;
const sqlite = tree1_mod.sqlite;
const prompt = tree1_mod.prompt;
const TUIHistory = @import("models.zig").TUIHistory;
const transform_llm_history_to_agent_messages = @import("transform_llm_history_to_agent_messages.zig");
const tool_models = tree1_mod.tool_models;

pub fn BuildMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    session_id: []const u8,
    historyMessages: []TUIHistory,
    skills: []const u8,
    memoryMd: []const u8,
    backgroundProcessmessage: []const u8,
    agentUsed: []const u8,
    tools: []tool_models.AgentTool,
) ![]agent.AgentMessage {

    // buildAgentPrompt now handles processMessages internally
    const activity_info = try build_activity_info(allocator, db, session_id);
    const systemContent = try prompt.build_agent_prompt(allocator, cwd, "", skills, memoryMd, backgroundProcessmessage, agentUsed, tools, activity_info);
    allocator.free(activity_info);

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

/// Build activity info string for the agent prompt
/// Uses worker table as the SOLE source of active workers info
/// Filters out current session to avoid self-reference
fn build_activity_info(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend, current_session_id: []const u8) ![]const u8 {
    const workers = try llm_history.get_active_workers(allocator, db);
    defer {
        for (workers) |*worker| worker.deinit(allocator);
        allocator.free(workers);
    }

    // Filter out current session and count remaining
    var filtered = std.ArrayList(llm_history.WorkerInfo).empty;
    defer filtered.deinit(allocator);
    for (workers) |worker| {
        if (!std.mem.eql(u8, worker.session_id, current_session_id)) {
            try filtered.append(allocator, worker);
        }
    }
    if (filtered.items.len == 0) {
        return try allocator.dupe(u8, "");
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "The following workers are currently active:\n\n");

    for (filtered.items) |worker| {
        try result.appendSlice(allocator, "- **");
        try result.appendSlice(allocator, worker.session_id);
        try result.appendSlice(allocator, "**");
        if (worker.working_directory.len > 0) {
            try result.appendSlice(allocator, " @ ");
            try result.appendSlice(allocator, worker.working_directory);
        }
        if (worker.last_activity > 0) {
            const now: i64 = @intCast(std.time.timestamp());
            const diff_secs = now - worker.last_activity;
            try result.appendSlice(allocator, " | last activity: ");
            try result.appendSlice(allocator, format_relative_time(diff_secs));
            if (worker.last_activity_description.len > 0) {
                try result.appendSlice(allocator, " (");
                try result.appendSlice(allocator, worker.last_activity_description);
                try result.appendSlice(allocator, ")");
            }
        }
        try result.appendSlice(allocator, "\n");
    }

    return try result.toOwnedSlice(allocator);
}

/// Format seconds into human-readable relative time
pub fn format_relative_time(seconds: i64) []const u8 {
    if (seconds < 60) {
        return "< 1m";
    } else if (seconds < 3600) {
        const mins = @divTrunc(seconds, 60);
        return if (mins == 1) "1m" else if (mins < 5) "2m" else "5m";
    } else if (seconds < 86400) {
        const hours = @divTrunc(seconds, 3600);
        return if (hours == 1) "1h" else if (hours < 12) "5h" else "12h+";
    } else {
        return "> 24h";
    }
}


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
const activity_registry = tree1_mod.session.activity_registry;

pub fn BuildMessages(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteBackend,
    cwd: []const u8,
    historyMessages: []TUIHistory,
    skills: []const u8,
    memoryMd: []const u8,
    backgroundProcessmessage: []const u8,
    agentUsed: []const u8,
    tools: []tool_models.AgentTool,
) ![]agent.AgentMessage {

    // buildAgentPrompt now handles processMessages internally
    const activity_info = try build_activity_info(allocator, db);
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
/// Uses activity_registry as PRIMARY source for active workers
/// DB provides enriched info (working_directory, last_activity)
fn build_activity_info(allocator: std.mem.Allocator, db: *sqlite.SqliteBackend) ![]const u8 {
    const registry = activity_registry.get_global_registry() orelse {
        return try allocator.dupe(u8, "");
    };

    // Get worker info from database for enrichment
    const workers = llm_history.get_active_workers(allocator, db) catch null;
    defer if (workers) |w| {
        for (w) |*worker| worker.deinit(allocator);
        allocator.free(w);
    };

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var iter = registry.sessions.iterator();
    var has_activity = false;

    while (iter.next()) |entry| {
        const session_id = entry.key_ptr.*;
        const atomic = entry.value_ptr.*;

        // Check if this session is currently running (not stopped, activity > 0)
        if (atomic.load(.seq_cst) > 0 and !registry.stopped.contains(session_id)) {
            if (!has_activity) {
                try result.appendSlice(allocator, "The following workers are currently active:\n\n");
                has_activity = true;
            }

            // Try to find enriched info from DB
            var working_dir: []const u8 = "";
            var last_activity_secs: i64 = 0;
            var last_activity_desc: []const u8 = "";

            if (workers) |w| {
                for (w) |worker| {
                    if (std.mem.eql(u8, worker.session_id, session_id)) {
                        working_dir = worker.working_directory;
                        last_activity_secs = worker.last_activity;
                        last_activity_desc = worker.last_activity_description;
                        break;
                    }
                }
            }

            try result.appendSlice(allocator, "- **");
            try result.appendSlice(allocator, session_id);
            try result.appendSlice(allocator, "**");
            if (working_dir.len > 0) {
                try result.appendSlice(allocator, " @ ");
                try result.appendSlice(allocator, working_dir);
            }
            if (last_activity_secs > 0) {
                const now: i64 = @intCast(std.time.timestamp());
                const diff_secs = now - last_activity_secs;
                try result.appendSlice(allocator, " | last activity: ");
                try result.appendSlice(allocator, format_relative_time(diff_secs));
                if (last_activity_desc.len > 0) {
                    try result.appendSlice(allocator, " (");
                    try result.appendSlice(allocator, last_activity_desc);
                    try result.appendSlice(allocator, ")");
                }
            }
            try result.appendSlice(allocator, "\n");
        }
    }

    if (!has_activity) {
        return try allocator.dupe(u8, "");
    }

    return try result.toOwnedSlice(allocator);
}

/// Format seconds into human-readable relative time
pub fn format_relative_time(seconds: i64) []const u8 {
    if (seconds < 60) {
        return "< 1m";
    } else if (seconds < 3600) {
        const mins = @divTrunc(seconds, 60);
        return if (mins == 1) "1m" else if (mins < 10) "2m" else "5m";
    } else if (seconds < 86400) {
        const hours = @divTrunc(seconds, 3600);
        return if (hours == 1) "1h" else if (hours < 12) "5h" else "12h+";
    } else {
        return "> 24h";
    }
}


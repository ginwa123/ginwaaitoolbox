const std = @import("std");
const build_messages = @import("build_messages_for_agent_prompt.zig");
const workflow = @import("workflow.zig");
const tool_models = @import("nalarcore").tool_models;
const TUIHistory = @import("models.zig").TUIHistory;
const sqlite = @import("nalarcore").sqlite;

// Test filterAndMergeTools with "all" - should return all tools
test "filterAndMergeTools - all tools allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try workflow.filterAndMergeTools(alloc, &[_]tool_models.AgentTool{}, "all");
    defer alloc.free(result);

    try std.testing.expect(result.len > 0);
}

// Test filterAndMergeTools with comma-separated list - filters base tools
test "filterAndMergeTools - filters to specific tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try workflow.filterAndMergeTools(alloc, &[_]tool_models.AgentTool{}, "read_file,glob");
    defer alloc.free(result);

    for (result) |tool| {
        const name = tool.function.name;
        try std.testing.expect(
            std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "glob"),
        );
    }
}

// Test filterAndMergeTools merges MCP tools with base tools
test "filterAndMergeTools - mcp tools are merged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const mcp_tool = tool_models.AgentTool{
        .type = "function",
        .function = tool_models.AgentToolFunction{
            .name = "mcp_server_tool",
            .description = "test mcp tool",
            .parameters = .{
                .type = "object",
                .properties = &[_]tool_models.ToolProperty{},
                .required = &[_][]const u8{},
            },
        },
    };

    const result = try workflow.filterAndMergeTools(alloc, &[_]tool_models.AgentTool{mcp_tool}, "all");
    defer alloc.free(result);

    const has_mcp_tool = for (result) |tool| {
        if (std.mem.eql(u8, tool.function.name, "mcp_server_tool")) break true;
    } else false;

    try std.testing.expect(has_mcp_tool);
}

// Test BuildSkillContent handles empty session_id
test "BuildSkillContent - empty session returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try build_messages.BuildSkillContent(alloc, undefined, "");
    defer alloc.free(result);

    try std.testing.expect(result.len == 0);
}

// Test BuildBackgroundProcessPrompt handles empty session_id
test "BuildBackgroundProcessPrompt - empty session returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try build_messages.BuildBackgroundProcessPrompt(alloc, undefined, "");
    defer alloc.free(result);

    try std.testing.expect(result.len == 0);
}

// Test BuildDynamicAgentContent handles empty session_id
test "BuildDynamicAgentContent - empty session returns early" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try build_messages.BuildDynamicAgentContent(alloc, undefined, "");
    defer alloc.free(result);

    try std.testing.expect(result.len == 0);
}

// Test formatRelativeTime helper function
test "formatRelativeTime - various durations" {
    try std.testing.expectEqualStrings("< 1m", build_messages.formatRelativeTime(30));
    try std.testing.expectEqualStrings("1m", build_messages.formatRelativeTime(60));
    try std.testing.expectEqualStrings("5m", build_messages.formatRelativeTime(300));
    try std.testing.expectEqualStrings("1h", build_messages.formatRelativeTime(3600));
    try std.testing.expectEqualStrings("5h", build_messages.formatRelativeTime(7200));
    try std.testing.expectEqualStrings("12h+", build_messages.formatRelativeTime(43200));
    try std.testing.expectEqualStrings("> 24h", build_messages.formatRelativeTime(86400));
}

// Test buildMessages - creates system message with history
test "buildMessages - returns messages with system prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create in-memory SQLite database
    var db: sqlite.SqliteBackend = undefined;
    try db.init(":memory:");
    defer db.deinit();

    // Create required tables for the test
    try db.exec(alloc, "CREATE TABLE IF NOT EXISTS session_skills (session_id TEXT NOT NULL, skill_name TEXT NOT NULL, content TEXT NOT NULL, loaded_at INTEGER DEFAULT (strftime('%s', 'now')), PRIMARY KEY (session_id, skill_name))", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE IF NOT EXISTS session_agents (session_id TEXT NOT NULL, agent_name TEXT NOT NULL, PRIMARY KEY (session_id, agent_name))", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE IF NOT EXISTS session_background_process (session_id TEXT NOT NULL, pid INTEGER NOT NULL, command TEXT NOT NULL, log_path TEXT NOT NULL, status TEXT NOT NULL, started_at INTEGER DEFAULT (strftime('%s', 'now')))", &[_][]const u8{});
    try db.exec(alloc, "CREATE TABLE IF NOT EXISTS worker (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, working_directory TEXT, last_activity INTEGER DEFAULT (strftime('%s', 'now')), last_activity_description TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)", &[_][]const u8{});

    // Create empty history
    const empty_history: []TUIHistory = &[_]TUIHistory{};

    // Create mock tools (can be empty for this test)
    const empty_tools: []tool_models.AgentTool = &[_]tool_models.AgentTool{};

    // Call buildMessages
    const result = try build_messages.buildMessages(
        alloc,
        &db,
        "/tmp",
        "test-session-123",
        empty_history,
        empty_tools,
    );
    defer {
        for (result) |*msg| msg.deinit(alloc);
        alloc.free(result);
    }

    // Should have at least the system message
    try std.testing.expect(result.len >= 1);

    // First message should be system role
    try std.testing.expect(result[0].role == .system);
    // System message content should not be empty (contains prompt instructions)
    try std.testing.expect(result[0].content != null);
    try std.testing.expect(result[0].content.?.len > 0);
}
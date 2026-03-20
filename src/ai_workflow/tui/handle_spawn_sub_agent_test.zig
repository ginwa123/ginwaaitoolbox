const std = @import("std");
const root_mod = @import("nalarcore");
const agent = root_mod.agent;
const sqlite = root_mod.sqlite;

// Import the module under test
const handle_spawn_sub_agent = @import("handle_spawn_sub_agent.zig");

// Test helper: create a minimal ToolCall
fn makeToolCall(name: []const u8, args: []const u8) agent.ToolCall {
    return agent.ToolCall{
        .id = "test-id",
        .type = "function",
        .function = .{
            .name = name,
            .arguments = args,
        },
    };
}

// Test helper: create a dummy SqliteBackend (initialized but not actually connected)
fn makeDummyDb() sqlite.SqliteBackend {
    return sqlite.SqliteBackend{};
}

// ============================================================================
// Tests for executeSubAgentTool
// ============================================================================

test "executeSubAgentTool - list_skills executes successfully" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("list_skills", "{}");
    var db = makeDummyDb();
    const session_id = "test-session";

    // The list_skills tool doesn't need actual DB connection
    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Result should contain valid JSON with skills array
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "{\"skills\":[") != null);
}

test "executeSubAgentTool - unknown tool returns error.UnknownTool" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("nonexistent_tool", "{}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);
    try std.testing.expectError(error.UnknownTool, result);
}

test "executeSubAgentTool - tool execution error is caught and returned" {
    const allocator = std.testing.allocator;
    // bash with invalid command will fail
    const tc = makeToolCall("bash", "{\"command\": \"exit 1\", \"cwd\": \"/tmp\"}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Should contain error message (bash execution error)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ERROR:") != null or
        std.mem.indexOf(u8, result.output, "error") != null);
}

test "executeSubAgentTool - read_file with valid path" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("read_file", "{\"path\": \"README.md\"}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // read_file doesn't need db/session_id, so should work
    try std.testing.expect(result.output.len > 0);
}

test "executeSubAgentTool - search tool executes" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("search", "{\"pattern\": \"test\", \"path\": \".\"}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // search returns results or empty array
    try std.testing.expect(result.output.len > 0);
}

// ============================================================================
// Tests for parseSkillFromResult
// ============================================================================

test "parseSkillFromResult - extracts skill info from valid output" {
    const output =
        \\<loaded>true</loaded>
        \\<skill_name>test_skill</skill_name>
        \\<content>skill content here</content>
    ;

    const result = handle_spawn_sub_agent.parseSkillFromResult(output);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test_skill", result.?.name);
    try std.testing.expectEqualStrings("skill content here", result.?.content);
}

test "parseSkillFromResult - returns null when no loaded tag" {
    const output = "<skill_name>test</skill_name><content>content</content>";

    const result = handle_spawn_sub_agent.parseSkillFromResult(output);

    try std.testing.expect(result == null);
}

test "parseSkillFromResult - returns null when missing skill_name" {
    const output = "<loaded>true</loaded><content>content</content>";

    const result = handle_spawn_sub_agent.parseSkillFromResult(output);

    try std.testing.expect(result == null);
}

test "parseSkillFromResult - returns null when missing content" {
    const output = "<loaded>true</loaded><skill_name>test</skill_name>";

    const result = handle_spawn_sub_agent.parseSkillFromResult(output);

    try std.testing.expect(result == null);
}

test "parseSkillFromResult - handles empty strings" {
    const output = "<loaded>true</loaded><skill_name></skill_name><content></content>";

    const result = handle_spawn_sub_agent.parseSkillFromResult(output);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("", result.?.name);
    try std.testing.expectEqualStrings("", result.?.content);
}

// ============================================================================
// Tests for parseAgentFromResult
// ============================================================================

test "parseAgentFromResult - extracts agent name from valid output" {
    const output =
        \\<loaded>true</loaded>
        \\<agent_name>my_agent</agent_name>
        \\some content
    ;

    const result = handle_spawn_sub_agent.parseAgentFromResult(output);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("my_agent", result.?);
}

test "parseAgentFromResult - returns null when no loaded tag" {
    const output = "<agent_name>test</agent_name>";

    const result = handle_spawn_sub_agent.parseAgentFromResult(output);

    try std.testing.expect(result == null);
}

test "parseAgentFromResult - returns null when missing agent_name" {
    const output = "<loaded>true</loaded>";

    const result = handle_spawn_sub_agent.parseAgentFromResult(output);

    try std.testing.expect(result == null);
}

// ============================================================================
// Tests for getAllowedTools
// ============================================================================

test "getAllowedTools - returns all tools when no filter" {
    const allocator = std.testing.allocator;

    const result = try handle_spawn_sub_agent.getAllowedTools(allocator, null);
    defer allocator.free(result);

    // Should have multiple tools (bash, read_file, search, etc.)
    try std.testing.expect(result.len > 5);

    // Verify some expected tools are present
    var has_bash = false;
    var has_read_file = false;
    var has_list_skills = false;
    for (result) |tool| {
        if (std.mem.eql(u8, tool.function.name, "bash")) has_bash = true;
        if (std.mem.eql(u8, tool.function.name, "read_file")) has_read_file = true;
        if (std.mem.eql(u8, tool.function.name, "list_skills")) has_list_skills = true;
    }
    try std.testing.expect(has_bash);
    try std.testing.expect(has_read_file);
    try std.testing.expect(has_list_skills);
}

test "getAllowedTools - filters to allowed tools only" {
    const allocator = std.testing.allocator;
    const allowed = &.{ "bash", "read_file" };

    const result = try handle_spawn_sub_agent.getAllowedTools(allocator, allowed);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    try std.testing.expectEqualStrings("bash", result[0].function.name);
    try std.testing.expectEqualStrings("read_file", result[1].function.name);
}

test "getAllowedTools - returns empty when no tools match filter" {
    const allocator = std.testing.allocator;
    const allowed = &.{"nonexistent_tool"};

    const result = try handle_spawn_sub_agent.getAllowedTools(allocator, allowed);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "getAllowedTools - single allowed tool" {
    const allocator = std.testing.allocator;
    const allowed = &.{"list_skills"};

    const result = try handle_spawn_sub_agent.getAllowedTools(allocator, allowed);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("list_skills", result[0].function.name);
}

// ============================================================================
// Tests for buildToolNamesList
// ============================================================================

test "buildToolNamesList - builds list of tool names" {
    const allocator = std.testing.allocator;

    // Get some tools first
    const tools = try handle_spawn_sub_agent.getAllowedTools(allocator, &.{ "bash", "read_file" });
    defer allocator.free(tools);

    const names = try handle_spawn_sub_agent.buildToolNamesList(allocator, tools);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("bash", names[0]);
    try std.testing.expectEqualStrings("read_file", names[1]);
}

test "buildToolNamesList - empty tool list" {
    const allocator = std.testing.allocator;
    const tools: []const root_mod.tool_models.AgentTool = &.{};

    const names = try handle_spawn_sub_agent.buildToolNamesList(allocator, tools);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    try std.testing.expectEqual(@as(usize, 0), names.len);
}

// ============================================================================
// Integration-style tests
// ============================================================================

test "executeSubAgentTool - SubAgentToolResult with auto_save fields" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("list_skills", "{}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // list_skills doesn't auto-save, so these should be null
    try std.testing.expect(result.skill_save == null);
    try std.testing.expect(result.agent_save == null);
}

test "executeSubAgentTool - write_file tool is available" {
    const allocator = std.testing.allocator;
    // Try to write to a temp path
    const tc = makeToolCall("write_file",
        \\{"path":"/tmp/test_write_file_zig.txt","content":"hello world"}
    );
    var db = makeDummyDb();
    const session_id = "test-session";

    // This should execute (may succeed or fail based on permissions, but shouldn't UnknownTool
    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Should get some output (success or error)
    try std.testing.expect(result.output.len > 0);
}

test "executeSubAgentTool - list_agents tool executes" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("list_agents", "{}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Should return JSON with agents
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "agents") != null);
}

test "executeSubAgentTool - get_agent tool with valid name" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("get_agent", "{\"agent_name\": \"code-reviewer\"}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Should get agent definition or error
    try std.testing.expect(result.output.len > 0);
}

test "executeSubAgentTool - remove_skill tool is available" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("remove_skill", "{\"skill_name\": \"nonexistent_skill_xyz\"}");
    var db = makeDummyDb();
    const session_id = "test-session";

    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Should get output (skill not found or success)
    try std.testing.expect(result.output.len > 0);
}

// ============================================================================
// Edge case tests
// ============================================================================

test "executeSubAgentTool - empty arguments" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("list_skills", "");
    var db = makeDummyDb();
    const session_id = "test-session";

    // Empty args should still work for tools that don't require args
    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    try std.testing.expect(result.output.len > 0);
}

test "executeSubAgentTool - text_replace tool with invalid input" {
    const allocator = std.testing.allocator;
    const tc = makeToolCall("text_replace", "{\"path\": \"nonexistent.zig\", \"old_str\": \"x\", \"new_str\": \"y\"}");
    var db = makeDummyDb();
    const session_id = "test-session";

    // Should execute and return error (file not found)
    const result = try handle_spawn_sub_agent.executeSubAgentTool(allocator, tc, &db, session_id);

    // Should contain some error indication
    try std.testing.expect(result.output.len > 0);
}

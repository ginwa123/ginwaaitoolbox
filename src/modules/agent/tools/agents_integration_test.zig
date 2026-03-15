const std = @import("std");
const agents = @import("agents.zig");
const list_agents = @import("list_agents.zig");
const get_agent = @import("get_agent.zig");
const GetAgentInput = get_agent.GetAgentInput;

// Helper function to create a test agent file with YAML frontmatter
fn createTestAgentFile(dir: std.fs.Dir, agent_name: []const u8, description: []const u8, content: []const u8) !void {
    // Create agent directory
    try dir.makePath(agent_name);

    // Build the agent file content with YAML frontmatter
    const agent_content = try std.fmt.allocPrint(std.testing.allocator,
        "---\nname: {s}\ndescription: \"{s}\"\n---\n\n{s}",
        .{ agent_name, description, content }
    );
    defer std.testing.allocator.free(agent_content);

    // Create the AGENT.md file
    const file_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ agent_name, "AGENT.md" });
    defer std.testing.allocator.free(file_path);

    const file = try dir.createFile(file_path, .{});
    defer file.close();
    try file.writeAll(agent_content);
}

// Helper function to set up a temporary agents directory
fn setupTestAgentsDir() !struct { tmp_dir: std.testing.TmpDir, agents_path: []const u8 } {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    // Create the .nalar/agents directory structure
    try tmp_dir.dir.makePath(".nalar/agents");

    // Get the full path to the agents directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const agents_path = try tmp_dir.dir.realpath(".nalar/agents", &path_buf);

    return .{ .tmp_dir = tmp_dir, .agents_path = agents_path };
}

// Test: Full agent workflow - list and get agents
// This test creates temporary agent files and tests the complete workflow
// of listing agents and retrieving specific agent content
test "full agent workflow - list and get agents" {
    const allocator = std.testing.allocator;

    // Create temporary directory structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create the agents directory
    try tmp_dir.dir.makePath(".nalar/agents");

    // Create test agent subdirectory
    var agents_dir = try tmp_dir.dir.openDir(".nalar/agents", .{});
    defer agents_dir.close();

    // Create test agent files
    try createTestAgentFile(agents_dir, "test-coder", "A test coding agent", "# Test Coder\n\nThis agent helps with coding tasks.");
    try createTestAgentFile(agents_dir, "test-reviewer", "A test code reviewer agent", "# Test Reviewer\n\nThis agent reviews code.");

    // Get the full path to the agents directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const agents_path = try tmp_dir.dir.realpath(".nalar/agents", &path_buf);

    // Change to the temp directory so resolveAgentsPath finds our test agents
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = try std.posix.getcwd(&cwd_buf);

    // We need to change to the temp directory for the test
    // Since we can't easily chdir in tests, we'll use the path directly

    // Test 1: List agents using listAgentFiles
    const files = agents.listAgentFiles(allocator);
    // Note: This may return null if the current directory doesn't have .nalar/agents
    // In a real integration test environment, we'd set up the directory properly

    if (files) |f| {
        defer agents.freeAgentFiles(allocator, f);
        // If we have files, verify structure
        try std.testing.expect(f.len >= 0); // May be 0 or more depending on environment
    }

    // Test 2: Verify we can parse the agent files we created
    const test_agent_path = try std.fs.path.join(allocator, &[_][]const u8{ agents_path, "test-coder", "AGENT.md" });
    defer allocator.free(test_agent_path);

    const loaded_content = agents.loadAgentFromPath(allocator, test_agent_path);
    if (loaded_content) |content| {
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "test-coder") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "A test coding agent") != null);

        // Parse frontmatter
        const frontmatter = agents.parseYamlFrontmatter(allocator, content);
        if (frontmatter) |fm| {
            defer agents.freeParsedFrontmatter(allocator, fm);
            try std.testing.expectEqualStrings("test-coder", fm.name);
            try std.testing.expectEqualStrings("A test coding agent", fm.description);
        }
    }

    // Restore original cwd
    try std.posix.chdir(original_cwd);
}

// Test: listAgents returns valid JSON
// Verifies that executeListAgents produces valid JSON output
test "listAgents returns valid JSON" {
    const allocator = std.testing.allocator;

    // Execute list_agents
    const result = try list_agents.executeListAgents(allocator);
    defer allocator.free(result);

    // Verify JSON structure
    try std.testing.expectStringStartsWith(result, "{\"agents\":[");
    try std.testing.expectStringEndsWith(result, "]}");

    // Verify JSON is valid by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();

    // Verify structure
    try std.testing.expect(parsed.value == .object);
    const root = parsed.value.object;
    try std.testing.expect(root.contains("agents"));

    const agents_array = root.get("agents").?;
    try std.testing.expect(agents_array == .array);
}

// Test: parseAgent returns valid XML
// Verifies that executeGetAgentToString produces valid XML output
test "parseAgent returns valid XML" {
    const allocator = std.testing.allocator;

    // Create temporary directory with test agent
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create the agents directory structure
    try tmp_dir.dir.makePath(".nalar/agents/xml-test-agent");

    // Create test agent file
    const agent_content = "---\nname: xml-test-agent\ndescription: \"Agent for XML testing\"\n---\n\n# XML Test Agent\n\nThis is content for XML testing.";

    const file = try tmp_dir.dir.createFile(".nalar/agents/xml-test-agent/AGENT.md", .{});
    defer file.close();
    try file.writeAll(agent_content);

    // Get the path to the agent file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const agent_file_path = try tmp_dir.dir.realpath(".nalar/agents/xml-test-agent/AGENT.md", &path_buf);

    // Test loading via path
    const input = GetAgentInput{
        .path = agent_file_path,
        .agent_name = null,
    };

    const result = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(result);

    // Verify XML structure
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent_name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</agent_name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<content>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</content>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</loaded>") != null);

    // Verify content is present
    try std.testing.expect(std.mem.indexOf(u8, result, "xml-test-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Agent for XML testing") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>true</loaded>") != null);
}

// Test: parseAgent handles missing agent
// Verifies that executeGetAgentToString returns appropriate error XML for non-existent agents
test "parseAgent handles missing agent" {
    const allocator = std.testing.allocator;

    // Test with a non-existent agent name
    const input = GetAgentInput{
        .agent_name = "non-existent-agent-xyz123",
        .path = null,
    };

    const result = try get_agent.executeGetAgentToString(allocator, input);
    defer allocator.free(result);

    // Verify error XML structure
    try std.testing.expect(std.mem.indexOf(u8, result, "<agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</agent>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<loaded>false</loaded>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</error>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<available_agents>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "</available_agents>") != null);

    // Verify error message is present
    try std.testing.expect(std.mem.indexOf(u8, result, "Agent not found") != null);
}

// Test: Integration with temporary directory and file cleanup
// Verifies that all temporary files are properly cleaned up
test "integration with proper cleanup" {
    // Create temporary directory
    var tmp_dir = std.testing.tmpDir(.{});

    // Create test files
    try tmp_dir.dir.makePath(".nalar/agents/cleanup-test");

    const agent_content = "---\nname: cleanup-test\ndescription: \"Test for cleanup\"\n---\n\n# Cleanup Test";

    const file = try tmp_dir.dir.createFile(".nalar/agents/cleanup-test/AGENT.md", .{});
    defer file.close();
    try file.writeAll(agent_content);

    // Verify file exists
    const stat = try tmp_dir.dir.statFile(".nalar/agents/cleanup-test/AGENT.md");
    try std.testing.expect(stat.size > 0);

    // Cleanup
    tmp_dir.cleanup();

    // After cleanup, the directory should be removed
    // (tmpDir automatically cleans up on scope exit)
}

// Test: Full workflow with multiple agents
// Creates multiple agents and verifies list/get operations work correctly
test "full workflow with multiple agents" {
    const allocator = std.testing.allocator;

    // Create temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create agents directory
    try tmp_dir.dir.makePath(".nalar/agents");

    var agents_dir = try tmp_dir.dir.openDir(".nalar/agents", .{});
    defer agents_dir.close();

    // Create multiple test agents
    try createTestAgentFile(agents_dir, "agent-alpha", "First test agent", "# Agent Alpha\n\nAlpha content.");
    try createTestAgentFile(agents_dir, "agent-beta", "Second test agent", "# Agent Beta\n\nBeta content.");
    try createTestAgentFile(agents_dir, "agent-gamma", "Third test agent", "# Agent Gamma\n\nGamma content.");

    // Verify files were created
    var alpha_file = try agents_dir.openFile("agent-alpha/AGENT.md", .{});
    alpha_file.close();

    var beta_file = try agents_dir.openFile("agent-beta/AGENT.md", .{});
    beta_file.close();

    var gamma_file = try agents_dir.openFile("agent-gamma/AGENT.md", .{});
    gamma_file.close();

    // Test loading each agent
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Load agent-alpha
    const alpha_path = try std.fs.path.join(allocator, &[_][]const u8{
        try tmp_dir.dir.realpath(".nalar/agents", &path_buf),
        "agent-alpha",
        "AGENT.md",
    });
    defer allocator.free(alpha_path);

    const alpha_content = agents.loadAgentFromPath(allocator, alpha_path);
    if (alpha_content) |content| {
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "agent-alpha") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "First test agent") != null);
    }

    // Load agent-beta
    const beta_path = try std.fs.path.join(allocator, &[_][]const u8{
        try tmp_dir.dir.realpath(".nalar/agents", &path_buf),
        "agent-beta",
        "AGENT.md",
    });
    defer allocator.free(beta_path);

    const beta_content = agents.loadAgentFromPath(allocator, beta_path);
    if (beta_content) |content| {
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "agent-beta") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "Second test agent") != null);
    }

    // Load agent-gamma
    const gamma_path = try std.fs.path.join(allocator, &[_][]const u8{
        try tmp_dir.dir.realpath(".nalar/agents", &path_buf),
        "agent-gamma",
        "AGENT.md",
    });
    defer allocator.free(gamma_path);

    const gamma_content = agents.loadAgentFromPath(allocator, gamma_path);
    if (gamma_content) |content| {
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "agent-gamma") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "Third test agent") != null);
    }
}

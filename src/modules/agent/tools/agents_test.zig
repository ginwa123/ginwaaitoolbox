const std = @import("std");
const agents = @import("agents.zig");

// Test: Constants are defined correctly
test "constants are defined" {
    // Verify constants exist and have reasonable values
    try std.testing.expect(agents.MAX_AGENT_SIZE > 0);
    try std.testing.expect(agents.MAX_AGENT_SIZE == 100 * 1024); // 100KB
    try std.testing.expectEqualStrings("nalar", agents.APP_NAME);
    try std.testing.expectEqualStrings(".nalar/agents", agents.LOCAL_AGENTS_DIR);
    try std.testing.expectEqualStrings("AGENT.md", agents.AGENT_FILE_NAME);
}

// Test: AgentInfo struct exists and can be instantiated
test "AgentInfo struct" {
    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-agent");
    defer allocator.free(name);
    const desc = try allocator.dupe(u8, "Test description");
    defer allocator.free(desc);

    const info = agents.AgentInfo{
        .name = name,
        .description = desc,
    };

    try std.testing.expectEqualStrings("test-agent", info.name);
    try std.testing.expectEqualStrings("Test description", info.description);
}

// Test: ParsedAgentFrontmatter struct exists
test "ParsedAgentFrontmatter struct" {
    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-agent");
    defer allocator.free(name);
    const desc = try allocator.dupe(u8, "Test description");
    defer allocator.free(desc);

    const fm = agents.ParsedAgentFrontmatter{
        .name = name,
        .description = desc,
    };

    try std.testing.expectEqualStrings("test-agent", fm.name);
    try std.testing.expectEqualStrings("Test description", fm.description);
}

// Test: parseYamlFrontmatter extracts name and description
test "parseYamlFrontmatter extracts metadata" {
    const allocator = std.testing.allocator;

    const content = "---\nname: test-agent\ndescription: \"A test agent for testing\"\n---\n# Test Agent\n\nThis is the agent content.\n";

    const result = agents.parseYamlFrontmatter(allocator, content) orelse {
        try std.testing.expect(false); // Should not be null
        return;
    };
    defer agents.freeParsedFrontmatter(allocator, result);

    try std.testing.expectEqualStrings("test-agent", result.name);
    try std.testing.expectEqualStrings("A test agent for testing", result.description);
}

// Test: parseYamlFrontmatter handles single quotes
test "parseYamlFrontmatter handles single quotes" {
    const allocator = std.testing.allocator;

    const content = "---\nname: 'test-agent'\ndescription: 'A test agent'\n---\n";

    const result = agents.parseYamlFrontmatter(allocator, content) orelse {
        try std.testing.expect(false);
        return;
    };
    defer agents.freeParsedFrontmatter(allocator, result);

    try std.testing.expectEqualStrings("test-agent", result.name);
    try std.testing.expectEqualStrings("A test agent", result.description);
}

// Test: parseYamlFrontmatter handles unquoted values
test "parseYamlFrontmatter handles unquoted values" {
    const allocator = std.testing.allocator;

    const content = "---\nname: test-agent\ndescription: Simple description\n---\n";

    const result = agents.parseYamlFrontmatter(allocator, content) orelse {
        try std.testing.expect(false);
        return;
    };
    defer agents.freeParsedFrontmatter(allocator, result);

    try std.testing.expectEqualStrings("test-agent", result.name);
    try std.testing.expectEqualStrings("Simple description", result.description);
}

// Test: parseYamlFrontmatter returns null for invalid content
test "parseYamlFrontmatter returns null for invalid content" {
    const allocator = std.testing.allocator;

    const content = "This is not valid frontmatter\n";

    const result = agents.parseYamlFrontmatter(allocator, content);
    try std.testing.expect(result == null);
}

// Test: parseYamlFrontmatter returns null when name is missing
test "parseYamlFrontmatter returns null when name missing" {
    const allocator = std.testing.allocator;

    const content = "---\ndescription: Just a description\n---\n";

    const result = agents.parseYamlFrontmatter(allocator, content);
    try std.testing.expect(result == null);
}

// Test: get_local_agents_path returns a valid path
test "get_local_agents_path returns path" {
    const allocator = std.testing.allocator;

    const path = agents.get_local_agents_path(allocator) orelse {
        // It's ok if cwd is not available in test environment
        return;
    };
    defer agents.free_agents_path(allocator, path);

    // Path should contain the local agents directory
    try std.testing.expect(std.mem.indexOf(u8, path, ".nalar/agents") != null);
}

// Test: get_global_agents_path returns a path
test "get_global_agents_path returns path" {
    const allocator = std.testing.allocator;

    const path = agents.get_global_agents_path(allocator) orelse {
        // It's ok if env vars are not set
        return;
    };
    defer agents.free_agents_path(allocator, path);

    // Path should not be empty
    try std.testing.expect(path.len > 0);
}

// Test: resolve_agents_path tries local first
test "resolve_agents_path resolution" {
    const allocator = std.testing.allocator;

    // This may return null if neither path exists
    const path = agents.resolve_agents_path(allocator);
    if (path) |p| {
        defer agents.free_agents_path(allocator, p);
        try std.testing.expect(p.len > 0);
    }
}

// Test: freeParsedFrontmatter works with empty strings
test "freeParsedFrontmatter handles empty strings" {
    const allocator = std.testing.allocator;

    // Create empty strings
    const name = try allocator.dupe(u8, "");
    const desc = try allocator.dupe(u8, "");

    const fm = agents.ParsedAgentFrontmatter{
        .name = name,
        .description = desc,
    };

    // Should not panic
    agents.freeParsedFrontmatter(allocator, fm);
}

// Test: free_agents_list works with empty list
test "free_agents_list handles empty list" {
    const allocator = std.testing.allocator;

    // Empty slice - just verify it doesn't panic
    const empty_list: []agents.AgentInfo = &[_]agents.AgentInfo{};

    // Should not panic
    agents.free_agents_list(allocator, empty_list);
}

// Test: free_agent_files works with empty list
test "free_agent_files handles empty list" {
    const allocator = std.testing.allocator;

    // Empty slice - just verify it doesn't panic
    const empty_files: [][]const u8 = &[_][]const u8{};

    // Should not panic
    agents.free_agent_files(allocator, empty_files);
}

// Test: free_agents_path works
test "free_agents_path frees path" {
    const allocator = std.testing.allocator;

    const path = try allocator.dupe(u8, "/test/path");

    // Should not panic
    agents.free_agents_path(allocator, path);
}

// Test: list_agent_files returns array (may be empty if no agents dir)
test "list_agent_files returns array" {
    const allocator = std.testing.allocator;

    const files = agents.list_agent_files(allocator) orelse {
        // It's ok if directory doesn't exist
        return;
    };
    defer agents.free_agent_files(allocator, files);

    // files is used in defer, no need for additional assertion
}

// Test: list_agents returns array (may be empty if no agents)
test "list_agents returns array" {
    const allocator = std.testing.allocator;

    const agents_list = agents.list_agents(allocator);
    defer agents.free_agents_list(allocator, agents_list);

    // agents_list is used in defer, no need for additional assertion
}

// Test: loadAgentFromPath with non-existent file returns null
test "loadAgentFromPath returns null for non-existent file" {
    const allocator = std.testing.allocator;

    const content = agents.loadAgentFromPath(allocator, "/nonexistent/path/AGENT.md");
    try std.testing.expect(content == null);
}

// Test: parse_agent with non-existent agent returns null
test "parse_agent returns null for non-existent agent" {
    const allocator = std.testing.allocator;

    const content = agents.parse_agent(allocator, "nonexistent-agent");
    try std.testing.expect(content == null);
}

// Integration test: Create a temporary agent file and verify it can be loaded
test "integration: create and load agent" {
    const allocator = std.testing.allocator;

    // Create a temporary directory structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create agent directory
    const agent_dir = "test-agent";
    var dir = tmp_dir.dir;
    try dir.makePath(agent_dir);

    // Create AGENT.md file
    const agent_content = "---\nname: test-agent\ndescription: A test agent for integration testing\n---\n# Test Agent\n\nThis is test content.\n";

    const agent_file = try dir.createFile("test-agent/AGENT.md", .{});
    defer agent_file.close();
    try agent_file.writeAll(agent_content);

    // Get the full path to the agent file
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const agent_path = try dir.realpath("test-agent/AGENT.md", &path_buf);

    // Load the agent content
    const loaded_content = agents.loadAgentFromPath(allocator, agent_path) orelse {
        try std.testing.expect(false); // Should load successfully
        return;
    };
    defer allocator.free(loaded_content);

    // Verify content contains expected text
    try std.testing.expect(std.mem.indexOf(u8, loaded_content, "test-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded_content, "integration testing") != null);

    // Parse frontmatter
    const frontmatter = agents.parseYamlFrontmatter(allocator, loaded_content) orelse {
        try std.testing.expect(false); // Should parse successfully
        return;
    };
    defer agents.freeParsedFrontmatter(allocator, frontmatter);

    try std.testing.expectEqualStrings("test-agent", frontmatter.name);
    try std.testing.expectEqualStrings("A test agent for integration testing", frontmatter.description);
}

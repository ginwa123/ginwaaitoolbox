const std = @import("std");
const add_agent = @import("add_agent.zig");
const AddAgentInput = add_agent.AddAgentInput;

test "AddAgentInput with all required fields" {
    const input = AddAgentInput{
        .name = "test-agent",
        .description = "A test agent for testing",
        .content = "# Test Agent\n\nThis is a test agent.",
    };
    
    try std.testing.expectEqualStrings("test-agent", input.name);
    try std.testing.expectEqualStrings("A test agent for testing", input.description);
    try std.testing.expectEqualStrings("# Test Agent\n\nThis is a test agent.", input.content);
}

test "AddAgentInput default create_with_dir is true" {
    const input = AddAgentInput{
        .name = "test-agent",
        .description = "Description",
        .content = "Content",
    };
    
    try std.testing.expect(input.create_with_dir == true);
}

test "AddAgentInput with create_with_dir set to false" {
    const input = AddAgentInput{
        .name = "test-agent",
        .description = "Description",
        .content = "Content",
        .create_with_dir = false,
    };
    
    try std.testing.expect(input.create_with_dir == false);
}

test "add_agent_tool has correct structure" {
    try std.testing.expectEqualStrings("function", add_agent.add_agent_tool.type);
    try std.testing.expectEqualStrings("add_agent", add_agent.add_agent_tool.function.name);
    try std.testing.expectEqualStrings("object", add_agent.add_agent_tool.function.parameters.type);
    try std.testing.expect(add_agent.add_agent_tool.function.parameters.properties.len > 0);
}

test "add_agent_tool has required properties" {
    const props = add_agent.add_agent_tool.function.parameters.properties;
    
    var has_name = false;
    var has_description = false;
    var has_content = false;
    
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "name")) has_name = true;
        if (std.mem.eql(u8, prop.name, "description")) has_description = true;
        if (std.mem.eql(u8, prop.name, "content")) has_content = true;
    }
    
    try std.testing.expect(has_name);
    try std.testing.expect(has_description);
    try std.testing.expect(has_content);
}

test "add_agent_tool has required fields marked as required" {
    const required = add_agent.add_agent_tool.function.parameters.required;
    
    var has_name = false;
    var has_description = false;
    var has_content = false;
    
    for (required) |req| {
        if (std.mem.eql(u8, req, "name")) has_name = true;
        if (std.mem.eql(u8, req, "description")) has_description = true;
        if (std.mem.eql(u8, req, "content")) has_content = true;
    }
    
    try std.testing.expect(has_name);
    try std.testing.expect(has_description);
    try std.testing.expect(has_content);
}

test "executeAddAgentToString returns error for empty name" {
    const allocator = std.testing.allocator;
    
    const input = AddAgentInput{
        .name = "",
        .description = "Description",
        .content = "Content",
    };
    
    const result = add_agent.executeAddAgentToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeAddAgentToString returns error for empty description" {
    const allocator = std.testing.allocator;
    
    const input = AddAgentInput{
        .name = "valid-name",
        .description = "",
        .content = "Content",
    };
    
    const result = add_agent.executeAddAgentToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeAddAgentToString returns error for empty content" {
    const allocator = std.testing.allocator;
    
    const input = AddAgentInput{
        .name = "valid-name",
        .description = "Description",
        .content = "",
    };
    
    const result = add_agent.executeAddAgentToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeAddAgentToString creates agent file with valid structure" {
    const allocator = std.testing.allocator;
    
    // Create a temporary directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // Get the realpath to temp directory
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    
    // Build expected path
    const agent_file_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, ".nalar", "agents", "test-agent", "AGENT.MD" });
    defer allocator.free(agent_file_path);
    
    // Change to temp directory
    try std.posix.chdir(tmp_path);
    
    // Create agent
    const input = AddAgentInput{
        .name = "test-agent",
        .description = "A test agent",
        .content = "# Test Agent\n\nThis agent was created by a test.",
    };
    
    const result = try add_agent.executeAddAgentToString(allocator, input);
    defer allocator.free(result);
    
    // Verify result contains success XML
    try std.testing.expect(std.mem.indexOf(u8, result, "<created>true</created>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "<path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test-agent") != null);
    
    // Verify file was created
    const file = try std.fs.openFileAbsolute(agent_file_path, .{});
    defer file.close();
    
    const stat = try file.stat();
    try std.testing.expect(stat.size > 0);
    
    // Read and verify content
    const content = try file.readToEndAlloc(allocator, stat.size + 1);
    defer allocator.free(content);
    
    try std.testing.expect(std.mem.indexOf(u8, content, "name: test-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "description: \"A test agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "# Test Agent") != null);
}

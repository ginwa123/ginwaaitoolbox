const std = @import("std");
const remove_agent = @import("remove_agent.zig");
const RemoveAgentInput = remove_agent.RemoveAgentInput;

test "RemoveAgentInput with required fields" {
    const input = RemoveAgentInput{
        .name = "test-agent",
        .session_id = "session-123",
    };
    
    try std.testing.expectEqualStrings("test-agent", input.name);
    try std.testing.expectEqualStrings("session-123", input.session_id);
}

test "remove_agent_tool has correct structure" {
    try std.testing.expectEqualStrings("function", remove_agent.remove_agent_tool.type);
    try std.testing.expectEqualStrings("remove_agent", remove_agent.remove_agent_tool.function.name);
    try std.testing.expectEqualStrings("object", remove_agent.remove_agent_tool.function.parameters.type);
    try std.testing.expect(remove_agent.remove_agent_tool.function.parameters.properties.len > 0);
}

test "remove_agent_tool has required properties" {
    const props = remove_agent.remove_agent_tool.function.parameters.properties;
    
    var has_name = false;
    var has_session_id = false;
    
    for (props) |prop| {
        if (std.mem.eql(u8, prop.name, "name")) has_name = true;
        if (std.mem.eql(u8, prop.name, "session_id")) has_session_id = true;
    }
    
    try std.testing.expect(has_name);
    try std.testing.expect(has_session_id);
}

test "remove_agent_tool has required fields marked as required" {
    const required = remove_agent.remove_agent_tool.function.parameters.required;
    
    var has_name = false;
    var has_session_id = false;
    
    for (required) |req| {
        if (std.mem.eql(u8, req, "name")) has_name = true;
        if (std.mem.eql(u8, req, "session_id")) has_session_id = true;
    }
    
    try std.testing.expect(has_name);
    try std.testing.expect(has_session_id);
}

test "executeRemoveAgentToString returns error for empty name" {
    const allocator = std.testing.allocator;
    
    const input = RemoveAgentInput{
        .name = "",
        .session_id = "session-123",
    };
    
    const result = remove_agent.executeRemoveAgentToString(allocator, input);
    try std.testing.expectError(error.InvalidInput, result);
}

test "executeRemoveAgentToString deletes agent file" {
    const allocator = std.testing.allocator;
    
    // Create temp directory
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    
    // Create agent directory and file
    const agent_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, ".nalar", "agents", "test-agent" });
    defer allocator.free(agent_dir_path);
    
    const agent_file_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir_path, "AGENT.MD" });
    defer allocator.free(agent_file_path);
    
    // Create the directory
    try std.fs.cwd().makePath(agent_dir_path);
    
    // Create agent file
    const file = try std.fs.createFileAbsolute(agent_file_path, .{});
    try file.writeAll("---\nname: test-agent\ndescription: \"Test agent\"\n---\n\n# Test Agent");
    file.close();
    
    // Change to temp directory
    try std.posix.chdir(tmp_path);
    
    // Delete the agent
    const input = RemoveAgentInput{
        .name = "test-agent",
        .session_id = "session-123",
    };
    
    const result = try remove_agent.executeRemoveAgentToString(allocator, input);
    defer allocator.free(result);
    
    // Verify success XML
    try std.testing.expect(std.mem.indexOf(u8, result, "<removed>true</removed>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test-agent") != null);
    
    // Verify directory is deleted - try to access should fail
    std.fs.cwd().access(agent_dir_path, .{}) catch {
        // This is expected - directory should not exist
        return;
    };
    // If we reach here, the directory still exists - fail
    try std.testing.expect(false);
}

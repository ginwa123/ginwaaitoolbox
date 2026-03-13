const std = @import("std");
const spawn_sub_agent = @import("spawn_sub_agent.zig");

test "spawnSubAgentTool exists and has correct name" {
    try std.testing.expectEqualStrings("spawn_sub_agent", spawn_sub_agent.spawnSubAgentTool.function.name);
}

test "parseSubAgents - valid JSON with two agents" {
    const allocator = std.testing.allocator;
    const json_input = 
        \\{"sub_agents": [
        \\  {"name": "agent1", "instruction": "search for X"},
        \\  {"name": "agent2", "instruction": "search for Y"}
        \\]}
    ;
    
    const result = try spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 2), result.sub_agents.len);
    try std.testing.expectEqualStrings("agent1", result.sub_agents[0].name);
    try std.testing.expectEqualStrings("search for X", result.sub_agents[0].instruction);
    try std.testing.expectEqualStrings("agent2", result.sub_agents[1].name);
    try std.testing.expectEqualStrings("search for Y", result.sub_agents[1].instruction);
}

test "parseSubAgents - single agent" {
    const allocator = std.testing.allocator;
    const json_input = 
        \\{"sub_agents": [
        \\  {"name": "worker", "instruction": "do the work"}
        \\]}
    ;
    
    const result = try spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 1), result.sub_agents.len);
    try std.testing.expectEqualStrings("worker", result.sub_agents[0].name);
    try std.testing.expectEqualStrings("do the work", result.sub_agents[0].instruction);
}

test "parseSubAgents - too many agents returns error" {
    const allocator = std.testing.allocator;
    // Use fewer agents in the JSON but set max lower to test error path
    const json_input = 
        \\{"sub_agents": [
        \\  {"name": "a1", "instruction": "i1"}
        \\]}
    ;
    
    const result = spawn_sub_agent.parseSubAgents(allocator, json_input, 0);
    try std.testing.expectError(error.TooManySubAgents, result);
}

test "parseSubAgents - empty returns error" {
    const allocator = std.testing.allocator;
    const json_input = 
        \\{"sub_agents": []}
    ;
    
    const result = spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    try std.testing.expectError(error.NoSubAgents, result);
}

test "parseSubAgents - missing name returns error" {
    const allocator = std.testing.allocator;
    const json_input = 
        \\{"sub_agents": [
        \\  {"instruction": "some task"}
        \\]}
    ;
    
    const result = spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    try std.testing.expectError(error.MissingSubAgentName, result);
}

test "parseSubAgents - missing instruction returns error" {
    const allocator = std.testing.allocator;
    const json_input = 
        \\{"sub_agents": [
        \\  {"name": "myname"}
        \\]}
    ;
    
    const result = spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    try std.testing.expectError(error.MissingSubAgentInstruction, result);
}

test "parseSubAgents - missing sub_agents field returns error" {
    const allocator = std.testing.allocator;
    const json_input = 
        \\{"other_field": "value"}
    ;
    
    const result = spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    try std.testing.expectError(error.MissingSubAgentsField, result);
}

test "parseSubAgents - LLM mistake: json_input as object (not string)" {
    const allocator = std.testing.allocator;
    // This is the format the LLM was generating incorrectly:
    // {"json_input": {"sub_agents": [...]}} instead of {"sub_agents": [...]}
    const json_input =
        \\{"json_input": {"sub_agents": [
        \\  {"name": "explore_apps", "instruction": "Explore src/apps", "tools": ["bash", "read_file"]},
        \\  {"name": "explore_modules", "instruction": "Explore modules/", "tools": ["bash"]}
        \\]}}
    ;

    const result = try spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.sub_agents.len);
    try std.testing.expectEqualStrings("explore_apps", result.sub_agents[0].name);
    try std.testing.expectEqualStrings("Explore src/apps", result.sub_agents[0].instruction);
    try std.testing.expectEqualStrings("explore_modules", result.sub_agents[1].name);
    try std.testing.expectEqualStrings("Explore modules/", result.sub_agents[1].instruction);

    // Check tools are parsed correctly
    try std.testing.expect(result.sub_agents[0].tools != null);
    try std.testing.expectEqual(@as(usize, 2), result.sub_agents[0].tools.?.len);
    try std.testing.expectEqualStrings("bash", result.sub_agents[0].tools.?[0]);
    try std.testing.expectEqualStrings("read_file", result.sub_agents[0].tools.?[1]);
}

test "parseSubAgents - correct format: json_input as string" {
    const allocator = std.testing.allocator;
    // This is the CORRECT format as defined in the tool schema:
    // {"json_input": "{\"sub_agents\": [...]}"}
    const json_input =
        \\{"json_input": "{\"sub_agents\": [{\"name\": \"test_agent\", \"instruction\": \"do something\", \"tools\": [\"bash\"]}]}"}
    ;

    const result = try spawn_sub_agent.parseSubAgents(allocator, json_input, 20);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.sub_agents.len);
    try std.testing.expectEqualStrings("test_agent", result.sub_agents[0].name);
    try std.testing.expectEqualStrings("do something", result.sub_agents[0].instruction);

    // Check tools are parsed correctly
    try std.testing.expect(result.sub_agents[0].tools != null);
    try std.testing.expectEqual(@as(usize, 1), result.sub_agents[0].tools.?.len);
    try std.testing.expectEqualStrings("bash", result.sub_agents[0].tools.?[0]);
}

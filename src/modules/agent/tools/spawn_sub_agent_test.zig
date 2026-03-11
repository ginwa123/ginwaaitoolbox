const std = @import("std");
const spawn_sub_agent = @import("spawn_sub_agent.zig");

test "spawnSubAgentTool exists and has correct name" {
    try std.testing.expectEqualStrings("spawn_sub_agent", spawn_sub_agent.spawnSubAgentTool.function.name);
}

test "parseSubAgents - valid XML with two agents" {
    const allocator = std.testing.allocator;
    const xml_input = "<sub_agents>\n  <sub_agent>\n    <name>agent1</name>\n    <instruction>search for X</instruction>\n  </sub_agent>\n  <sub_agent>\n    <name>agent2</name>\n    <instruction>search for Y</instruction>\n  </sub_agent>\n</sub_agents>";
    
    const result = try spawn_sub_agent.parseSubAgents(allocator, xml_input, 20);
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 2), result.sub_agents.len);
    try std.testing.expectEqualStrings("agent1", result.sub_agents[0].name);
    try std.testing.expectEqualStrings("search for X", result.sub_agents[0].instruction);
    try std.testing.expectEqualStrings("agent2", result.sub_agents[1].name);
    try std.testing.expectEqualStrings("search for Y", result.sub_agents[1].instruction);
}

test "parseSubAgents - single agent" {
    const allocator = std.testing.allocator;
    const xml_input = "<sub_agents>\n  <sub_agent>\n    <name>worker</name>\n    <instruction>do the work</instruction>\n  </sub_agent>\n</sub_agents>";
    
    const result = try spawn_sub_agent.parseSubAgents(allocator, xml_input, 20);
    defer result.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 1), result.sub_agents.len);
    try std.testing.expectEqualStrings("worker", result.sub_agents[0].name);
    try std.testing.expectEqualStrings("do the work", result.sub_agents[0].instruction);
}

test "parseSubAgents - too many agents returns error" {
    const allocator = std.testing.allocator;
    // Use fewer agents in the XML but set max lower to test error path
    const xml_input = "<sub_agents><sub_agent><name>a1</name><instruction>i1</instruction></sub_agent></sub_agents>";
    
    const result = spawn_sub_agent.parseSubAgents(allocator, xml_input, 0);
    try std.testing.expectError(error.TooManySubAgents, result);
}

test "parseSubAgents - empty returns error" {
    const allocator = std.testing.allocator;
    const xml_input = "<sub_agents></sub_agents>";
    
    const result = spawn_sub_agent.parseSubAgents(allocator, xml_input, 20);
    try std.testing.expectError(error.NoSubAgents, result);
}

test "parseSubAgents - missing name returns error" {
    const allocator = std.testing.allocator;
    const xml_input = "<sub_agents>\n  <sub_agent>\n    <instruction>some task</instruction>\n  </sub_agent>\n</sub_agents>";
    
    const result = spawn_sub_agent.parseSubAgents(allocator, xml_input, 20);
    try std.testing.expectError(error.MissingSubAgentName, result);
}

test "parseSubAgents - missing instruction returns error" {
    const allocator = std.testing.allocator;
    const xml_input = "<sub_agents>\n  <sub_agent>\n    <name>myname</name>\n  </sub_agent>\n</sub_agents>";
    
    const result = spawn_sub_agent.parseSubAgents(allocator, xml_input, 20);
    try std.testing.expectError(error.MissingSubAgentInstruction, result);
}

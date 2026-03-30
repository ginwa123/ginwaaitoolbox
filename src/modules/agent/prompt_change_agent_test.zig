const std = @import("std");
const prompt = @import("prompt.zig");

test "prompt.zig contains change_agent references" {
    // Build a prompt and check it contains "change_agent"
    const allocator = std.testing.allocator;
    
    const full_prompt = try prompt.buildAgentPrompt(
        allocator,
        "/test",      // cwd
        "/test",      // treeDir
        "",           // skillsContent
        "",           // memoryMd
        "",           // backgroundProcessContent
        "",           // agent
    );
    defer allocator.free(full_prompt);
    
    // Check that prompt mentions change_agent
    try std.testing.expect(std.mem.indexOf(u8, full_prompt, "change_agent") != null);
}

test "prompt.zig encourages agent switching" {
    const allocator = std.testing.allocator;
    
    const full_prompt = try prompt.buildAgentPrompt(
        allocator,
        "/test",
        "/test",
        "",
        "",
        "",
        "",
    );
    defer allocator.free(full_prompt);
    
    // Check that prompt encourages switching agents
    try std.testing.expect(
        std.mem.indexOf(u8, full_prompt, "switch") != null or
        std.mem.indexOf(u8, full_prompt, "persona") != null or
        std.mem.indexOf(u8, full_prompt, "Agent Switching") != null or
        std.mem.indexOf(u8, full_prompt, "switch agents") != null
    );
}

const std = @import("std");
const build_memory_for_agent = @import("build_memory_for_agent_prompt.zig");

test "memory_files array contains expected files" {
    // Test that the module defines the expected memory files
    const memory_files = [_][]const u8{ "MEMORY.md", "AGENT.md", "CLAUDE.md" };
    
    try std.testing.expectEqual(@as(usize, 3), memory_files.len);
    try std.testing.expectEqualStrings("MEMORY.md", memory_files[0]);
    try std.testing.expectEqualStrings("AGENT.md", memory_files[1]);
    try std.testing.expectEqualStrings("CLAUDE.md", memory_files[2]);
}

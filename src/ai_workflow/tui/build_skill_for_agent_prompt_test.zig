const std = @import("std");

test "build_skill_for_agent_prompt module imports" {
    // Test that the module can be imported without errors
    const build_skill = @import("build_skill_for_agent_prompt.zig");
    _ = build_skill;
    try std.testing.expect(true);
}

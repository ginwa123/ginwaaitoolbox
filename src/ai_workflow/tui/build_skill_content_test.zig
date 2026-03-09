const std = @import("std");
const testing = std.testing;
const build_skill_content = @import("build_skill_content.zig");

test "build_skill_content module exists" {
    // This module depends on database, so we just verify it compiles
    _ = build_skill_content;
}

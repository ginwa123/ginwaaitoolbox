const std = @import("std");
const testing = std.testing;
const save_skill = @import("save_skill.zig");

test "save_skill module exists" {
    // This module depends on database, so we just verify it compiles
    _ = save_skill;
}

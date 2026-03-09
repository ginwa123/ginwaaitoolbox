const std = @import("std");
const testing = std.testing;
const send_skill = @import("send_skill.zig");

test "send_skill module exists" {
    // This module depends on database, so we just verify it compiles
    _ = send_skill;
}

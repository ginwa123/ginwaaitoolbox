const std = @import("std");
const testing = std.testing;
const send_user_choice = @import("send_user_choice.zig");

test "send_user_choice module exists" {
    // This module depends on logger, so we just verify it compiles
    _ = send_user_choice;
}

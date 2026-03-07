const std = @import("std");
const save_message = @import("save_message.zig");

test "save_message module exists" {
    // This module depends on database, so we just verify it compiles
    _ = save_message;
}

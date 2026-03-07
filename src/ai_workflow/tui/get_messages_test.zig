const std = @import("std");
const get_messages = @import("get_messages.zig");

test "get_messages module exists" {
    // This module depends on database, so we just verify it compiles
    _ = get_messages;
}

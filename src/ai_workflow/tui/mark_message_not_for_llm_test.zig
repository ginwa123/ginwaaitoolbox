const std = @import("std");
const mark_message = @import("mark_message_not_for_llm.zig");

test "mark_message_not_for_llm module exists" {
    // This module depends on database, so we just verify it compiles
    _ = mark_message;
}

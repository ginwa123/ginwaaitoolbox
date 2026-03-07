const std = @import("std");
const handle_tool = @import("handle_tool.zig");

test "handle_tool module exists" {
    // This module has complex dependencies, so we just verify it compiles
    _ = handle_tool;
}

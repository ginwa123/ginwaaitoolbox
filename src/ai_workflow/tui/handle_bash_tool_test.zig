const std = @import("std");
const handle_bash = @import("handle_bash_tool.zig");

test "handle_bash_tool module exists" {
    // This module has complex dependencies, so we just verify it compiles
    _ = handle_bash;
}

const std = @import("std");
const handle_read_file = @import("handle_read_file_tool.zig");

test "handle_read_file_tool module exists" {
    // This module has complex dependencies, so we just verify it compiles
    _ = handle_read_file;
}

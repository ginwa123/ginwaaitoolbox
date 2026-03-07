const std = @import("std");
const handle_filter = @import("handle_content_filter.zig");

test "handle_content_filter module exists" {
    // This module has complex dependencies, so we just verify it compiles
    _ = handle_filter;
}

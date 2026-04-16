const std = @import("std");
const tool_registry = @import("tool_registry.zig");

test "tool_registry execBash function exists" {
    // This module has complex dependencies, so we just verify it compiles
    _ = tool_registry.execBash;
}

const std = @import("std");
const testing = std.testing;
const handle_list_skills_tool = @import("handle_list_skills_tool.zig");

test "handle_list_skills_tool module exists" {
    // This module depends on database and logger, so we just verify it compiles
    _ = handle_list_skills_tool;
}

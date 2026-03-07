const std = @import("std");
const send_tool_result = @import("send_tool_result.zig");

test "send_tool_result module exists" {
    // This module has logger dependencies, so we just verify it compiles
    _ = send_tool_result;
}

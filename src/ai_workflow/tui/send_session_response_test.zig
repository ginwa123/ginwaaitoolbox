const std = @import("std");
const testing = std.testing;
const send_session_response = @import("send_session_response.zig");

test "send_session_response module exists" {
    // This module depends on tui_workflow, so we just verify it compiles
    _ = send_session_response;
}

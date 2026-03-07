const std = @import("std");
const get_agent = @import("get_current_agent_by_session_id.zig");

test "get_current_agent_by_session_id module exists" {
    // This module depends on database, so we just verify it compiles
    _ = get_agent;
}

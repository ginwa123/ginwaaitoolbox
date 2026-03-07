const std = @import("std");
const get_session = @import("get_session_by_dir.zig");

test "get_session_by_dir module exists" {
    // This module depends on database, so we just verify it compiles
    _ = get_session;
}

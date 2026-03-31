const std = @import("std");
const session_table = @import("session_table.zig");
const SessionInfo = session_table.SessionInfo;

// Re-export inline tests from session_table.zig by importing it
// The inline tests in session_table.zig will be discovered when this module is imported

test "session_table module loads" {
    _ = session_table;
    try std.testing.expect(true);
}

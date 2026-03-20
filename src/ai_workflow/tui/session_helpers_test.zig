const std = @import("std");

test "session_helpers module imports" {
    // Test that the module can be imported without errors
    const session_helpers = @import("session_helpers.zig");
    _ = session_helpers;
    try std.testing.expect(true);
}

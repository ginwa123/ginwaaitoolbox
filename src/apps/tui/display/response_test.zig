const std = @import("std");

test "response module imports" {
    // Test that the module can be imported without errors
    const response = @import("response.zig");
    _ = response;
    try std.testing.expect(true);
}

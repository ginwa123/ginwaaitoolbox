const std = @import("std");

test "config module imports" {
    // Test that the config module can be imported
    const config = @import("config.zig");
    _ = config;
    try std.testing.expect(true);
}

const std = @import("std");

test "sqlite module imports" {
    // Test that the sqlite module can be imported
    const sqlite = @import("Sqlite.zig");
    _ = sqlite;
    try std.testing.expect(true);
}

const std = @import("std");

test "migration module imports" {
    // Test that the migration module can be imported
    const migration = @import("migration.zig");
    _ = migration;
    try std.testing.expect(true);
}

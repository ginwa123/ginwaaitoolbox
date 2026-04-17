const std = @import("std");

test "migrations module imports" {
    // Test that the migrations module can be imported
    const migrations = @import("Migrations.zig");
    _ = migrations;
    try std.testing.expect(true);
}

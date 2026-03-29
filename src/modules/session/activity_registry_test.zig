const std = @import("std");
const activity_registry = @import("activity_registry.zig");

test "ActivityRegistry struct exists" {
    const allocator = std.testing.allocator;
    var registry = activity_registry.ActivityRegistry.init(allocator);
    defer registry.deinit();
}

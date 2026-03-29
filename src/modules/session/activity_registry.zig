const std = @import("std");

pub const ActivityRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(*std.atomic.Value(usize)),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(*std.atomic.Value(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

test {
    _ = @import("activity_registry_test.zig");
}

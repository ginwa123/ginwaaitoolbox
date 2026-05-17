const std = @import("std");

pub const EventBus = struct {
    const Self = @This();

    const Callback = struct {
        ptr: *const anyopaque,
    };

    name: []const u8,
    alloc: std.mem.Allocator,
    listeners: std.StringHashMapUnmanaged(Callback),

    pub fn init(name: []const u8, alloc: std.mem.Allocator) Self {
        return .{
            .name = name,
            .alloc = alloc,
            .listeners = .{},
        };
    }

    pub fn subscribe(self: *Self, comptime T: type, id: []const u8, callback: *const fn (T) void) !void {
        const owned_id = try self.alloc.dupe(u8, id); // ✅ own the bytes
        const result = try self.listeners.getOrPut(self.alloc, owned_id);
        if (result.found_existing) {
            self.alloc.free(owned_id); // ✅ already have this key, discard duplicate
        }
        result.value_ptr.* = .{ .ptr = @ptrCast(callback) };
    }

    pub fn unsubscribe(self: *Self, id: []const u8) void {
        if (self.listeners.fetchRemove(id)) |entry| {
            self.alloc.free(entry.key); // ✅ free owned key bytes
        }
    }

    pub fn deinit(self: *Self) void {
        // ✅ free all owned keys before deiniting the map
        var it = self.listeners.keyIterator();
        while (it.next()) |key| {
            self.alloc.free(key.*);
        }
        self.listeners.deinit(self.alloc);
    }
    pub fn emit(self: *Self, comptime T: type, id: []const u8, data: T) void {
        if (self.listeners.get(id)) |cb| {
            const typed_fn: *const fn (T) void = @ptrCast(@alignCast(cb.ptr));
            typed_fn(data);
        } else {}
    }
};

const std = @import("std");

pub const EventBus = struct {
    const Self = @This();

    const Callback = struct {
        ptr: *const anyopaque,
        call: *const fn (ptr: *const anyopaque, data: *const anyopaque) void,
    };

    name: []const u8,
    alloc: std.mem.Allocator,
    // 0.15/0.16: StringHashMap is now "unmanaged" by default;
    // use StringHashMapUnmanaged and pass alloc explicitly to each call
    listeners: std.StringHashMapUnmanaged(Callback),

    pub fn init(name: []const u8, alloc: std.mem.Allocator) Self {
        return .{
            .name = name,
            .alloc = alloc,
            .listeners = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.listeners.deinit(self.alloc);
    }

    pub fn subscribe(self: *Self, comptime T: type, id: []const u8, callback: *const fn (T) void) !void {
        const wrapper = struct {
            fn call(ptr: *const anyopaque, data: *const anyopaque) void {
                const typed_fn: *const fn (T) void = @ptrCast(@alignCast(ptr));
                const typed_data: *const T = @ptrCast(@alignCast(data));
                typed_fn(typed_data.*);
            }
        };

        try self.listeners.put(self.alloc, id, .{
            .ptr = @ptrCast(callback),
            .call = wrapper.call,
        });
    }

    pub fn unsubscribe(self: *Self, id: []const u8) void {
        _ = self.listeners.remove(id);
    }

    pub fn emit(self: *const Self, comptime T: type, id: []const u8, data: T) void {
        if (self.listeners.get(id)) |cb| {
            cb.call(cb.ptr, @ptrCast(&data));
        }
    }
};

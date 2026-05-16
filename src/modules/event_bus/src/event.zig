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

    pub fn deinit(self: *Self) void {
        self.listeners.deinit(self.alloc);
    }

    pub fn subscribe(self: *Self, comptime T: type, id: []const u8, callback: *const fn (T) void) !void {
        const unused_type = T;
        _ = unused_type;
        std.debug.print("EVENT_BUS: subscribe type={s} id={s}\n", .{ @typeName(T), id });
        try self.listeners.put(self.alloc, id, .{
            .ptr = @ptrCast(callback),
        });
    }

    pub fn unsubscribe(self: *Self, id: []const u8) void {
        std.debug.print("EVENT_BUS: unsubscribe id={s}\n", .{id});
        _ = self.listeners.remove(id);
    }

    pub fn emit(self: *Self, comptime T: type, id: []const u8, data: T) void {
        std.debug.print("EVENT_BUS: emit type={s} id={s} listeners={d}\n", .{ @typeName(T), id, self.listeners.count() });
        if (self.listeners.get(id)) |cb| {
            std.debug.print("EVENT_BUS: found listener, calling\n", .{});
            const typed_fn: *const fn (T) void = @ptrCast(@alignCast(cb.ptr));
            typed_fn(data);
        } else {
            std.debug.print("EVENT_BUS: no listener found for id={s}\n", .{id});
        }
    }
};

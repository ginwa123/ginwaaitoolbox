const std = @import("std");

pub const EventBus = struct {
    const Self = @This();

    const Callback = struct {
        ptr: *const anyopaque,
    };

    name: []const u8,
    alloc: std.mem.Allocator,
    listeners: std.StringHashMapUnmanaged(Callback),
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    /// Caller must ensure `name` outlives this EventBus,
    /// or dupe it before passing.
    pub fn init(name: []const u8, alloc: std.mem.Allocator, io: std.Io) Self {
        return .{ .name = name, .alloc = alloc, .listeners = .{}, .mutex = .init, .io = io };
    }

    pub fn subscribe(self: *Self, comptime T: type, id: []const u8, callback: *const fn (T) void) !void {
        const owned_id = try self.alloc.dupe(u8, id);
        errdefer self.alloc.free(owned_id); // free if getOrPut fails
        //
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const result = try self.listeners.getOrPut(self.alloc, owned_id);
        if (result.found_existing) {
            self.alloc.free(owned_id); // key already stored, discard duplicate
        }
        // Last-writer-wins: replaces any existing callback for this id
        result.value_ptr.* = .{ .ptr = @ptrCast(callback) };
    }

    pub fn unsubscribe(self: *Self, id: []const u8) void {
        self.mutex.lock(self.io) catch unreachable;
        defer self.mutex.unlock(self.io);

        if (self.listeners.fetchRemove(id)) |entry| {
            self.alloc.free(entry.key);
        }
    }

    pub fn emit(self: *Self, comptime T: type, id: []const u8, data: T) void {
        self.mutex.lock(self.io) catch unreachable;
        defer self.mutex.unlock(self.io);

        if (self.listeners.get(id)) |cb| {
            const typed_fn: *const fn (T) void = @ptrCast(@alignCast(cb.ptr));
            typed_fn(data);
        }
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock(self.io) catch unreachable;
        defer self.mutex.unlock(self.io);

        var it = self.listeners.keyIterator();
        while (it.next()) |key| {
            self.alloc.free(key.*);
        }
        self.listeners.deinit(self.alloc);
    }
};

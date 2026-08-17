const std = @import("std");

pub const ActiveLoops = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    set: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) ActiveLoops {
        return .{
            .set = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ActiveLoops, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.set.deinit();
    }

    // Returns true if inserted (caller owns the loop), false if already running
    pub fn tryInsert(self: *ActiveLoops, io: std.Io, session_id: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const result = self.set.getOrPut(session_id) catch return false;
        if (result.found_existing) return false;
        return true;
    }

    pub fn remove(self: *ActiveLoops, io: std.Io, session_id: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = self.set.remove(session_id);
    }

    pub fn contains(self: *ActiveLoops, io: std.Io, session_id: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.set.contains(session_id);
    }
};
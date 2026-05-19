const std = @import("std");

pub const GilvecDb = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !GilvecDb {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
        };
    }

    fn createIndex(dimension: usize, metric: []const u8) void {
        _ = dimension;
        _ = metric;
    }

    fn writeFile() void {

    }

    fn readFile() void {

    }


    fn semanticSearch() void {

    }


};

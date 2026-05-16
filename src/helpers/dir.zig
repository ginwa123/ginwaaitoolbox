const std = @import("std");


/// Helper to get nalar data directory (~/local/share/nalar/data/apps)
pub fn getDataAppsDir(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) ![]u8 {
    _ = io;
    const home = environment.get("HOME") orelse {
        return error.HomeNotFound;
    };
    return std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".local",
        "share",
        "nalar",
        "data",
        "apps",
    });
}

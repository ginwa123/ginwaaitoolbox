const std = @import("std");
const Io = std.Io;

pub fn getDbPath(allocator: std.mem.Allocator, io: std.Io, environment: *std.process.Environ.Map) ![:0]const u8 {
    const home = environment.get("HOME") orelse {
        std.log.err("Failed to get HOME environment variable", .{});
        return error.FailedToGetHome;
    };

    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "nalar",
    });
    defer allocator.free(config_dir);

    Io.Dir.createDirAbsolute(io, config_dir, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err("Failed to create config directory: {s}", .{config_dir});
            return err;
        }
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    return try allocator.dupeZ(u8, db_path);
}

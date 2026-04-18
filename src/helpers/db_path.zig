const std = @import("std");

pub fn getDbPath(allocator: std.mem.Allocator) ![:0]const u8 {
    const home = std.posix.getenv("HOME") orelse {
        std.log.err("HOME environment variable not set", .{});
        return error.HomeNotFound;
    };

    // Build the config directory path: ~/.config/nalar
    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "nalar",
    });
    defer allocator.free(config_dir);

    // Create the directory if it doesn't exist (makePath creates all parent directories too)
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.log.err("Failed to create config directory: {s}", .{config_dir});
            return err;
        }
    };

    // Build the full database path
    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    // Return as null-terminated string (required by sqlite init)
    return try allocator.dupeZ(u8, db_path);
}
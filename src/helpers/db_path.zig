const std = @import("std");
const Io = std.Io;

/// Resolve `~/.config/nalar/agent.db`, creating the directory tree with
/// `mkdir -p` semantics if it does not yet exist.
///
/// On a fresh `$HOME` (a brand-new user's first run, or a CI runner with
/// an isolated tempdir as `$HOME`), neither `.config` nor `nalar` exists.
/// The previous implementation called `Dir.createDirAbsolute` which only
/// creates the FINAL path component — `mkdir(/$HOME/.config/nalar)` returns
/// ENOENT if `/$HOME/.config` does not yet exist. The fix is to open
/// `$HOME` as a `Dir` and call `Dir.createDirPath` which walks the
/// components and creates each one (true `mkdir -p` semantics).
///
/// Cross-platform note: the `~/.config/nalar/` path is what the rest of
/// the nalar codebase already uses for `agent.db`. On macOS, `Config.zig`
/// stores `config.json` under `$HOME/Library/Application Support/nalar/`
/// per platform convention, but the DB lives in `~/.config/nalar/` on ALL
/// platforms (this is the project's established convention — see
/// `helpers.db_path.getDbPath` callers in `main.zig:60`).
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

    // mkdir -p semantics: open HOME as a Dir and createDirPath the rest.
    // If the directory already exists (e.g. when LlmConfig.init's
    // `writeDefaultConfig` ran first and created `$HOME/.config/nalar`
    // via `createDirPath`), this is a no-op — `createDirPath`
    // returns Ok when the leaf already exists.
    var home_dir = Io.Dir.openDirAbsolute(io, home, .{}) catch |err| {
        std.log.err("Failed to open HOME directory {s}: {s}", .{ home, @errorName(err) });
        return err;
    };
    defer home_dir.close(io);
    home_dir.createDirPath(io, ".config/nalar") catch |err| {
        std.log.err("Failed to create config directory {s}: {s}", .{ config_dir, @errorName(err) });
        return err;
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);

    return try allocator.dupeZ(u8, db_path);
}

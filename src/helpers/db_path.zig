const std = @import("std");
const Io = std.Io;

/// Resolve `~/.config/pabrik/agent.db`, creating the directory tree with
/// `mkdir -p` semantics if it does not yet exist.
///
/// On a fresh `$HOME` (a brand-new user's first run, or a CI runner with
/// an isolated tempdir as `$HOME`), neither `.config` nor `pabrik` exists.
/// The previous implementation called `Dir.createDirAbsolute` which only
/// creates the FINAL path component — `mkdir(/$HOME/.config/pabrik)` returns
/// ENOENT if `/$HOME/.config` does not yet exist. The fix is to open
/// `$HOME` as a `Dir` and call `Dir.createDirPath` which walks the
/// components and creates each one (true `mkdir -p` semantics).
///
/// Cross-platform note: the `~/.config/pabrik/` path is what the rest of
/// the pabrik codebase already uses for `agent.db`. On macOS, `Config.zig`
/// stores `config.json` under `$HOME/Library/Application Support/pabrik/`
/// per platform convention, but the DB lives in `~/.config/pabrik/` on ALL
/// platforms (this is the project's established convention — see
/// `helpers.db_path.getDbPath` callers in `main.zig:60`).
pub fn getDbPath(allocator: std.mem.Allocator, io: std.Io, environment: *std.process.Environ.Map) ![:0]const u8 {
    // On POSIX systems, the canonical user-home env var is `HOME`. On
    // Windows, Git Bash sets `HOME` (typically to %USERPROFILE%), so
    // the POSIX path covers most cases — including the CI smoke test,
    // which runs inside Git Bash on windows-latest runners. As a
    // safety net for native-Windows invocations (where `HOME` may
    // not be set), fall back to `USERPROFILE` (Windows' canonical
    // user-home variable). Only used if HOME is missing or empty.
    const home = blk: {
        if (environment.get("HOME")) |h| {
            if (h.len > 0) break :blk h;
        }
        if (environment.get("USERPROFILE")) |u| {
            if (u.len > 0) break :blk u;
        }
        std.log.err("Failed to get HOME/USERPROFILE environment variable", .{});
        return error.FailedToGetHome;
    };

    // `home` is fed to `openDirAbsolute` below, which ASSERTS the path is
    // absolute and ABORTS the whole process (Debug/ReleaseSafe) instead of
    // returning an error — a relative HOME/USERPROFILE would make pabrik
    // un-startable with no actionable message.
    if (!std.fs.path.isAbsolute(home)) {
        std.log.err("HOME/USERPROFILE is not an absolute path: {s}", .{home});
        return error.FailedToGetHome;
    }

    const config_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        "pabrik",
    });
    defer allocator.free(config_dir);

    // mkdir -p semantics: open HOME as a Dir and createDirPath the rest.
    // If the directory already exists (e.g. when LlmConfig.init's
    // `writeDefaultConfig` ran first and created `$HOME/.config/pabrik`
    // via `createDirPath`), this is a no-op — `createDirPath`
    // returns Ok when the leaf already exists.
    var home_dir = Io.Dir.openDirAbsolute(io, home, .{}) catch |err| {
        std.log.err("Failed to open HOME directory {s}: {s}", .{ home, @errorName(err) });
        return err;
    };
    defer home_dir.close(io);
    home_dir.createDirPath(io, ".config/pabrik") catch |err| {
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

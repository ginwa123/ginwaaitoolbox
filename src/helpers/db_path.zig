const std = @import("std");
const Io = std.Io;
const brand = @import("brand_paths.zig");

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

    // The database is the one thing a rebrand cannot recreate: every session,
    // workspace, kanban card and credential lives in it. An install that
    // predates the rename has `agent.db` under the legacy directory name, so
    // prefer the new directory only once it exists — otherwise the upgraded
    // app would start with an empty database and silently orphan the old one.
    const current_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        brand.app_name,
    });
    const legacy_dir = try std.fs.path.join(allocator, &[_][]const u8{
        home,
        ".config",
        brand.legacy_app_name,
    });
    const current_db = try std.fs.path.join(allocator, &[_][]const u8{ current_dir, "agent.db" });
    const legacy_db = try std.fs.path.join(allocator, &[_][]const u8{ legacy_dir, "agent.db" });
    const use_legacy = !brand.exists(current_db) and brand.exists(legacy_db);
    const config_dir = if (use_legacy) legacy_dir else current_dir;
    defer allocator.free(current_dir);
    defer allocator.free(legacy_dir);

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
    home_dir.createDirPath(io, ".config/" ++ brand.app_name) catch |err| {
        std.log.err("Failed to create config directory {s}: {s}", .{ config_dir, @errorName(err) });
        return err;
    };

    const db_path = try std.fs.path.join(allocator, &[_][]const u8{
        config_dir,
        "agent.db",
    });
    defer allocator.free(db_path);
    defer allocator.free(current_db);
    defer allocator.free(legacy_db);

    return try allocator.dupeZ(u8, db_path);
}

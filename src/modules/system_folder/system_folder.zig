//! System folder path utilities
//! 
//! Provides utilities for resolving paths relative to home directory.

const std = @import("std");
const builtin = @import("builtin");

/// Error set for system folder operations
pub const SystemFolderError = error{
    HomeNotFound,
    OutOfMemory,
    InvalidPath,
    AccessDenied,
    NotDirectory,
};

/// Directory entry for folder listing
pub const FolderEntry = struct {
    name: []const u8,
    path: []const u8,
    is_directory: bool,
    is_symlink: bool,
};

/// Namespace containing system folder utilities
pub const SystemFolder = struct {
    /// Get the relative path from home directory
    /// 
    /// If `full_path` starts with `home`, returns the portion after home.
    /// Otherwise, returns the original `full_path` unchanged.
    /// 
    /// Returns "/" if path equals home exactly.
    pub fn getRelativePathFromHome(allocator: std.mem.Allocator, full_path: []const u8, home: []const u8) SystemFolderError![]u8 {
        // Normalize home path (remove trailing slash or backslash).
        // Windows homes look like `C:\Users\ginwa` (or `C:/Users/ginwa`
        // under Git Bash) — strip one trailing separator of either kind.
        const normalized_home = if (home.len > 0 and (home[home.len - 1] == '/' or home[home.len - 1] == '\\'))
            home[0..home.len - 1]
        else
            home;

        // Normalize full_path to remove trailing slash/backslash (but keep
        // filesystem roots like `/`, `C:\`, `C:/` intact).
        const normalized_path = if (full_path.len > 1 and (full_path[full_path.len - 1] == '/' or full_path[full_path.len - 1] == '\\'))
            full_path[0..full_path.len - 1]
        else
            full_path;
        
        // Check if full_path starts with home
        if (!std.mem.startsWith(u8, normalized_path, normalized_home)) {
            // Path doesn't start with home, return absolute path unchanged
            return allocator.dupe(u8, full_path);
        }
        
        // Check if path equals home exactly
        const after_home = normalized_path[normalized_home.len..];
        
        if (after_home.len == 0) {
            // Path equals home exactly
            return allocator.dupe(u8, "/");
        }
        
        // Remove leading slash/backslash from the remainder
        // (Windows remainder looks like `\Documents` when home is
        // `C:\Users\ginwa`).
        const remainder = if (after_home.len > 0 and (after_home[0] == '/' or after_home[0] == '\\'))
            after_home[1..]
        else
            after_home;
        
        // Build result with leading slash
        const result = try std.fmt.allocPrint(allocator, "/{s}", .{remainder});
        return result;
    }
    
    /// Get home directory from environment
    ///
    /// On POSIX the canonical var is `HOME`. On native Windows
    /// (cmd/pwsh — NOT Git Bash, which sets HOME to %USERPROFILE%)
    /// `HOME` is typically unset; fall back to `USERPROFILE`
    /// (Windows' canonical user-home variable), then to
    /// `HOMEDRIVE`+`HOMEPATH`. Only used if HOME is missing or empty.
    /// Mirrors helpers.db_path.getDbPath / helpers.dir.getDataAppsDir
    /// (same HOME -> USERPROFILE chain).
    pub fn getHomeDirectory(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const env = environment orelse return SystemFolderError.HomeNotFound;
        if (env.get("HOME")) |h| {
            if (h.len > 0) return allocator.dupe(u8, h) catch return SystemFolderError.OutOfMemory;
        }
        if (env.get("USERPROFILE")) |u| {
            if (u.len > 0) return allocator.dupe(u8, u) catch return SystemFolderError.OutOfMemory;
        }
        // Last resort on Windows: HOMEDRIVE (e.g. "C:") + HOMEPATH (e.g. "\Users\ginwa")
        if (env.get("HOMEDRIVE")) |drive| {
            if (env.get("HOMEPATH")) |hpath| {
                if (drive.len > 0 and hpath.len > 0) {
                    const joined = std.fs.path.join(allocator, &.{ drive, hpath }) catch return SystemFolderError.OutOfMemory;
                    return joined;
                }
            }
        }
        // Compat: on POSIX an explicitly-set-but-empty HOME historically
        // succeeded with "" (see test "HOME=empty string still succeeds").
        // The fallback chain above already preferred USERPROFILE/HOMEDRIVE
        // when present, so reaching here means no fallback existed —
        // preserve the old behaviour by returning HOME verbatim (even "").
        if (env.get("HOME")) |h| {
            return allocator.dupe(u8, h) catch return SystemFolderError.OutOfMemory;
        }
        return SystemFolderError.HomeNotFound;
    }
    
    /// Get the current working directory
    pub fn getCurrentWorkingDirectory(allocator: std.mem.Allocator) ![]u8 {
        return std.process.getCwdAlloc(allocator);
    }
    
    /// Get relative path from home for current working directory
    pub fn getCwdRelativeToHome(allocator: std.mem.Allocator, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        const cwd = try getCurrentWorkingDirectory(allocator);
        defer allocator.free(cwd);

        return getRelativePathFromHome(allocator, cwd, home);
    }

    /// Resolve a relative path to absolute path (relative to home)
    pub fn resolvePath(allocator: std.mem.Allocator, relative_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError![]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Check if path already starts with home directory (absolute path)
        if (std.mem.startsWith(u8, relative_path, home)) {
            return allocator.dupe(u8, relative_path);
        }

        // If path starts with /, it's an absolute Unix path - return as-is
        if (std.mem.startsWith(u8, relative_path, "/")) {
            return allocator.dupe(u8, relative_path);
        }

        // Windows absolute path: drive letter (`C:\...`, `C:/...`) or
        // UNC (`\\server\share`). Return as-is so `listDirectory` can
        // open it directly via `openDirAbsolute`.
        if (relative_path.len >= 2 and std.ascii.isAlphabetic(relative_path[0]) and relative_path[1] == ':') {
            return allocator.dupe(u8, relative_path);
        }
        if (std.mem.startsWith(u8, relative_path, "\\\\") or std.mem.startsWith(u8, relative_path, "//")) {
            return allocator.dupe(u8, relative_path);
        }

        // Otherwise treat as absolute path
        return allocator.dupe(u8, relative_path);
    }

    /// List directory contents (first level only)
    pub fn listDirectory(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) SystemFolderError![]FolderEntry {
        var entries = std.ArrayList(FolderEntry).empty;
        errdefer entries.deinit(allocator);

        var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
            return SystemFolderError.InvalidPath;
        };
        defer std.Io.Dir.close(dir, io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            const name = entry.name;
            if (name.len == 0) break;

            // Skip hidden files/folders (starting with .)
            if (name.len > 0 and name[0] == '.') continue;

            const is_dir = entry.kind == .directory;
            const is_link = entry.kind == .sym_link;
            const is_file = entry.kind == .file;

            if (is_dir or is_file) {
                const entry_name = allocator.dupe(u8, name) catch continue;
                const full_path = std.fs.path.join(allocator, &.{ dir_path, name }) catch {
                    allocator.free(entry_name);
                    continue;
                };

                // Check if path is gitignored (use -C to set working
                // directory). Spawn failures (e.g. `git` not on PATH
                // on Windows / Wine) are FALL-THROUGH-OK: the entry
                // is kept because we can't prove it's gitignored. The
                // old `catch continue` silently dropped every entry
                // when git was unavailable — which made listDirectory
                // return `[]` for any Windows / sandboxed environment.
                const git_result = std.process.run(allocator, io, .{
                    .argv = &.{ "git", "-C", dir_path, "check-ignore", name },
                }) catch blk: {
                    // Spawn failed — treat as "not gitignored" so
                    // callers see the entry rather than a confusing
                    // empty list. The fake Term.exited=128 mirrors
                    // git's "not a git repo" exit code.
                    break :blk std.process.RunResult{
                        .term = .{ .exited = 128 },
                        .stdout = &[_]u8{},
                        .stderr = &[_]u8{},
                    };
                };
                defer allocator.free(git_result.stdout);
                defer allocator.free(git_result.stderr);
                if (git_result.term.exited == 0) {
                    // Path is gitignored, skip it
                    allocator.free(entry_name);
                    allocator.free(full_path);
                    continue;
                }

                entries.append(allocator, FolderEntry{
                    .name = entry_name,
                    .path = full_path,
                    .is_directory = is_dir,
                    .is_symlink = is_link,
                }) catch continue;
            }
        }

        // Sort: directories first, then files, alphabetically
        std.mem.sort(FolderEntry, entries.items, {}, struct {
            fn less(_: void, a: FolderEntry, b: FolderEntry) bool {
                if (a.is_directory != b.is_directory) {
                    return a.is_directory;
                }
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);

        return entries.toOwnedSlice(allocator);
    }

    /// Get parent directory path
    pub fn getParentPath(allocator: std.mem.Allocator, dir_path: []const u8, environment: ?*const std.process.Environ.Map) SystemFolderError!?[]u8 {
        const home = try getHomeDirectory(allocator, environment);
        defer allocator.free(home);

        // Don't go above home. Compare normalized forms so
        // `C:\Users\ginwa\` (trailing separator) still matches home
        // `C:\Users\ginwa` on Windows.
        // Cross-platform rule (keeps POSIX tests green):
        // - trailing `\` is always stripped (Windows paths can appear in
        //   synthetic env maps on any OS; a POSIX filename ending in `\`
        //   is vanishingly rare);
        // - trailing `/` is stripped on Windows only, because the POSIX
        //   test "dir_path == home with trailing slash still returns
        //   parent" explicitly documents `/home/user/` -> parent `/home`.
        const norm_dir = if (dir_path.len > 1 and dir_path[dir_path.len - 1] == '\\')
            dir_path[0..dir_path.len - 1]
        else if (builtin.os.tag == .windows and dir_path.len > 1 and dir_path[dir_path.len - 1] == '/')
            dir_path[0..dir_path.len - 1]
        else
            dir_path;
        const norm_home = if (home.len > 1 and home[home.len - 1] == '\\')
            home[0..home.len - 1]
        else if (builtin.os.tag == .windows and home.len > 1 and home[home.len - 1] == '/')
            home[0..home.len - 1]
        else if (home.len == 1 and (home[0] == '/' or home[0] == '\\'))
            home[0..0] // root "/" normalizes to "" so "/"+trailing variants compare equal
        else
            home;
        // Also treat a single trailing `\` on a multi-char home (e.g.
        // `C:\Users\ginwa\`) as equal — covered by the first branch above
        // for dir; for home the `len > 1` backslash branch handles it.
        // Edge: home `\` alone (Windows root) normalizes to "" like POSIX.
        const norm_home_adj = if (home.len == 1 and home[0] == '\\') home[0..0] else norm_home;
        if (std.mem.eql(u8, norm_dir, norm_home_adj)) {
            return null;
        }
        // POSIX dirname handles `/`-separated paths (including a trailing
        // `/`, which it strips before finding the parent). It knows
        // nothing about `\`, so Windows paths on Linux/macOS fall through
        // to the manual split below.
        if (std.fs.path.dirname(dir_path)) |p| {
            return try allocator.dupe(u8, p);
        }
        // Manual Windows-separator parent: strip one trailing separator,
        // then cut at the last `/` or `\`. Drive roots (`C:\`, `C:/`, `/`,
        // `\`) have no parent -> null.
        var stripped = dir_path;
        if (stripped.len > 1 and (stripped[stripped.len - 1] == '/' or stripped[stripped.len - 1] == '\\')) {
            stripped = stripped[0..stripped.len - 1];
        }
        const last_sep: ?usize = blk: {
            const b = std.mem.lastIndexOfScalar(u8, stripped, '\\');
            const f = std.mem.lastIndexOfScalar(u8, stripped, '/');
            if (b != null and f != null) break :blk @max(b.?, f.?);
            break :blk b orelse f;
        };
        const idx = last_sep orelse return null;
        if (idx == 0) return null; // `/foo` -> parent is `/`, but bare `/` root -> null; `idx==0` means root-level
        if (idx == 2 and stripped.len >= 3 and std.ascii.isAlphabetic(stripped[0]) and stripped[1] == ':' and (stripped[2] == '/' or stripped[2] == '\\')) {
            // `C:\foo` -> parent is the drive root `C:\` (keep separator style of input)
            return try allocator.dupe(u8, stripped[0..3]);
        }
        // `C:` alone or empty prefix -> null
        if (idx == 0) return null;
        return try allocator.dupe(u8, stripped[0..idx]);
    }
};
